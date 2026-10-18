# frozen_string_literal: true

require "test_helper"

class RewriterTest < Minitest::Test
  def body(source) = rewrite(source).source.sub(/\n# ar_minimizer v.*\n\z/, "")

  def test_variable_receiver
    assert_equal 'user = 1; (::User.equal?(user.class) ? user.attribute_was(-"age") : user.age_was)',
      body("user = 1; user.age_was")
  end

  def test_guard_lists_every_model_with_the_attribute
    assert_equal '(::Post.equal?(@u.class) || ::User.equal?(@u.class) ? @u.attribute_changed?(-"name") : @u.name_changed?)',
      body("@u.name_changed?")
  end

  def test_many_models_ask_the_class_instead
    entry = ArMinimizer::Index::Entry.new("attribute_changed?", "name", true, %w[A B C D E], nil)
    out = ArMinimizer::Rewriter.new(index: { name_changed?: entry }, guards: true).rewrite("@u.name_changed?").source
    assert_includes out, '(::ActiveRecord::Base === @u && @u.class._has_attribute?("name") ? @u.attribute_changed?(-"name") : @u.name_changed?)'
  end

  def test_other_receivers_are_evaluated_once
    assert_equal '(::User.equal?((__arm1 = find(1)).class) ? __arm1.attribute_was(-"age") : __arm1.age_was)',
      body("find(1).age_was")
  end

  def test_query_compiles_by_column_type
    assert_equal '(::User.equal?(@u.class) ? (!!@u.active) : @u.active?)', body("@u.active?")
    assert_equal '(::User.equal?(@u.class) ? ((@u.age || 0) != 0) : @u.age?)', body("@u.age?")
    assert_equal '(::Post.equal?(@u.class) || ::User.equal?(@u.class) ? (!@u.name.blank?) : @u.name?)', body("@u.name?")
    assert_includes body("@u.status?"), "@u.query_attribute(-\"status\")" # enum
    assert_includes body("@u.born_at?"), "(!!@u.born_at)" # plain DateTime outside Rails (no time zone conversion)
    # self is known: parenthesized so `!` and `.to_s` still apply to the whole expression
    assert_includes body("class User < ActiveRecord::Base\n  def x = !age?.to_s\nend"), "def x = !((self.age || 0) != 0).to_s"
  end

  def test_private_proxy_goes_through_send
    assert_includes body("@u.name_will_change!"), '@u.__send__(:attribute_will_change!, -"name")'
    assert_includes body("name_will_change!"), ': name_will_change!)' # implicit self: no __send__ needed
    assert_includes body("name_will_change!"), '? attribute_will_change!(-"name")'
  end

  def test_arguments
    assert_includes body("@u.saved_change_to_name?(from: a, to: b)"), '@u.saved_change_to_attribute?(-"name", from: a, to: b) : @u.saved_change_to_name?(from: a, to: b)'
  end

  def test_safe_navigation
    assert_equal '(nil == @u ? nil : ::User.equal?(@u.class) ? @u.attribute_was(-"age") : @u.age_was)', body("@u&.age_was")
    assert_equal '(nil == (__arm1 = u) ? nil : ::User.equal?(__arm1.class) ? __arm1.attribute_was(-"age") : __arm1.age_was)', body("u&.age_was")
  end

  def test_implicit_self_inside_model_instance_method
    source = "class User < ActiveRecord::Base\n  def x = name_changed?\nend"
    assert_includes body(source), 'def x = attribute_changed?(-"name")'
  end

  def test_implicit_self_elsewhere_checks_the_class
    assert_includes body("module Concern\n  def x = age_was\nend"), '(::User.equal?(self.class) ? attribute_was(-"age") : age_was)'
    # a block inside a model method may be instance_exec'd on something else
    assert_includes body("class User < ActiveRecord::Base\n  def x = build { age? }\nend"), "::User.equal?(self.class)"
  end

  def test_nested_sites
    out = body("a.b.age_was.foo.will_save_change_to_age?")
    assert_equal '(::User.equal?((__arm1 = (::User.equal?((__arm2 = a.b).class) ? __arm2.attribute_was(-"age") : __arm2.age_was).foo).class) ? ' \
      '__arm1.will_save_change_to_attribute?(-"age") : __arm1.will_save_change_to_age?)', out
  end

  def test_left_alone
    ["defined?(u.name?)", "u.name_changed? { }", "u.name_changed?(&b)", "u.age_changed?", "u.name", "u.whatever?",
     "u.name_changed?(<<~X)\n  hi\nX", "u.send(:name?)", "u.name? = 1 rescue nil"].each do |source|
      result = rewrite(source)
      assert_equal source, result.source, source if result.sites.zero?
      assert_equal 0, result.sites, source
    end
  end

  def test_line_numbers_kept_and_marker_appended
    source = "a = 1\nu.name?\n\nu.age?\n"
    out = rewrite(source).source
    assert_equal 2, out.lines.index { it.include?("name.blank?") } + 1
    assert_equal 4, out.lines.index { it.include?(".age || 0") } + 1
    assert_equal ArMinimizer::Rewriter::MARKER, out.lines.last.chomp
  end

  def test_marker_goes_before_data
    out = rewrite("u.name?\n__END__\ndata\n").source
    assert out.end_with?("#{ArMinimizer::Rewriter::MARKER}\n__END__\ndata\n")
  end

  def test_idempotent
    once = rewrite("u.name?\n").source
    result = rewrite(once)
    assert_equal 0, result.sites
    assert_equal once, result.source
  end

  def test_unparseable_files_are_skipped
    result = rewrite("def (", path: "bad.rb")
    assert_equal "def (", result.source
    assert_equal ["bad.rb: does not parse, left untouched"], result.skipped
  end
end

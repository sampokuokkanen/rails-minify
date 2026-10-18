# frozen_string_literal: true

require "test_helper"

class SlimTest < Minitest::Test
  def generated(model) = model.send(:generated_attribute_methods).instance_methods(false).map(&:to_s).sort

  def test_only_readers_writers_and_hand_written_overrides_are_generated
    with_slim(true) do
      User.new
      # id, id=, id? ... are real methods in ActiveRecord::AttributeMethods::PrimaryKey.
      expected = (User.attribute_names - %w[id] + %w[id_value title]).flat_map { [it, "#{it}="] } + %w[age_changed?]
      # Rails main defines id_value as a plain reader for most models, with no writer.
      expected -= %w[id_value=] unless User.attribute_alias?("id_value")
      # Rails calls these itself: enum predicates/scopes, and cache_version.
      expected += %w[status_for_database updated_at_before_type_cast updated_at_came_from_user?]
      assert_equal expected.sort, generated(User)
    end
  end

  def test_keep_methods
    ArMinimizer::Slim.enable!(keep_methods: ["name_changed?", "Post#title_was", "User#title_was"])
    User.new
    Post.new
    assert_includes generated(User), "name_changed?"
    assert_includes generated(Post), "name_changed?"
    assert_includes generated(Post), "title_was"
    assert_includes generated(User), "title_was" # an alias in User: kept by name too
    refute_includes generated(Post), "title_changed?"
  ensure
    ArMinimizer::Slim.disable!
  end

  def test_parse_keep_file
    text = "# hot methods\nUser#will_save_change_to_email? # 2274 calls\n\nname_changed?\n"
    assert_equal %w[User#will_save_change_to_email? name_changed?], ArMinimizer::Slim.parse_keep_file(text)
  end

  def test_stock_activerecord_generates_many_more
    with_slim(false) do
      User.new
      assert_operator generated(User).size, :>, 150
    end
  end

  # Every pattern method of every attribute (and alias) answers the same with and without Slim.
  def test_parity_with_stock_activerecord
    names = User.attribute_method_patterns.flat_map { |p| (User.attribute_names + %w[title id_value]).map { p.method_name(it) } }
    names -= names.grep(/=\z|!\z|\Aclear_/) # mutators: checked separately

    states = {
      new: -> { User.new(name: "", age: 0) },
      saved: -> { User.create!(name: "a", age: 3, active: true, balance: "1.5") },
      dirty: -> { User.create!(name: "a").tap { it.name = "b"; it.age = 0 } },
      partial: -> { User.create!(name: "a"); User.select(:id, :name).first },
    }
    states.each do |state, build|
      stock = with_slim(false) { u = build.call; names.to_h { [it, outcome { u.public_send(it) }] } }
      slim = with_slim(true) { u = build.call; names.to_h { [it, outcome { u.public_send(it) }] } }
      names.each { assert_equal stock[it], slim[it], "#{state}: #{it}" }
    end
  end

  def test_lazy_generates_a_method_on_first_call
    with_slim(true) do
      u = User.create!(name: "a")
      refute_includes generated(User), "name_previously_changed?"
      assert u.name_previously_changed?
      assert_includes generated(User), "name_previously_changed?"
      assert u.name_previously_changed? # now the generated method
      refute_includes generated(Post), "name_previously_changed?" # per model

      u.name = "b"
      assert_equal "a", u.title_was # alias
      assert_includes generated(User), "title_was"
      assert_equal "a", u.title_was

      v = User.select("users.*, 1 AS answer").first
      assert v.answer?
      refute_includes generated(User), "answer?" # not a column of the class
    end
  end

  def test_lazy_off
    ArMinimizer::Slim.enable!(lazy: false, strict: false)
    u = User.new
    u.name_changed?
    refute_includes generated(User), "name_changed?"
  ensure
    ArMinimizer::Slim.disable!
  end

  def test_attribute_methods_for_non_attributes_stay_generated
    klass = Class.new(ActiveRecord::Base) do
      self.table_name = "users"
      def self.name = "Stored"
      def show_previews = true
    end
    with_slim(true) do
      klass.define_attribute_method(:show_previews) # what typed_store does for its keys
      assert_equal true, klass.new.show_previews?
    end
  end

  def test_columns_only_the_query_has
    User.create!(name: "a")
    [false, true].each do |slim|
      with_slim(slim) do
        u = User.select("users.*, 42 AS answer").first
        assert_equal 42, u.answer
        assert u.answer?
        assert u.respond_to?(:answer_before_type_cast)
        assert_raises(NoMethodError) { User.first.answer }
      end
    end
  end

  def test_mutators
    with_slim(true) do
      u = User.create!(name: "a")
      u.name = "b"
      u.restore_name!
      assert_equal "a", u.name
      u.title = "c"
      u.clear_title_change
      refute u.name_changed?
      u.name_will_change!
      assert u.name_changed?
    end
  end

  def test_respond_to_and_method_objects
    with_slim(true) do
      u = User.new
      assert u.respond_to?(:name_changed?)
      assert u.respond_to?(:title_before_type_cast)
      refute u.respond_to?(:nope_changed?)
      assert_equal false, u.method(:name_changed?).call
      assert_raises(NoMethodError) { u.nope_changed? }
    end
  end

  def test_hand_written_override_calling_super
    with_slim(true) do
      u = User.create!(age: 1)
      assert_equal false, u.age_changed?
      u.age = 2
      assert_equal true, u.age_changed?
    end
  end
end

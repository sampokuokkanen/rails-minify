# frozen_string_literal: true

require "test_helper"

# A concern only User includes: inside it, self is a User.
module NameTracking
  def name_tracking_probe = name_changed?
end
User.include(NameTracking)

class InferenceTest < Minitest::Test
  def index = ArMinimizer::Index.from_models([User, Post])

  def body(source) = ArMinimizer::Rewriter.new(index: index, marker: false).rewrite(source).source

  def test_locals_assigned_a_record_need_no_guard
    assert_equal 'def x = (u = User.find(1); u.attribute_changed?(-"name"))', body("def x = (u = User.find(1); u.name_changed?)")
    assert_equal 'def x = (u = User.find(1); [1].each { u.name_changed? })'.sub("u.name_changed?", 'u.attribute_changed?(-"name")'),
      body("def x = (u = User.find(1); [1].each { u.name_changed? })") # read from a block, depth 1
    assert_equal "def x = (u = User.new(name: \"a\"); (!!u.active))", body("def x = (u = User.new(name: \"a\"); u.active?)")
    assert_equal 'def x = (u = User.find_by!(name: "a"); (!u.name.blank?))', body('def x = (u = User.find_by!(name: "a"); u.name?)')
  end

  def test_anything_uncertain_stays_as_written_or_keeps_the_guard
    {
      "def x(o) = (u = User.find(1); u = o; u.name_changed?)" => "reassigned",
      "def x(u) = u.name_changed?" => "a parameter",
      "def x = (u = User.find([1, 2]); u.name_changed?)" => "an Array",
      "def x = (u = User.create(list); u.name_changed?)" => "maybe an Array",
      "def x = (u ||= User.find(1); u.name_changed?)" => "||=",
      "def x = (u = User.find(1); [1].each { u = nil }; u.name_changed?)" => "reassigned in a block",
    }.each do |source, why|
      assert_equal source, body(source), why # default: not compiled
      guarded = ArMinimizer::Rewriter.new(index: index, marker: false, guards: true).rewrite(source).source
      assert_includes guarded, ".equal?(u.class)", why
    end
  end

  def test_maybe_nil_records_get_a_nil_check_not_a_class_check
    assert_equal 'def x = (u = User.find_by(name: 1); (nil == u ? u.name_changed? : u.attribute_changed?(-"name")))',
      body("def x = (u = User.find_by(name: 1); u.name_changed?)")
    assert_equal "def x = (u = User.first; (nil == u ? nil : (!!u.active)))", body("def x = (u = User.first; u&.active?)")
  end

  def test_associations_and_scopes
    # posts: has_many Post, user: belongs_to User (maybe nil); verified: an enum scope
    assert_equal 'def x = (u = User.find(1); u.posts.each { |p| p.attribute_changed?(-"title") })',
      body("def x = (u = User.find(1); u.posts.each { |p| p.title_changed? })")
    assert_equal "def x = (p = Post.find(1); (nil == (__arm1 = p.user) ? __arm1.active? : (!!__arm1.active)))",
      body("def x = (p = Post.find(1); p.user.active?)")
    assert_equal "def x = User.verified.where(age: 3).each { |u| (!!u.active) }", body("def x = User.verified.where(age: 3).each { |u| u.active? }")
    assert_equal "class Post < ActiveRecord::Base\n  def x = (nil == (__arm1 = user) ? __arm1.active? : (!!__arm1.active))\nend\n",
      body("class Post < ActiveRecord::Base\n  def x = user.active?\nend\n") # implicit self's association
  end

  def test_block_parameters_of_relation_iterations
    # (exact strings: a guarded call contains the unguarded one as its fast branch)
    assert_equal "def x = User.where(active: true).order(:name).each { |u| (!!u.active) }",
      body("def x = User.where(active: true).order(:name).each { |u| u.active? }")
    assert_equal 'def x = User.all.map { |u| u.attribute_changed?(-"name") }', body("def x = User.all.map { |u| u.name_changed? }")
    assert_equal "def x = list.each { |u| u.active? }", body("def x = list.each { |u| u.active? }") # unknown collection
    assert_equal "def x = User.where(a: 1).each { |u| u = other; u.active? }", body("def x = User.where(a: 1).each { |u| u = other; u.active? }")
    assert_equal "def x = User.all.each { |u| [1].map { (!!u.active) } }", body("def x = User.all.each { |u| [1].map { u.active? } }") # read from a nested block
  end

  def test_self_in_a_class_that_is_not_a_model_stays_as_written
    source = "class Widget\n  def x = name_changed?\nend\n"
    result = ArMinimizer::Rewriter.new(index: index, marker: false).rewrite(source)
    assert_equal source, result.source
    assert_equal 0, result.sites
  end

  def test_calls_no_possible_class_has_as_an_attribute_method_stay_as_written
    # Post has no active column: inside Post, and on a Post, active? is something else.
    source = "class Post < ActiveRecord::Base\n  def x = active?\n  def y = (p = Post.find(1); p.active?)\nend\n"
    result = ArMinimizer::Rewriter.new(index: index, marker: false).rewrite(source)
    assert_equal source, result.source
  end

  def test_self_in_a_concern_its_models_all_have_the_attribute_for
    out = body("module NameTracking\n  def name_tracking_probe = name_changed?\nend\n")
    assert_includes out, 'def name_tracking_probe = attribute_changed?(-"name")'
  end

  def test_unqualified_constants_in_a_namespace_with_a_model_of_that_name
    idx = ArMinimizer::Index.new([
      *index.models,
      ArMinimizer::Index::Model.new(name: "Shop::User", attributes: { "name" => :string }, primary_key: ["id"],
        patterns: index.models.first.patterns, hand_written: []),
    ], keep: ArMinimizer::Slim::DEFAULT_KEEP)
    source = "module Shop\n  def self.x = (u = User.find(1); u.name_changed?)\nend\n"
    assert_equal source, ArMinimizer::Rewriter.new(index: idx, marker: false).rewrite(source).source # User here may be Shop::User
  end

  def test_runs_like_rails
    ArMinimizer::Slim.enable!(strict: false) # the original source calls pattern methods
    User.create!(name: "a", active: true)
    source = <<~RUBY
      module InferenceProbe
        def self.found(id) = (u = User.find(id); [u.name?, u.active?, u.name_changed?, u.saved_change_to_name?])
        def self.iterated = User.order(:id).map { |u| [u.name?, u.active?] }
      end
    RUBY
    Object.class_eval(source)
    original = [InferenceProbe.found(User.first.id), InferenceProbe.iterated]
    compiled_source = ArMinimizer::Rewriter.new(index: index, marker: false).rewrite(source).source
    refute_includes compiled_source, ".equal?(" # all inferred
    Object.class_eval(compiled_source)
    assert_equal original, [InferenceProbe.found(User.first.id), InferenceProbe.iterated]
  ensure
    ArMinimizer::Slim.disable!
  end
end

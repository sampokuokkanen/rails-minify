# frozen_string_literal: true

require_relative "test_helper"

class RewriteTest < Minitest::Test
  include RewriteHelpers

  def test_queries_by_column_type
    assert_equal "x = v.featured.present?", rewrite("x = v.featured?")
    assert_equal "x = v.name.present?", rewrite("x = v.name?")
    assert_equal "x = v.query_attribute(:rank)", rewrite("x = v.rank?")
    assert_equal "x = v.query_attribute(:status)", rewrite("x = v.status?")
  end

  def test_truthy_columns_read_as_is_where_only_truthiness_matters
    assert_equal "go if v.featured", rewrite("go if v.featured?")
    assert_equal "go unless v.featured || !v.featured", rewrite("go unless v.featured? || !v.featured?")
    assert_equal "v.featured ? 1 : 2", rewrite("v.featured? ? 1 : 2")
    assert_equal "go if (v.featured && w.name.present?)", rewrite("go if (v.featured? && w.name?)")
    # an empty string or 0 is truthy, so those keep their query
    assert_equal "go if v.name.present? && v.query_attribute(:rank)", rewrite("go if v.name? && v.rank?")
    # values that are used keep a boolean
    assert_equal "[v.featured.present?, v.featured.present? && 1]", rewrite("[v.featured?, v.featured? && 1]")
  end

  def test_other_patterns_keep_their_arguments
    assert_equal "v.attribute_changed?(:name)", rewrite("v.name_changed?")
    assert_equal "v.attribute_changed?(:name, from: nil, to: 1)", rewrite("v.name_changed?(from: nil, to: 1)")
    assert_equal "v.attribute_changed?(:name, to: 1)", rewrite("v.name_changed? to: 1")
    assert_equal "v&.saved_change_to_attribute?(:rank)", rewrite("v&.saved_change_to_rank?")
    assert_equal "a.b.attribute_was(:name)", rewrite("a.b.name_was")
  end

  def test_nested_calls
    assert_equal "v.attribute_changed?(:name, to: w.attribute_was(:name))", rewrite("v.name_changed?(to: w.name_was)")
    assert_equal "list.attribute_was(:name).present?", rewrite("list.name_was.present?")
  end

  def test_no_receiver_only_in_models_and_their_modules
    model = "class Venue < ApplicationRecord\n  def x = featured? && name_changed?\nend"
    assert_equal "class Venue < ApplicationRecord\n  def x = featured.present? && attribute_changed?(:name)\nend", rewrite(model)
    assert_equal "module Featurable\n  def x = attribute_changed?(:name)\nend", rewrite("module Featurable\n  def x = name_changed?\nend")
    helper = "module VenuesHelper\n  def x = featured?\nend"
    assert_equal helper, rewrite(helper)
    assert_equal "featured?", rewrite("featured?")
    assert_equal "self.featured?", rewrite("self.featured?", views: true)
  end

  def test_class_level_code_is_not_a_record
    src = "class Venue\n  def self.x = featured?\n  class << self\n    def y = name_changed?\n  end\nend"
    assert_equal src, rewrite(src)
  end

  def test_private_proxies
    assert_equal "class Venue\n  def x = attribute_will_change!(:name)\nend", rewrite("class Venue\n  def x = name_will_change!\nend")
    assert_equal "class Venue\n  def x = self.attribute_will_change!(:name)\nend", rewrite("class Venue\n  def x = self.name_will_change!\nend")
    assert_equal "v.name_will_change!", rewrite("v.name_will_change!")
    assert_match(/it's private/, messages("v.name_will_change!").first)
  end

  def test_a_local_of_the_same_name_gets_self
    src = "class Venue\n  def x(featured) = [featured?, featured]\nend"
    assert_equal "class Venue\n  def x(featured) = [self.featured.present?, featured]\nend", rewrite(src)
  end

  def test_names_the_app_defines_are_only_reported
    defined = { "featured?" => "app/models/poro.rb:3" }
    assert_equal "p.featured?", rewrite("p.featured?", defined: defined)
    assert_match(%r{app/models/poro.rb:3 defines}, messages("p.featured?", defined: defined).first)
  end

  def test_other_names_are_left_alone
    %w[v.featured v.name= v.id? v.other? v.name_changed?{} v.name_changed?(&b)].each { assert_equal it, rewrite(it) }
    assert_empty messages("v.featured; v.id?")
  end

  def test_callback_conditions_become_lambdas
    src = "class Venue\n  before_save :geo, if: :name_changed?, unless: [:featured?, :ok?]\n  validates :x, if: :name?\nend"
    assert_equal "class Venue\n  before_save :geo, if: -> { attribute_changed?(:name) }, unless: [-> { featured }, :ok?]\n  validates :x, if: -> { name.present? }\nend", rewrite(src)
  end

  def test_send_try_and_delegate_are_reported
    assert_equal 3, messages("v.try(:featured?); v.send(:name_was)\nclass P\n  delegate :featured?, to: :venue\nend").size
  end

  def test_keeps_multibyte_text_intact
    assert_equal "# 日本語\nv.featured.present? # ゴルフ\n", rewrite("# 日本語\nv.featured? # ゴルフ\n")
  end
end

class RewriteFalsePositiveTest < Minitest::Test
  include RewriteHelpers

  def index
    @index ||= ArMinimizer::Index.new([
      ArMinimizer::Index::Model.new(name: "Setting", primary_key: ["id"], patterns: PATTERNS, hand_written: [],
        attributes: { "key" => :string, "empty" => :truthy, "name" => :string }),
    ], keep: ["attribute", "attribute="])
  end

  def test_core_method_names_and_calls_with_arguments_are_not_attribute_methods
    assert_equal "h.key?(:a); a.empty?; s.name?(1)", rewrite("h.key?(:a); a.empty?; s.name?(1)")
    assert_empty messages("h.key?(:a); h.key?; v.try(:key?)")
  end

  def test_reports_say_where_it_was_removed
    assert_match(/removed by strict mode from Setting, but x.rb:1 defines/, messages("p.name?", defined: { "name?" => "x.rb:1" }).first)
  end
end

class RewriteShadowTest < Minitest::Test
  include RewriteHelpers

  # Profile has no username column; its username? is an enum predicate.
  def index
    @index ||= ArMinimizer::Index.new([
      ArMinimizer::Index::Model.new(name: "User", primary_key: ["id"], patterns: PATTERNS, hand_written: [], attributes: { "username" => :string }),
      ArMinimizer::Index::Model.new(name: "Profile", primary_key: ["id"], patterns: PATTERNS, hand_written: [], attributes: { "bio" => :string }, shadows: ["username?"]),
      ArMinimizer::Index::Model.new(name: "Admin", primary_key: ["id"], patterns: PATTERNS, hand_written: [], attributes: { "bio" => :string, "username" => :string }, superclass: "User"),
      ArMinimizer::Index::Model.new(name: "Mixed", primary_key: ["id"], patterns: PATTERNS, hand_written: [], attributes: {}, modules: ["Named"]),
      ArMinimizer::Index::Model.new(name: "Named2", primary_key: ["id"], patterns: PATTERNS, hand_written: [], attributes: { "username" => :string }, modules: ["Named"]),
    ], keep: ["attribute", "attribute="])
  end

  def test_no_receiver_in_a_model_without_the_attribute_is_left_alone
    src = "class Profile\n  def name = username? && bio_changed?\nend"
    assert_equal "class Profile\n  def name = username? && attribute_changed?(:bio)\nend", rewrite(src)
    assert_equal "class User\n  def x = username.present?\nend", rewrite("class User\n  def x = username?\nend")
  end

  def test_modules_included_where_only_some_models_have_it_are_reported
    src = "module Named\n  def x = username?\nend"
    assert_equal src, rewrite(src)
    assert_match(/not every class/, messages(src).first)
  end

  def test_names_another_model_defines_otherwise_are_reported_on_receivers
    assert_equal "u.username?", rewrite("u.username?")
    assert_match(/Profile defines it otherwise/, messages("u.username?").first)
    assert_equal "u.attribute_changed?(:username)", rewrite("u.username_changed?")
  end
end

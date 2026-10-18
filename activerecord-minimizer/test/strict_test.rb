# frozen_string_literal: true

require "test_helper"

class StrictTest < Minitest::Test
  def strict(**opts)
    ArMinimizer::Slim.enable!(**opts) # strict is the default
    yield
  ensure
    ArMinimizer::Slim.disable!
  end

  def generated(model) = model.send(:generated_attribute_methods).instance_methods(false).map(&:to_s)

  def test_pattern_methods_are_gone
    strict do
      u = User.create!(name: "a")
      error = assert_raises(NoMethodError) { u.name_changed? }
      assert_equal "name_changed? was removed by activerecord-minimizer's strict mode; use attribute_changed?(:name, ...)", error.message
      assert_equal :name_changed?, error.name
      assert_match(/use query_attribute\(:name\)/, assert_raises(NoMethodError) { u.name? }.message)
      assert_match(/use saved_change_to_attribute\?\(:name, \.\.\.\)/, assert_raises(NoMethodError) { u.saved_change_to_name? }.message)
      assert_match(/use attribute_will_change!\(:name\) \(private: on self\)/, assert_raises(NoMethodError) { u.name_will_change! }.message)
      assert_match(/use attribute_changed\?/, assert_raises(NoMethodError) { u.title_changed? }.message) # an alias
      refute_includes generated(User), "name_changed?" # not generated on demand either
      refute u.respond_to?(:name_changed?)
      assert_raises(NameError) { u.method(:name_changed?) }
    end
  end

  # Form fields and numericality validation ask respond_to? first and do
  # something else on no.
  def test_methods_rails_probes_still_answer
    strict do
      klass = Class.new(User) { def self.name = "User"; validates :age, numericality: true, allow_nil: true }
      u = klass.new(age: "abc")
      assert u.respond_to?(:age_came_from_user?)
      assert_equal ["abc", true], [u.age_before_type_cast, u.age_came_from_user?]
      refute u.valid? # validated as typed, not as the cast value
      assert_includes generated(klass), "age_before_type_cast" # generated on first call
      refute u.respond_to?(:age_was)
    end
  end

  def test_the_replacements_answer_the_same
    strict do
      u = User.create!(name: "a")
      u.name = "b"
      assert_equal [true, "a", true], [u.attribute_changed?(:name), u.attribute_was(:name), u.query_attribute(:name)]
    end
  end

  def test_readers_writers_and_query_only_columns_still_work
    strict do
      User.create!(name: "a")
      u = User.select("users.*, 42 AS answer").first
      assert_equal 42, u.answer
      assert u.respond_to?(:answer)
      refute u.respond_to?(:answer?) # a pattern method: gone
      u.name = "b"
      assert_equal "b", u.title # alias reader
      refute u.respond_to?(:to_ary)
      assert_equal [u], [u].flatten
    end
  end

  def test_what_still_gets_generated
    strict(keep_methods: ["User#name_previously_changed?"]) do
      u = User.create!(age: 1)
      assert_equal false, u.age_changed? # hand-written, calls super
      assert u.name_previously_changed?.in?([true, false]) # kept by name
      assert u.pending? # enum predicate: status_for_database is generated
      # cache_version calls these by name
      assert_includes generated(User), "updated_at_before_type_cast"
      assert_includes generated(User), "updated_at_came_from_user?"
    end
  end

  def test_unknown_methods_are_still_plain_no_method_errors
    strict do
      error = assert_raises(NoMethodError) { User.new.not_a_thing }
      refute_match(/strict mode/, error.message)
    end
  end
end

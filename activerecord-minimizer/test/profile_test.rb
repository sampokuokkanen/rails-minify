# frozen_string_literal: true

require "test_helper"

class ProfileTest < Minitest::Test
  def test_counts_slow_path_calls_per_model_and_method
    Dir.mktmpdir do |dir|
      ArMinimizer::Profile.start!(dir)
      ArMinimizer::Slim.enable!(lazy: false, strict: false)
      u = User.new
      3.times { u.name_changed? }
      u.title_was # alias
      u.name # reader: generated, not counted
      ArMinimizer::Profile.stop!
      assert_equal [["User#name_changed?", 3], ["User#title_was", 1]], ArMinimizer::Profile.report(dir)
    ensure
      ArMinimizer::Slim.disable!
    end
  end

  def test_with_lazy_generation_each_method_is_counted_once
    Dir.mktmpdir do |dir|
      ArMinimizer::Profile.start!(dir)
      with_slim(true) { u = User.new; 3.times { u.name_changed? } }
      ArMinimizer::Profile.stop!
      assert_equal [["User#name_changed?", 1]], ArMinimizer::Profile.report(dir)
    end
  end
end

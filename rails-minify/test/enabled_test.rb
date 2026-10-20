# frozen_string_literal: true

require "test_helper"

class EnabledTest < Minitest::Test
  def config(**rails_minify)
    Struct.new(:rails_minify, :ar_minimizer, :as_minimizer).new(
      ActiveSupport::OrderedOptions.new.merge!(rails_minify),
      ActiveSupport::OrderedOptions.new, ActiveSupport::OrderedOptions.new)
  end

  def apply(config, env: "production", ruby: "4.1.0")
    RailsMinify::Railtie.apply_enabled(config, env: ActiveSupport::EnvironmentInquirer.new(env), ruby: ruby)
    config
  end

  def test_turns_on_strict_enums_and_zjit
    c = apply(config(enabled: true))
    assert_equal true, c.ar_minimizer.slim
    assert_equal true, c.ar_minimizer.enums
    assert_equal true, c.rails_minify.zjit
  end

  def test_leaves_the_experimental_parts_off
    c = apply(config(enabled: true))
    %i[views load_time small_records guards].each { assert_nil c.ar_minimizer[it], it }
    assert_nil c.as_minimizer.unroll_callbacks
    assert_nil c.rails_minify.patches
  end

  def test_keeps_what_is_set_on_its_own
    c = config(enabled: true, zjit: false)
    c.ar_minimizer.enums = false
    apply(c)
    assert_equal false, c.ar_minimizer.enums
    assert_equal false, c.rails_minify.zjit
    assert_equal true, c.ar_minimizer.slim
  end

  def test_no_zjit_in_development_and_test_or_before_ruby_4_1
    assert_equal false, apply(config(enabled: true), env: "test").rails_minify.zjit
    assert_equal false, apply(config(enabled: true), env: "development").rails_minify.zjit
    assert_equal false, apply(config(enabled: true), ruby: "4.0.1").rails_minify.zjit
    assert_equal true, apply(config(enabled: true), ruby: "4.1.0").rails_minify.zjit
  end

  def test_does_nothing_unless_enabled
    c = apply(config)
    assert_nil c.ar_minimizer.slim
    assert_nil c.rails_minify.zjit
  end
end

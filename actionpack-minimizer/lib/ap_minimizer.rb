# frozen_string_literal: true

require "action_controller"
require "ap_minimizer/version"

# Precompiles parts of Action Pack / Action View: named route helpers
# (ApMinimizer::Routes) and template rendering (ApMinimizer::Views).
# Controller callbacks are unrolled by activesupport-minimizer.
module ApMinimizer
  autoload :Routes, "ap_minimizer/routes"
  autoload :Views, "ap_minimizer/views"
  autoload :Census, "ap_minimizer/census"
end

require "ap_minimizer/railtie" if defined?(Rails::Railtie)

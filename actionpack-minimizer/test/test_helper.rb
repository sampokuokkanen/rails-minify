# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)

require "minitest/autorun"
require "action_controller"
require "action_view"
require "ap_minimizer"

ApMinimizer::Routes.install!

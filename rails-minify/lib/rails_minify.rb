# frozen_string_literal: true

require "rails_minify/version"
require "as_minimizer"
require "ar_minimizer"
require "ap_minimizer"

# One switch for the minimizers:
#
#   # config/environments/production.rb
#   config.rails_minify.enabled = true
#
# turns on, unless set otherwise on their own:
#   config.ar_minimizer.slim, .views, .load_time (load_time only with config/ar_minimizer.json)
#   config.as_minimizer.unroll_callbacks
#   config.ap_minimizer.route_helpers, .views
#
# and these patches, for parts of Rails and common gems that redo work on
# every request (config.rails_minify.patches = [...] to choose):
#   :action_text_plain_text  ActionText::Content#to_plain_text, once per distinct HTML
#   :omniauth                OmniAuth strategies skip their per-request dup off their paths
module RailsMinify
  module Patches
    autoload :ActionTextPlainText, "rails_minify/patches/action_text_plain_text"
    autoload :OmniAuthPassthrough, "rails_minify/patches/omniauth_passthrough"
    autoload :RequestHost, "rails_minify/patches/request_host"
  end
end

require "rails_minify/railtie" if defined?(Rails::Railtie)

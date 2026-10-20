# frozen_string_literal: true

require "rails_minify/version"
require "as_minimizer"
require "ar_minimizer"
begin
  require "ap_minimizer" # optional: gem "actionpack-minimizer"
rescue LoadError => e
  raise unless e.path == "ap_minimizer"
end

# One switch:
#
#   # config/environments/production.rb
#   config.rails_minify.enabled = true
#
# turns on, unless set otherwise on their own:
#   config.ar_minimizer.slim   strict mode: only readers and writers per column
#   config.ar_minimizer.enums  enum predicates/bang methods as plain methods
#   config.rails_minify.zjit   ZJIT after boot
#
# Experimental, each off unless set: the other minimizer options
# (ar_minimizer.views, .load_time, .small_records, as_minimizer.unroll_callbacks,
# ap_minimizer.*) and the patches for parts of Rails and common gems that redo
# work on every request (config.rails_minify.patches = true, or a list):
#   :action_text_plain_text  ActionText::Content#to_plain_text, once per distinct HTML
#   :omniauth                OmniAuth strategies skip their per-request dup off their paths
#   :request_host            ActionDispatch::Request#host without a substitution per call
module RailsMinify
  module Patches
    autoload :ActionTextPlainText, "rails_minify/patches/action_text_plain_text"
    autoload :OmniAuthPassthrough, "rails_minify/patches/omniauth_passthrough"
    autoload :RequestHost, "rails_minify/patches/request_host"
  end
end

require "rails_minify/railtie" if defined?(Rails::Railtie)

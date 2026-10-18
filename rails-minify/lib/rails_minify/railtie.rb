# frozen_string_literal: true

module RailsMinify
  class Railtie < Rails::Railtie
    config.rails_minify = ActiveSupport::OrderedOptions.new

    # After config/environments/*.rb, before any initializer reads the
    # minimizers' options.
    config.before_initialize do |app|
      next unless app.config.rails_minify.enabled

      ar = app.config.ar_minimizer
      ar.slim = true if ar.slim.nil?
      ar.views = true if ar.views.nil?
      ar.enums = true if ar.enums.nil?
      ar.small_records = true if ar.small_records.nil?
      ar.load_time = app.root.join("config/ar_minimizer.json").exist? if ar.load_time.nil?
      as = app.config.as_minimizer
      as.unroll_callbacks = true if as.unroll_callbacks.nil?
      ap = app.config.ap_minimizer
      ap.route_helpers = true if ap.route_helpers.nil?
      ap.views = true if ap.views.nil?
    end

    PATCHES = {
      action_text_plain_text: ["ActionText::Content", :action_text_content, -> { Patches::ActionTextPlainText.install! }],
      omniauth: ["OmniAuth::Strategy", nil, -> { Patches::OmniAuthPassthrough.install! }],
      request_host: ["ActionDispatch::Request", nil, -> { Patches::RequestHost.install! }],
    }.freeze

    initializer "rails_minify.patches" do |app|
      options = app.config.rails_minify
      next unless options.enabled || options.patches

      Array(options.patches || PATCHES.keys).each do |name|
        constant, hook, install = PATCHES.fetch(name.to_sym)
        if hook
          ActiveSupport.on_load(hook) { install.call }
        else
          config.after_initialize { install.call if Object.const_defined?(constant) }
        end
      end
    end

    rake_tasks do
      namespace :minify do
        prepare = lambda do
          app = Rails.application
          app.eager_load!
          # Routes define methods too (Devise's authenticate_user!); Rails 8 loads them lazily.
          app.respond_to?(:reload_routes_unless_loaded) ? app.reload_routes_unless_loaded : app.reload_routes!
          app
        end

        desc "How much of the app runs compiled, and why the rest doesn't (VERBOSE=1 for every item)"
        task census: :environment do
          app = prepare.call
          verbose = ENV["VERBOSE"] == "1"
          routed = AsMinimizer::Check.routed_actions(app.routes)
          sections = {
            "Active Record (activerecord-minimizer)" => ArMinimizer::Census.report(root: app.root),
            "Callbacks (activesupport-minimizer)" => AsMinimizer::Census.report(routed: routed),
            "Routes and views (actionpack-minimizer)" => ApMinimizer::Census.report(app.routes, app.paths["app/views"].existent),
          }
          sections.each do |title, result|
            puts title
            result.lines(verbose: verbose).each { puts "  #{it}" }
            puts
          end
        end

        desc "Fail on callback problems (missing targets, chains longer than callback_limit, " \
             "callbacks that save their own record) and an out-of-date manifest"
        task check: :environment do
          app = prepare.call
          options = app.config.rails_minify
          routed = AsMinimizer::Check.routed_actions(app.routes)
          failed = false
          report = lambda do |title, items, mode|
            next puts("#{title}: none") if items.empty?

            puts "#{title}: #{items.size}#{" (warning)" if mode == :warn}"
            items.each { puts "  #{it}" }
            failed ||= mode != :warn
          end

          missing = AsMinimizer::Check.callback_targets(routed: routed).select { it.status == :missing }
          report.("callback targets naming no method", missing, :fail)

          limit = options.callback_limit || 5
          report.("callback chains with more than #{limit} of the app's callbacks",
            AsMinimizer::Check.long_chains(limit: limit, root: app.root.to_s, routed: routed,
              exclude: options.callback_limit_exclude.nil? ? ["ApplicationController"] : Array(options.callback_limit_exclude)),
            (options.callback_limit_mode || :fail).to_sym)

          report.("callbacks saving their own record",
            AsMinimizer::Check.callback_loops(root: app.root.to_s, allow: Array(options.allow_callback_loops)), (options.callback_loops || :fail).to_sym)

          if defined?(ArMinimizer::Census) && app.root.join("config/ar_minimizer.json").exist?
            manifest = ArMinimizer::Census.manifest_state(app.root, ArMinimizer::Index.from_models)
            puts "manifest: #{manifest}"
            failed ||= manifest.start_with?("out of date")
          end
          abort if failed
        end
      end
    end
  end
end

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

        desc "Fail on what would break at runtime or compile stale: missing callback targets, an out-of-date manifest"
        task check: :environment do
          app = prepare.call
          problems = AsMinimizer::Check.callback_targets(routed: AsMinimizer::Check.routed_actions(app.routes))
          missing = problems.select { it.status == :missing }
          missing.each { puts "  #{it}" }
          manifest = ArMinimizer::Census.manifest_state(app.root, ArMinimizer::Index.from_models)
          puts "callback targets: #{missing.size} missing; manifest: #{manifest}"
          abort if missing.any? || manifest.start_with?("out of date")
        end
      end
    end
  end
end

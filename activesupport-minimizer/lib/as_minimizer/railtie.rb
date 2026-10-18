# frozen_string_literal: true

module AsMinimizer
  class Railtie < Rails::Railtie
    config.as_minimizer = ActiveSupport::OrderedOptions.new

    # config.as_minimizer.unroll_callbacks = true   (e.g. config/environments/production.rb)
    # config.as_minimizer.source_dir = "tmp/rails_minify/callbacks"  # write the generated methods out
    initializer "as_minimizer" do |app|
      options = app.config.as_minimizer
      next unless options.unroll_callbacks

      AsMinimizer::Unroller.source_dir = app.root.join(options.source_dir) if options.source_dir
      AsMinimizer::Unroller.install!
    end

    rake_tasks do
      namespace :as_minimizer do
        desc "List callbacks (before_action, before_save, ...) naming methods that don't exist; fails if any"
        task check: :environment do
          Rails.application.eager_load!
          # Routes define methods too (Devise's authenticate_user!); Rails 8 loads them lazily.
          app = Rails.application
          app.respond_to?(:reload_routes_unless_loaded) ? app.reload_routes_unless_loaded : app.reload_routes!
          problems = AsMinimizer::Check.callback_targets(routed: AsMinimizer::Check.routed_actions(app.routes))
          problems.each { puts "  #{it}" }
          missing = problems.count { it.status == :missing }
          puts "as_minimizer: #{missing} missing, #{problems.size - missing} possibly answered by method_missing"
          abort if missing.positive?
        end
      end
    end
  end
end

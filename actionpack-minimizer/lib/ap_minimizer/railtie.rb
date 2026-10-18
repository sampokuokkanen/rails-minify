# frozen_string_literal: true

module ApMinimizer
  class Railtie < Rails::Railtie
    config.ap_minimizer = ActiveSupport::OrderedOptions.new

    # In config/environments/production.rb:
    #
    #   config.ap_minimizer.route_helpers = true  # post_path(post) as string interpolation
    #   config.ap_minimizer.views = true          # literal partial renders and tag helpers precompiled
    #
    # Before routes are drawn, so every helper gets defined through the hook.
    initializer "ap_minimizer", before: :set_routes_reloader_hook do |app|
      options = app.config.ap_minimizer
      ApMinimizer::Routes.install! if options.route_helpers
      ActiveSupport.on_load(:action_view) { ApMinimizer::Views.install! } if options.views
    end
  end
end

# frozen_string_literal: true

module ApMinimizer
  # What the route helper and view compilers cover in an app, and why the
  # rest takes Rails' path.
  module Census
    Result = Data.define(:routes, :views) do
      def lines(verbose: false)
        out = []
        compiled, skipped = routes.partition { |_, why| why.nil? }
        out << "route helpers: #{compiled.size}/#{routes.size} #{Routes.enabled? ? "compiled" : "compilable (config.ap_minimizer.route_helpers is off)"}"
        skipped.group_by(&:last).sort_by { -it[1].size }.each do |why, list|
          out << "  #{list.size} through Rails: #{why}"
          list.first(verbose ? list.size : 3).each { |name, _| out << "    #{name}" }
        end
        compiled = ["render partial", "render record", "link_to", "link_to with a block"]
        done = views.select { |k, _| compiled.include?(k) }.sum(&:last)
        out << "view call sites: #{done}/#{views.values.sum} compiled (#{views["render partial"]} render, #{views["render record"].to_i} render record (collections and components keep Rails' render at runtime), " \
          "#{views["link_to"]} link_to, #{views["link_to with a block"].to_i} link_to with a block)"
        views.reject { |k, _| compiled.include?(k) }.sort_by { -it[1] }.each { |k, n| out << "  #{n} #{k}" }
        out
      end
    end

    class << self
      def report(route_set, view_paths)
        Result.new(routes(route_set), views(view_paths))
      end

      # [[helper name, nil or why not compiled], ...]
      def routes(route_set)
        route_set.named_routes.names.sort.map do |name|
          route = route_set.named_routes.get(name)
          # Positional arguments fill the required segments; constraints there
          # (id: /\d+/) keep Rails' helper. Constraints on optional segments
          # filled from url_options, like (:locale), don't.
          constrained = route.required_parts & route.path.requirements.keys
          why =
            if Routes.glob?(route) then "a glob segment (or unknown: AST already freed)"
            elsif constrained.any? then "constraints on segments arguments fill (#{constrained.join(", ")})"
            end
          ["#{name}_path", why]
        end
      end

      # Counts over every ERB template under the paths, rewritten or not.
      def views(view_paths)
        stats = Hash.new(0)
        Array(view_paths).flat_map { Dir.glob(File.join(it.to_s, "**", "*.erb")) }.each do |file|
          ruby = ActionView::Template::Handlers::ERB::Erubi.new(File.read(file)).src
          Views.rewrite_with_stats(ruby).last.each { |k, n| stats[k] += n }
        rescue StandardError
          stats["templates that didn't compile for the census"] += 1
        end
        stats["render partial"] += 0
        stats["link_to"] += 0
        stats.to_h
      end
    end
  end
end

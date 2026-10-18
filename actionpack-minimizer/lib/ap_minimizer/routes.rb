# frozen_string_literal: true

module ApMinimizer
  # Named route helpers (post_path, post_url, ...) as string interpolation.
  #
  # Rails builds every URL from scratch: the "optimized" path merges hashes
  # and runs the Journey formatter (~1.5 µs); with default_url_options set,
  # as in most apps with a locale in their URLs, every helper takes the full
  # url_for path with recall, defaults and route matching (~6-8 µs).
  #
  # Here the original helper runs once with placeholder arguments,
  #
  #   trip_path("Zq9ArmSentinel0Zq9")  # => "/ja/trips/Zq9ArmSentinel0Zq9"
  #
  # and what surrounds the placeholders is reused:
  #
  #   "/ja/trips/#{escape_segment(trip.to_param)}"
  #
  # That holds for as long as everything else that goes into the URL is the
  # same, so the result is cached by:
  #
  #   - url_options, except the current request's path parameters (_recall):
  #     host, protocol, script name, default_url_options (the locale), ...
  #   - whether Rails would take its optimized path here;
  #   - the helper and the number of arguments, which decide the segment
  #     each argument fills;
  #   - the values of the request's path parameters for the route parts that
  #     neither the arguments nor url_options provide (usually none), since
  #     Rails fills those from the request.
  #
  # The original helper runs instead for an options hash, a nil or empty
  # to_param, more than four arguments, glob routes, arguments filling a
  # constrained segment, and when an argument would land in the query string
  # or anchor, where escaping differs.
  module Routes
    SENTINEL = "Zq9ArmSentinel%dZq9"
    SENTINEL_RE = /Zq9ArmSentinel(\d+)Zq9/
    MAX_ARGS = 4
    MAX_ENTRIES = 4096

    # Unreserved characters are never escaped: most ids and slugs skip the encoder.
    UNRESERVED = /\A[a-zA-Z0-9\-._~]*\z/
    ESCAPE = ->(value) { UNRESERVED.match?(value) ? value : ActionDispatch::Journey::Router::Utils.escape_segment(value) }

    HELPERS = {} # [helpers module, helper name] => UrlHelper
    # Journey route => glob?, recorded when helpers are defined: with eager
    # loading Rails frees each route's AST once routes are finalized, and
    # Route#glob? reads it.
    GLOBS = {}.compare_by_identity
    BASES = {}   # [routes object_id, optimized?, url_options without _recall] => Integer
    META = {}    # [base, helper name, argument count] => recall keys, or false
    PARTS = {}   # [base, helper name, argument count, recall values] => frozen literal parts, or false
    MUTEX = Mutex.new

    class << self
      def install!
        @enabled = true
        @next_base = 0
        collection = ActionDispatch::Routing::RouteSet::NamedRouteCollection
        collection.prepend(Collection) unless collection < Collection
      end

      def enabled? = @enabled == true

      # The url_options part of the cache key, as a small Integer. Computed
      # once per url_options object (Rails memoizes it per request).
      def base_for(context, options)
        key = [context._routes.object_id, context.send(:optimize_routes_generation?), options.except(:_recall)]
        BASES[key] || MUTEX.synchronize do
          reset! if BASES.size >= MAX_ENTRIES
          BASES[key] ||= (@next_base += 1)
        end
      end

      # Literal parts around each argument, or false to always use the original helper.
      def parts_for(context, name, count, base, options)
        meta_key = [base, name, count]
        recall_keys = META.fetch(meta_key) { store(META, meta_key, recall_keys_for(context, name, count, options)) }
        return false unless recall_keys

        recall = options[:_recall] || {}
        key = [base, name, count, recall_keys.map { recall[it] }]
        PARTS.fetch(key) { store(PARTS, key, literal_parts(context, name, count)) }
      end

      # The URL for args, or nil to let the original helper decide (it raises
      # or builds something else for nil, empty or non-String to_param values).
      def fill(parts, args)
        return parts[0].dup if args.empty?

        out = +parts[0]
        args.each_with_index do |arg, i|
          value = arg.to_param
          return nil unless ::String === value && !value.empty?

          out << ESCAPE.(value) << parts[i + 1]
        end
        out
      end

      # True when unknown (the AST is already gone): such routes keep Rails' helper.
      def glob?(route)
        GLOBS.fetch(route) { route.path.ast ? route.glob? : true }
      end

      def define(mod, name, helper)
        HELPERS[[mod, name]] = helper
        route = helper.instance_variable_get(:@route)
        GLOBS[route] = route.path.ast ? route.glob? : true
        mod.alias_method(:"__ap_original_#{name}", name)
        mod.send(:private, :"__ap_original_#{name}")
        mod.module_eval(<<~RUBY, "route helper: #{name}", 1)
          def #{name}(*args)
            ::ApMinimizer::Routes.url_for_args(self, :#{name}, args) || __ap_original_#{name}(*args)
          end
        RUBY
        define_parts_lookup(mod)
      end

      # Shared by every helper: the URL, or nil for the original helper.
      #
      # One small body per helper and the work here, rather than a
      # specialized body per helper: those were 40% faster per call but, with
      # ~1,100 helpers, cost 19 MB and made whole pages slower under YJIT.
      def url_for_args(context, name, args)
        last = args[-1]
        return if args.size > MAX_ARGS || ::Hash === last || ::ActionController::Parameters === last

        parts = context.__send__(:__ap_route_parts, name, args.size) or return
        fill(parts, args)
      end

      private

      def store(table, key, value)
        MUTEX.synchronize do
          reset! if table.size >= MAX_ENTRIES
          table[key] = value
        end
      end

      def reset!
        [BASES, META, PARTS].each(&:clear)
      end

      # Route parts Rails would fill from the current request: those neither
      # the arguments nor url_options and the route's defaults provide. false
      # when the helper can't be compiled for this argument count.
      def recall_keys_for(context, name, count, options)
        owner = context.class.instance_method(:"__ap_original_#{name}").owner
        helper = HELPERS[[owner, name]] or return false
        route = helper.instance_variable_get(:@route)
        return false if glob?(route)

        optimized = helper.is_a?(ActionDispatch::Routing::RouteSet::NamedRouteCollection::UrlHelper::OptimizedUrlHelper) &&
          count == helper.arg_size && context.send(:optimize_routes_generation?)
        return [].freeze if optimized # Rails' optimized path uses neither recall nor defaults

        sentinels = Array.new(count) { format(SENTINEL, it) }
        defaults = options.merge(helper.instance_variable_get(:@options))
        mapped = helper.handle_positional_args(options, {}, sentinels, defaults, route.segment_keys.uniq)
        filled = mapped.select { |_, v| ::String === v && SENTINEL_RE.match?(v) }.keys
        return false unless filled.size == count # an argument with no segment to go to
        return false if filled.any? { route.path.requirements.key?(it) }

        (route.parts - mapped.keys).freeze
      rescue StandardError
        false
      end

      def literal_parts(context, name, count)
        sentinels = Array.new(count) { format(SENTINEL, it) }
        url = context.__send__(:"__ap_original_#{name}", *sentinels)
        return false unless url.scan(SENTINEL_RE).flatten == Array.new(count) { it.to_s }

        # Query strings and anchors escape differently from path segments.
        cut = url.index(/[?#]/)
        return false if cut && count.positive? && url.index(SENTINEL_RE, cut)

        url.split(SENTINEL_RE, -1).values_at(*(0..count).map { it * 2 }).map(&:freeze).freeze
      rescue StandardError
        false
      end

      # In each helper context (controller, view, mailer): the parts for each
      # helper and argument count, for the current url_options object.
      def define_parts_lookup(mod)
        return if mod.private_method_defined?(:__ap_route_parts)

        mod.module_eval(<<~RUBY, __FILE__, __LINE__ + 1)
          private def __ap_route_parts(name, count)
            options = url_options
            memo = @__ap_route_parts
            unless memo && memo[0].equal?(options)
              memo = @__ap_route_parts = [options, ::ApMinimizer::Routes.base_for(self, options), {}]
            end
            by_count = (memo[2][name] ||= [])
            parts = by_count[count]
            parts.nil? ? (by_count[count] = ::ApMinimizer::Routes.parts_for(self, name, count, memo[1], options)) : parts
          rescue ::FrozenError
            nil
          end
        RUBY
      end
    end

    module Collection
      private

      def define_url_helper(mod, name, helper, url_strategy)
        super
        Routes.define(mod, name, helper) if Routes.enabled?
      end
    end
  end
end

# frozen_string_literal: true

module AsMinimizer
  # Callbacks naming methods that don't exist. Rails registers callbacks by
  # name and only finds out when the chain runs: a NoMethodError, for a
  # controller a 500 on every action the filter covers. (Roundhouse's
  # filter_targets check, for a running app.)
  module Check
    Problem = Data.define(:klass, :chain, :kind, :role, :target, :status, :actions) do
      def to_s
        where = actions ? " (#{actions.empty? ? "no action" : actions.join(", ")})" : ""
        verb = status == :missing ? "names no method" : "may be answered by method_missing"
        "#{Check.name_of(klass)}: #{kind}_#{chain} #{role} #{target.inspect} #{verb}#{where}"
      end
    end

    # A chain with more of the app's own callbacks than the limit.
    LongChain = Data.define(:klass, :chain, :callbacks, :limit, :action, :also) do
      def to_s
        where = action ? " (#{action})" : ""
        others = also.empty? ? "" : " (inherited by #{also.size}: #{also.first(3).map { Check.name_of(it) }.join(", ")}#{", ..." if also.size > 3})"
        "#{Check.name_of(klass)}#{others}: #{chain} chain has #{callbacks.size} callbacks#{where}, more than #{limit}\n" +
          callbacks.map { "    #{it}" }.join("\n")
      end
    end

    # A model callback that saves (updates, touches, ...) the record it runs
    # for: that runs the chain again, so it repeats until something stops it.
    Loop = Data.define(:klass, :chain, :callback, :call, :location, :guard) do
      def to_s
        "#{Check.name_of(klass)}: #{callback} calls #{call} on the record itself (#{location}), " \
          "which runs the #{chain} callbacks again#{"; guarded by #{guard}, check it can't stay true" if guard}"
      end
    end

    # Chains whose callbacks are validations, not callbacks.
    SKIP_CHAINS = %i[validate].freeze
    # Model chains a save, update or touch of the same record runs again.
    REENTERED_CHAINS = %i[validation save create update commit touch].freeze
    # Calls on the record itself that run its callbacks (update_column(s) and
    # update_all don't).
    SELF_SAVES = %i[save save! update update! update_attribute update_attributes update_attributes! touch increment! decrement! toggle!].freeze

    # method_missing implementations whose answers are known: attribute methods.
    ATTRIBUTE_METHOD_MISSING = %w[ActiveModel::AttributeMethods ActiveRecord::AttributeMethods ArMinimizer::Slim::Record].freeze
    PLAIN_METHOD_MISSING = %w[BasicObject Kernel].freeze

    # Some classes redefine .name (and raise); Module#name is nil for anonymous ones.
    def self.name_of(klass)
      Module.instance_method(:name).bind_call(klass) || (klass.name rescue nil) || klass.inspect
    rescue StandardError, ScriptError
      klass.inspect
    end

    class << self
      # :present, :missing, or :unknown (the class has its own method_missing).
      def status(klass, name)
        return :present if klass.method_defined?(name) || klass.private_method_defined?(name) || klass.protected_method_defined?(name)
        return :present if attribute_method?(klass, name)

        owner = klass.instance_method(:method_missing).owner.name.to_s
        if PLAIN_METHOD_MISSING.include?(owner) || ATTRIBUTE_METHOD_MISSING.include?(owner)
          :missing
        else
          :unknown
        end
      end

      # Every named class using callbacks, or the ones given. routed:
      # { "PostsController" => Set["show", ...] } limits controllers to the
      # actions a request can reach (public helper methods are actions too).
      def callback_targets(classes = callback_classes, routed: nil)
        @routed = routed
        classes.flat_map { problems_in(it) }
      end

      # From a RouteSet: controller class name => routed action names.
      def routed_actions(routes)
        routes.routes.each_with_object(Hash.new { |h, k| h[k] = Set.new }) do |route, map|
          controller, action = route.defaults.values_at(:controller, :action)
          map["#{controller.camelize}Controller"] << action.to_s if controller && action
        end
      end

      # Chains with more than +limit+ of the app's own callbacks (defined under
      # +root+, not in gems). Controllers: their action with the most.
      # Callbacks a subclass inherits from an +exclude+d class (the
      # ApplicationController default: time zone, locale, current user, ...,
      # the per-request basics) don't count. A class over the limit is reported
      # once, with how many classes inherit its chain; those aren't repeated.
      def long_chains(classes = callback_classes, limit: 5, root:, routed: nil, exclude: ["ApplicationController"])
        @routed = routed
        excluded = exclude.filter_map { Object.const_get(it) if Object.const_defined?(it) }
        reported = {} # [class, chain] => LongChain
        classes.sort_by { it.ancestors.size }.each do |klass|
          next if excluded.include?(klass)

          klass.__callbacks.each do |chain_name, chain|
            next if SKIP_CHAINS.include?(chain_name)
            next if chain.none?

            # Already over the limit in a superclass: covered by that report.
            parent = klass.ancestors.drop(1).find { reported.key?([it, chain_name]) }
            if parent
              reported[[parent, chain_name]].also << klass
              next
            end

            inherited = excluded.select { klass < it && it.respond_to?(:__callbacks) }
                                .flat_map { it.__callbacks[chain_name].to_a }.to_set
            actions = controller_actions(klass, chain_name)
            candidates = actions.nil? || actions.empty? ? [nil] : actions # a base class: all of its callbacks
            action, own = candidates.map do |act|
              [act, chain.select { |cb| !inherited.include?(cb) && (act.nil? || applies?(cb, act)) && own_location(klass, cb, root) }]
            end.max_by { it[1].size }
            next unless own.size > limit

            reported[[klass, chain_name]] = LongChain.new(klass, chain_name, own.map { describe(klass, it, root) }, limit, action, [])
          end
        end
        reported.values
      end

      # Model callbacks (under +root+) that call save, update, touch, ... on
      # the record they run for. allow: ["Trip#recalculate", ...] to accept one.
      def callback_loops(classes = callback_classes, root:, allow: [])
        classes.flat_map do |klass|
          next [] unless defined?(ActiveRecord::Base) && klass < ActiveRecord::Base

          klass.__callbacks.flat_map do |chain_name, chain|
            next [] unless REENTERED_CHAINS.include?(chain_name)

            chain.flat_map do |callback|
              next [] unless (location = own_location(klass, callback, root))
              next [] if allow.include?("#{name_of(klass)}##{callback.filter}")

              self_saves(*location).map do |call, line|
                Loop.new(klass, chain_name, "#{callback.kind}_#{chain_name} #{callback.filter.is_a?(Symbol) ? callback.filter.inspect : "block"}",
                  call, "#{relative(location[0], root)}:#{line}", guard(callback))
              end
            end
          end
        end.uniq { [it.klass, it.callback, it.call, it.location] }
      end

      def callback_classes
        ObjectSpace.each_object(Class).filter_map do |klass|
          name = Module.instance_method(:name).bind_call(klass) # some classes redefine .name (and raise)
          [name, klass] if name && klass < ActiveSupport::Callbacks && klass.respond_to?(:__callbacks)
        rescue StandardError, ScriptError
          nil
        end.sort_by(&:first).map(&:last)
      end

      private

      def problems_in(klass)
        klass.__callbacks.flat_map do |chain_name, chain|
          actions = controller_actions(klass, chain_name)
          next [] if actions&.empty? # abstract controllers: checked through their subclasses

          chain.flat_map do |callback|
            targets(callback).filter_map do |name, role|
              status = status(klass, name)
              next if status == :present

              applies = actions&.select { applies?(callback, it) }
              next if applies&.empty?

              Problem.new(klass, chain_name, callback.kind, role, name, status, applies)
            end
          end
        end
      end

      def targets(callback)
        list = []
        list << [callback.filter, :filter] if callback.filter.is_a?(Symbol)
        (callback.instance_variable_get(:@if) + callback.instance_variable_get(:@unless)).each do |c|
          list << [c, :condition] if c.is_a?(Symbol)
        end
        list
      end

      def controller_actions(klass, chain_name)
        return unless chain_name == :process_action && klass.respond_to?(:action_methods)

        return [] if klass.abstract?

        actions = klass.action_methods.to_a
        actions &= @routed[klass.name].to_a if @routed&.key?(klass.name)
        actions.sort
      end

      def applies?(callback, action)
        callback.instance_variable_get(:@if).all? { !action_filter?(it) || listed?(it, action) } &&
          callback.instance_variable_get(:@unless).none? { action_filter?(it) && listed?(it, action) }
      end

      def action_filter?(c) = defined?(AbstractController::Callbacks::ActionFilter) && c.is_a?(AbstractController::Callbacks::ActionFilter)

      def listed?(filter, action) = filter.instance_variable_get(:@actions).include?(action)

      # [file, line] of the callback's code when it's the app's own (under root, not a gem), else nil.
      def own_location(klass, callback, root)
        filter = callback.filter
        location =
          case filter
          when Symbol then (klass.instance_method(filter).source_location rescue nil)
          when Proc then filter.source_location
          end
        return unless location && location[0].start_with?(root.to_s) && !location[0].match?(%r{/(vendor|gems)/})

        location
      end

      def describe(klass, callback, root)
        file, line = own_location(klass, callback, root)
        name = callback.filter.is_a?(Symbol) ? callback.filter.inspect : "block"
        "#{callback.kind}_#{callback.name} #{name} (#{relative(file, root)}:#{line})"
      end

      def relative(file, root) = file.delete_prefix("#{root}/")

      # The :if/:unless that might stop a loop, as written. Rails' own
      # condition on model after_* callbacks (skip after a halt) isn't one.
      def guard(callback)
        conditions = (callback.instance_variable_get(:@if).map { ["if", it] } + callback.instance_variable_get(:@unless).map { ["unless", it] })
          .reject { |_, c| c.is_a?(ActiveSupport::Callbacks::Conditionals::Value) }
        conditions.filter_map { |kind, c| "#{kind}: #{c.inspect}" if c.is_a?(Symbol) }.first ||
          (conditions.any? ? "a #{conditions.first[0]}: condition" : nil)
      end

      # [[call, line]] for calls in SELF_SAVES on self in the method or block
      # starting at file:line.
      def self_saves(file, line)
        require "prism"
        @parsed ||= {}
        root_node = (@parsed[file] ||= Prism.parse_file(file).value)
        body = find_starting(root_node, line) or return []
        found = []
        walk = lambda do |node|
          if node.is_a?(Prism::CallNode) && SELF_SAVES.include?(node.name) && (node.receiver.nil? || node.receiver.is_a?(Prism::SelfNode))
            found << [node.name.to_s, node.location.start_line]
          end
          node.compact_child_nodes.each(&walk)
        end
        walk.(body)
        found
      end

      def find_starting(node, line)
        return node if (node.is_a?(Prism::DefNode) || node.is_a?(Prism::LambdaNode) || node.is_a?(Prism::BlockNode)) && node.location.start_line == line

        node.compact_child_nodes.each do |child|
          next unless child.location.start_line <= line && child.location.end_line >= line

          found = find_starting(child, line) and return found
        end
        nil
      end

      # name_changed?, saved_change_to_title?, ... for a real attribute (Slim may not have generated it).
      def attribute_method?(klass, name)
        return false unless klass.respond_to?(:attribute_method_patterns) && klass.respond_to?(:attribute_names)

        attributes = klass.attribute_names
        klass.attribute_method_patterns.any? do |pattern|
          attr = pattern.respond_to?(:matched_attribute_name) ? pattern.matched_attribute_name(name.to_s) : pattern.match(name.to_s)&.attr_name
          attr && (attributes.include?(attr) || klass.attribute_alias?(attr))
        end
      rescue StandardError
        false
      end
    end
  end
end

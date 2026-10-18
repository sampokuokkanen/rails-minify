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

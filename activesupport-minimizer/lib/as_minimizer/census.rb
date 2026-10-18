# frozen_string_literal: true

module AsMinimizer
  # How many callback chains the unroller can run, and why the rest run
  # through ActiveSupport. Controllers are checked per routed action.
  module Census
    Result = Data.define(:unrolled, :fallbacks, :problems) do
      # fallbacks: { reason => ["PostsController#process_action[show]", ...] }
      def lines(verbose: false)
        total = unrolled + fallbacks.values.sum(&:size)
        out = ["callback chains: #{unrolled}/#{total} unrolled"]
        fallbacks.sort_by { -it[1].size }.each do |reason, labels|
          out << "  #{labels.size} through ActiveSupport: #{reason}"
          labels.first(verbose ? labels.size : 3).each { out << "    #{it}" }
        end
        missing = problems.count { it.status == :missing }
        out << "callback targets: #{missing} missing, #{problems.size - missing} possibly answered by method_missing"
        problems.each { out << "  #{it}" } if verbose || missing.positive?
        out
      end
    end

    def self.report(classes = Check.callback_classes, routed: nil)
      unrolled = 0
      fallbacks = Hash.new { |h, k| h[k] = [] }
      classes.each do |klass|
        name = Check.name_of(klass)
        klass.__callbacks.each do |kind, chain|
          next if chain.empty?

          # Controllers no route reaches (abstract ones included) never run their chain.
          next if kind == :process_action && klass.respond_to?(:action_methods) && controller_actions(klass, routed).empty?

          begin
            Unroller::Generator.new(klass, kind, chain).source
            unrolled += 1
          rescue Unroller::Unsupported => e
            fallbacks[e.message] << "#{name}##{kind}"
          end
        end
      end
      Result.new(unrolled, fallbacks.to_h, Check.callback_targets(classes, routed: routed))
    end

    def self.controller_actions(klass, routed)
      return [] if klass.abstract?

      actions = klass.action_methods.to_a
      actions &= routed[klass.name].to_a if routed&.key?(klass.name)
      actions.sort
    end
  end
end

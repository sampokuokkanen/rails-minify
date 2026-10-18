# frozen_string_literal: true

require "fileutils"

module AsMinimizer
  # Runs a class's callback chain (controller actions, model save/create/
  # update/destroy/commit, validations, jobs: anything on ActiveSupport::Callbacks)
  # as one generated method, built the first time the chain runs:
  #
  #   before_save :normalize
  #   before_save :check, if: :published?
  #   after_save :notify
  #
  #   # Post#save then runs (abbreviated)
  #   def __as_save
  #     halted = false
  #     value = nil
  #     if !halted
  #       halted = true
  #       catch(:abort) do
  #         self.normalize
  #         halted = false
  #       end
  #       halted_callback_hook(:normalize, :save) if halted
  #     end
  #     ...
  #     value = !halted && (block_given? ? yield : true)
  #     if !halted && ::AsMinimizer::Unroller::OBJECTS[3].call(self, value)
  #       self.notify
  #     end
  #     value
  #   end
  #
  # It follows ActiveSupport::Callbacks#run_callbacks: before callbacks in
  # order, the chain's terminator after each (performed? for controllers,
  # throw :abort for the rest, or any custom terminator), around callbacks
  # nesting the rest of the chain, after callbacks last-defined first and
  # skipped after a halt when the chain says so. For controllers, `only:` and
  # `except:` are decided per action when the method is generated.
  #
  # The generated code is named in backtraces ("unrolled: Post#save"), and with
  # source_dir set, written to a file there, so backtraces point at code you can open.
  module Unroller
    # Filters and conditions that aren't symbols are referenced from here.
    OBJECTS = []
    MUTEX = Mutex.new
    Unsupported = Class.new(StandardError)

    class << self
      attr_accessor :source_dir

      def install!
        @enabled = true
        ActiveSupport::Callbacks.prepend(Hook) unless ActiveSupport::Callbacks < Hook
      end

      def disable! = @enabled = false

      def enabled? = @enabled == true

      # The generated method's name, or nil to let ActiveSupport run the chain.
      def method_for(target, kind)
        klass = target.class
        chain = target.__callbacks[kind]
        action = target.action_name if kind == :process_action && target.respond_to?(:action_name)
        cache = klass.instance_variable_get(:@__as_unrolled) ||
          MUTEX.synchronize { klass.instance_variable_get(:@__as_unrolled) || klass.instance_variable_set(:@__as_unrolled, {}) }
        hit = (per_kind = cache[kind]) && per_kind[action]
        return hit[1] if hit && hit[0].equal?(chain)

        MUTEX.synchronize do
          per_kind = (cache[kind] ||= {})
          hit = per_kind[action]
          return hit[1] if hit && hit[0].equal?(chain)

          name = generate(klass, kind, action, chain)
          per_kind[action] = [chain, name]
          name
        end
      end

      def source_for(klass, kind, action = nil) = Generator.new(klass, kind, action, klass.__callbacks[kind]).source

      private

      def generate(klass, kind, action, chain)
        generator = Generator.new(klass, kind, action, chain)
        body = generator.source
        warn_missing(klass, kind, action, generator.targets)
        name = :"__as_#{kind}#{"_#{action.unpack1("H*")}" if action}"
        label = "#{klass.name || "anonymous"}##{kind}#{"[#{action}]" if action}"
        code = "# #{label} callbacks, unrolled by activesupport-minimizer\ndef #{name}\n#{body}\nend\n"
        klass.class_eval(code, file_for(klass, kind, action, label, code), 1)
        klass.send(:private, name)
        name
      rescue Unsupported
        nil
      end

      # Rails finds out when the chain runs (NoMethodError, a 500 for a
      # controller); say so when the method is generated, once per target.
      def warn_missing(klass, kind, action, targets)
        targets.each do |name, role, callback_kind|
          next unless Check.status(klass, name) == :missing

          @warned ||= {}
          next if @warned[[klass, kind, name]]

          @warned[[klass, kind, name]] = true
          AsMinimizer.warn("activesupport-minimizer: #{klass.name || klass}'s #{callback_kind}_#{kind} #{role} #{name.inspect} " \
            "names no method#{" (action #{action})" if action}; running the chain will raise NoMethodError")
        end
      end

      def file_for(klass, kind, action, label, code)
        return "unrolled: #{label}" unless source_dir

        path = File.join(source_dir.to_s, (klass.name || "anonymous_#{klass.object_id}").gsub("::", "/"),
          "#{kind}#{"_#{action}" if action}.rb")
        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, code)
        path
      end
    end

    module Hook
      def run_callbacks(kind, type = nil, &block)
        if type.nil? && Unroller.enabled? && (name = Unroller.method_for(self, kind))
          __send__(name, &block)
        else
          super
        end
      end
    end

    class Generator
      Level = Struct.new(:befores, :afters, :around, :nested)

      # Symbols the generated code calls (filters and conditions that apply).
      attr_reader :targets

      def initialize(klass, kind, action, chain)
        @klass = klass
        @kind = kind
        @action = action
        @chain = chain
        @config = chain.config
        @lambdas = 0
        @targets = []
      end

      def source
        terminator!
        "halted = false\nvalue = nil\n#{level(levels)}value"
      end

      private

      def terminator!
        terminator = @config[:terminator]
        @terminator =
          if terminator.equal?(ActiveSupport::Callbacks::CallbackChain.const_get(:DEFAULT_TERMINATOR))
            :abort
          elsif terminator.is_a?(Proc) && terminator.source_location&.first&.end_with?("abstract_controller/callbacks.rb")
            :performed
          else
            object(terminator)
          end
        @skip_after = @config[:skip_after_callbacks_if_terminated]
        # With raise_on_missing_callback_actions, only:/except: check the action list at runtime.
        @static_actions = @action && !(@klass.respond_to?(:raise_on_missing_callback_actions) && @klass.raise_on_missing_callback_actions)
      end

      # What CallbackChain#compile builds: each around opens a nested level;
      # befores keep definition order, afters run last-defined first.
      def levels
        current = Level.new([], [], nil, nil)
        @chain.to_a.reverse_each do |callback|
          case callback.kind
          when :before then current.befores.unshift(callback)
          when :after then current.afters.push(callback)
          when :around then current = Level.new([], [], callback, current)
          end
        end
        current
      end

      def level(lvl)
        code = +""
        lvl.befores.each { code << before(it) }
        if lvl.around
          code << around(lvl.around, level(lvl.nested))
        else
          code << "value = !halted && (block_given? ? yield : true)\n"
        end
        lvl.afters.each { code << after(it) }
        code
      end

      def before(callback)
        cond = conditions(callback) or return ""
        call = call(callback, callback.filter)
        check = if cond == "true" then "!halted" else "!halted && #{cond}" end
        hook = "halted_callback_hook(#{literal(callback.filter)}, #{callback.name.inspect})"
        case @terminator
        when :performed
          "if #{check}\n  #{call}\n  if performed?\n    halted = true\n    #{hook}\n  end\nend\n"
        when :abort
          "if #{check}\n  halted = true\n  catch(:abort) do\n    #{call}\n    halted = false\n  end\n  #{hook} if halted\nend\n"
        else
          "if #{check}\n  if #{@terminator}.call(self, -> { #{call} })\n    halted = true\n    #{hook}\n  end\nend\n"
        end
      end

      def after(callback)
        cond = conditions(callback) or return ""
        check = [("!halted" if @skip_after), (cond unless cond == "true")].compact
        call = call(callback, callback.filter)
        check.empty? ? "#{call}\n" : "if #{check.join(" && ")}\n  #{call}\nend\n"
      end

      # The rest of the chain goes in a proc: the around callback gets it as
      # its block, and it runs directly when the around is skipped.
      def around(callback, inner)
        cond = conditions(callback)
        inner_name = "inner#{@lambdas += 1}"
        code = "#{inner_name} = proc do\n#{inner}end\n" # a Proc, as ActiveSupport passes: extra arguments are ignored
        return code << "#{inner_name}.()\n" unless cond

        skip = cond == "true" ? "halted" : "halted || !(#{cond})"
        code << "if #{skip}\n  #{inner_name}.()\nelse\n  #{call(callback, callback.filter, inner_name)}\nend\n"
      end

      # Ruby for the callback's :if/:unless, "true" when there are none, nil
      # when it never runs (an `only:`/`except:` that rules out this action).
      def conditions(callback)
        parts = []
        callback.instance_variable_get(:@if).each do |c|
          if static_action_filter?(c)
            return nil unless action_listed?(c)
          else
            parts << condition(callback, c)
          end
        end
        callback.instance_variable_get(:@unless).each do |c|
          if static_action_filter?(c)
            return nil if action_listed?(c)
          else
            parts << "!(#{condition(callback, c)})"
          end
        end
        parts.empty? ? "true" : parts.join(" && ")
      end

      def static_action_filter?(c)
        @static_actions && defined?(AbstractController::Callbacks::ActionFilter) && c.is_a?(AbstractController::Callbacks::ActionFilter)
      end

      def action_listed?(filter) = filter.instance_variable_get(:@actions).include?(@action)

      # As CallTemplate.build + make_lambda.
      def condition(callback, c)
        case c
        when Symbol then (@targets << [c, :condition, callback.kind]; "self.#{method_call(c)}")
        when ActiveSupport::Callbacks::Conditionals::Value then "#{object(c)}.call(self, value)"
        when Proc
          raise Unsupported, "a condition proc with 2 parameters" if c.arity == 2 # needs a block, which conditions never get: ActiveSupport raises
          [1, -2].include?(c.arity) ? "instance_exec(self, &#{object(c)})" : "instance_exec(&#{object(c)})"
        else "#{object(c)}.#{scope_method(callback)}(self)"
        end
      end

      def call(callback, filter, block = nil)
        case filter
        when Symbol then (@targets << [filter, :filter, callback.kind]; "self.#{method_call(filter)}#{"(&#{block})" if block}")
        when Proc
          case filter.arity
          when 2
            raise Unsupported, "a before/after proc with 2 parameters" unless block # ActiveSupport raises ArgumentError here
            "instance_exec(self, #{block}, &#{object(filter)})"
          when 1, -2 then "instance_exec(self, &#{object(filter)})"
          else "instance_exec(&#{object(filter)})"
          end
        else "#{object(filter)}.#{scope_method(callback)}(#{["self", ("&#{block}" if block)].compact.join(", ")})"
        end
      end

      # The method an object filter answers to: before_save, validate, around, ...
      def scope_method(callback)
        name = Array(@config[:scope]).map { callback.public_send(it) }.join("_")
        method_call(name)
      end

      def method_call(name)
        raise Unsupported, "method name #{name.inspect} isn't an identifier" unless name.to_s.match?(/\A[a-zA-Z_]\w*[?!]?\z/)

        name.to_s
      end

      def literal(filter) = filter.is_a?(Symbol) ? filter.inspect : object(filter)

      def object(obj)
        index = OBJECTS.index { it.equal?(obj) } || (OBJECTS << obj).size - 1
        "::AsMinimizer::Unroller::OBJECTS[#{index}]"
      end
    end
  end
end

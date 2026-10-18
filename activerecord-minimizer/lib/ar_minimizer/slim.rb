# frozen_string_literal: true

module ArMinimizer
  # Prepended to ActiveRecord::Base's singleton class. Skips generating the
  # attribute methods whose proxy is not in +keep+ (by default everything but
  # readers and writers).
  #
  # Strict (the default): those methods are gone. Calling one raises
  # NoMethodError naming its replacement; rubocop-minify rewrites the calls,
  # keep_methods lists what gems call by name.
  #
  # strict: false: they keep working through ActiveModel's method_missing,
  # and with +lazy+ the first call generates that one method on that model.
  module Slim
    # Proxy targets whose methods are still generated: the reader and the writer.
    DEFAULT_KEEP = %w[attribute attribute=].freeze

    MATCH = ActiveModel::AttributeMethods::ClassMethods::AttributeMethodPattern::AttributeMethod

    # Rails asks respond_to? before calling these, and quietly does something
    # else when the answer is no: form fields show the cast value instead of
    # what the user typed, numericality validates the cast value ("abc" -> 0).
    # Strict mode keeps them answering, generated on first call.
    PROBED = { "_before_type_cast" => "attribute_before_type_cast", "_came_from_user?" => "attribute_came_from_user?" }.freeze

    class << self
      attr_reader :keep, :keep_methods

      def keep=(proxies)
        @keep = proxies.map(&:to_s).to_set.freeze
      end

      # Method names ("name_changed?") or "Model#name_changed?" to keep
      # generating: calls in gems or views that would otherwise take the slow
      # path on a hot path. ArMinimizer::Profile lists them.
      def keep_methods=(names)
        @keep_methods = names.map { it.to_s.strip }.reject(&:empty?).to_set.freeze
      end

      # One "name" or "Model#name" per line; " # ..." starts a comment.
      def parse_keep_file(text)
        text.lines.map { it.sub(/(\A|\s)#.*/, "").strip }.reject(&:empty?)
      end

      def enabled? = @enabled == true

      def lazy? = @lazy == true

      def strict? = @strict == true

      # Call before any model instantiates (an initializer is fine).
      #
      # strict: the skipped methods are gone, not generated on first call:
      # calling one raises NoMethodError naming its replacement
      # (attribute_changed?(:name) for name_changed?), respond_to? says no,
      # and records answer respond_to?/method_missing for unknown names
      # without ActiveModel's scan over every attribute method pattern.
      # rubocop-minify rewrites the calls.
      def enable!(keep: DEFAULT_KEEP, keep_methods: [], lazy: true, strict: true)
        self.keep = keep
        self.keep_methods = keep_methods
        @strict = strict
        @lazy = lazy && !strict
        @enabled = true
        ActiveRecord::Base.singleton_class.prepend(self) unless ActiveRecord::Base.singleton_class < self
        ActiveRecord::Base.prepend(Record) unless ActiveRecord::Base < Record
        reset_models
      end

      def disable!
        @enabled = false
        @strict = false
        reset_models
      end

      # The class's own String for an attribute name (what generated methods
      # pass), so records don't keep copies made by method-name matching.
      def canonical_name(klass, name)
        names = klass.instance_variable_get(:@__arm_attribute_names) ||
          klass.instance_variable_set(:@__arm_attribute_names, klass.attribute_names.to_h { [it, it] }.freeze)
        names[name] || name
      end

      def skip?(model, pattern, attr_name, name)
        return false unless enabled?
        return false if Thread.current[:ar_minimizer_generating] == name
        return false if keep.include?(pattern.proxy_target)
        return false if keep_methods.include?(name) || keep_methods.include?("#{model.name}##{name}")

        !framework_calls?(model, pattern.proxy_target, attr_name.to_s)
      end

      # For the strict-mode error: the call that replaces a removed method.
      def replacement(model, name)
        model.attribute_method_patterns.each do |pattern|
          next if keep.include?(pattern.proxy_target)

          attr = pattern.respond_to?(:matched_attribute_name) ? pattern.matched_attribute_name(name) : pattern.match(name)&.attr_name
          next unless attr && (model._has_attribute?(attr) || model.attribute_alias?(attr))

          proxy = pattern.proxy_target == "attribute?" ? "query_attribute" : pattern.proxy_target
          args = pattern.parameters == false ? ":#{attr}" : ":#{attr}, ..."
          return "#{proxy}(#{args})#{" (private: on self)" unless ActiveRecord::Base.public_method_defined?(proxy)}"
        end
        nil
      end

      # Generates the skipped method +name+ on +model+, as ActiveRecord would
      # have. Only for the class's own attributes and aliases: columns that
      # only some query selects (`AS trips_count`) never get methods in Rails either.
      def generate(model, name, match)
        return unless model._has_attribute?(match.attr_name) || model.attribute_alias?(match.attr_name)

        pattern = model.attribute_method_patterns.find { it.proxy_target == match.proxy_target }
        target = model.attribute_aliases[match.attr_name]
        ActiveRecord::AttributeMethods::GeneratedAttributeMethods::LOCK.synchronize do
          Thread.current[:ar_minimizer_generating] = name
          ActiveSupport::CodeGenerator.batch(model.send(:generated_attribute_methods), __FILE__, __LINE__) do |owner|
            if target
              model.send(:define_attribute_method_pattern, pattern, target, owner: owner, as: match.attr_name, override: true)
            else
              model.send(:define_attribute_method_pattern, pattern, match.attr_name, owner: owner, as: match.attr_name)
            end
          end
        ensure
          Thread.current[:ar_minimizer_generating] = nil
        end
      end

      private

      # For models loaded before the switch. ActiveRecord only undefines once
      # attribute methods were generated, but alias_attribute defines its
      # methods right away, in the class body.
      def reset_models
        ActiveRecord::Base.descendants.each do |model|
          model.undefine_attribute_methods
          model.send(:generated_attribute_methods).module_eval { undef_method(*instance_methods(false)) }
        end
      end

      # Methods Rails itself calls by name on hot paths.
      def framework_calls?(model, proxy, attr)
        case proxy
        # every enum predicate (`published?`) and enum scope calls status_for_database
        when "attribute_for_database" then model.defined_enums.key?(attr)
        # cache_version, on every cache key with recyclable cache keys
        when "attribute_before_type_cast", "attribute_came_from_user?" then attr == "updated_at"
        else false
        end
      end
    end

    def define_attribute_method_pattern(pattern, attr_name, owner:, as:, override: false) # :nodoc:
      name = pattern.method_name(as)
      # alias_attribute passes override: true (and attr_name: the aliased
      # attribute); Record teaches method_missing to resolve those.
      return super unless Slim.skip?(self, pattern, attr_name, name)
      # Only real attributes: the slow path can't find anything else (gems such
      # as activerecord-typedstore call define_attribute_method for store keys).
      return super unless _has_attribute?(attr_name.to_s)

      # A hand-written method of the same name may call `super`, which needs
      # the generated method to exist.
      return super if method_defined?(name) || private_method_defined?(name)

      # Still raise DangerousAttributeError where ActiveRecord would.
      instance_method_already_implemented?(name) unless override
      nil
    end

    # What the slow path needs to stand in for the skipped methods.
    module Record
      # ActiveModel's method_missing only knows real attributes: with
      # `alias_attribute :title, :name`, title_changed? must become
      # attribute_changed?("name"). Rails aliases id_value to id on every model.
      def attribute_missing(match, ...)
        return super unless Slim.enabled?

        # The name comes from a regex match, a new String each time, and the
        # record's attribute set keeps whatever String it gets as a key. Pass
        # the class's own name String, as generated methods do.
        target = self.class.attribute_aliases[match.attr_name] || match.attr_name
        __send__(match.proxy_target, Slim.canonical_name(self.class, target), ...)
      end

      private

      # ActiveModel overrides respond_to? but not respond_to_missing?, so
      # without this `user.method(:name_changed?)` raises NameError.
      def respond_to_missing?(name, include_private = false)
        # Strict: matched_attribute_method only matches readers, writers and
        # the PROBED patterns.
        super || (Slim.enabled? && !matched_attribute_method(name.to_s).nil?)
      end

      # ActiveModel's method_missing gives up on anything respond_to? (and so
      # respond_to_missing? above) says exists; dispatch pattern matches here.
      def method_missing(name, ...)
        return super unless Slim.enabled?

        self.class.define_attribute_methods
        match = matched_attribute_method(name.name)
        unless match
          if Slim.strict? && (replacement = Slim.replacement(self.class, name.name))
            raise NoMethodError.new("#{name} was removed by activerecord-minimizer's strict mode; use #{replacement}",
              name, receiver: self)
          end
          return super
        end

        Slim.generate(self.class, name.name, match) if Slim.lazy? || Slim::PROBED.value?(match.proxy_target)
        attribute_missing(match, ...)
      end

      # Strict: only readers and writers are left to match (columns only some
      # query selects, `AS trips_count`), so check those two directly instead
      # of every pattern ActiveModel knows.
      def matched_attribute_method(method_name)
        return super unless Slim.strict?

        Slim::PROBED.each do |suffix, proxy|
          next unless method_name.end_with?(suffix)

          attr = method_name.delete_suffix(suffix)
          klass = self.class
          return Slim::MATCH.new(proxy, attr) if klass._has_attribute?(attr) || klass.attribute_aliases.key?(attr) || @attributes&.key?(attr)
        end

        writer = method_name.end_with?("=")
        attr = writer ? method_name.delete_suffix("=") : method_name
        # The class's own attributes have generated readers and writers; what
        # reaches here is columns only this query has, or aliases.
        return unless @attributes&.key?(attr) || self.class.attribute_aliases.key?(attr)

        Slim::MATCH.new(writer ? "attribute=" : "attribute", attr)
      end

      # ActiveModel's matched_attribute_method asks this for each candidate
      # attribute, and only knows the attributes this instance loaded. That
      # still has to work for columns only this query has (`select("COUNT(*)
      # AS trips_count")`), but on a partial select (`select(:id)`) name_changed?
      # would raise NoMethodError where the generated method answers. Accept the
      # class's attributes and aliases too, as the generated methods would.
      def attribute_method?(attr_name)
        return super unless Slim.enabled?

        # Rails' check materializes the attribute in a lazy attribute set,
        # keyed by the String it gets: give it the class's own.
        attr_name = Slim.canonical_name(self.class, attr_name)
        return true if super

        klass = self.class
        klass._has_attribute?(attr_name) || klass._has_attribute?(klass.attribute_aliases[attr_name].to_s)
      end
    end
  end
end

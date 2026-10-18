# frozen_string_literal: true

module ArMinimizer
  # Enum predicates and bang methods as ordinary methods.
  #
  # Rails defines them with closures, and each predicate call builds and
  # interns the `<name>_for_database` symbol before calling it:
  #
  #   # def active?() status_for_database == 0 end      (Rails' own comment)
  #   define_method("#{value_method_name}?") { public_send(:"#{name}_for_database") == value }
  #
  # Here the enum's literal data goes into the method source instead, as
  # Roundhouse does for macros with literal arguments:
  #
  #   def active? = public_send(:status_for_database) == 0
  #   def active! = update!("status" => 0)
  #
  # Rails still runs first (conflict detection, scopes); only the two methods
  # are replaced. Rails allows booleans, integers, floats, symbols and strings
  # as values; non-finite floats, and method names that aren't plain
  # identifiers, keep Rails' closures.
  module Enums
    IDENTIFIER = /\A[a-zA-Z_][a-zA-Z0-9_]*\z/

    class << self
      # Before models load (their class bodies declare the enums).
      def install!
        @enabled = true
        mod = ActiveRecord::Enum.const_get(:EnumMethods)
        mod.prepend(Definer) unless mod < Definer
      end

      def disable! = @enabled = false

      def enabled? = @enabled == true

      def literal(value)
        case value
        when Integer, String, Symbol, true, false, nil then value.inspect
        when Float then value.inspect if value.finite?
        end
      end
    end

    module Definer
      private

      def define_enum_methods(name, value_method_name, value, scopes, instance_methods)
        super
        return unless instance_methods && Enums.enabled?
        return unless value_method_name.match?(IDENTIFIER) && (literal = Enums.literal(value))

        remove_method(:"#{value_method_name}?", :"#{value_method_name}!")
        module_eval(<<~RUBY, "enum #{klass.name}.#{name}", 1)
          def #{value_method_name}? = public_send(#{:"#{name}_for_database".inspect}) == #{literal}
          def #{value_method_name}! = update!(#{name.inspect} => #{literal})
        RUBY
      end
    end
  end
end

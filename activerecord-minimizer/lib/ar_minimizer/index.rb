# frozen_string_literal: true

module ArMinimizer
  # Which method names the rewriter may compile, built from the loaded models.
  # A name qualifies when, in every model that has it, it is a generated
  # attribute method for the same attribute and proxy, e.g. "name_changed?" ->
  # attribute_changed?("name"). It is dropped if any model defines it by hand
  # (the hand-written method must keep running) or uses it as a column.
  class Index
    # classes: names of the models that have the attribute, for the call-site guard.
    # query: for name?, what the column's values let it compile to (see QUERY).
    Entry = Data.define(:proxy, :attr, :args, :classes, :query) do
      # The proxy as callable on an explicit receiver: public ones directly,
      # private ones (attribute_will_change!, ...) are nil and go through __send__.
      def public_proxy = PUBLIC_ALIASES.fetch(proxy) { ActiveRecord::Base.public_method_defined?(proxy) ? proxy : nil }

      def same_method?(other) = [proxy, attr, args] == [other.proxy, other.attr, other.args]
    end

    # What the index needs to know about one model; also what Manifest stores.
    #   attributes: { "name" => :string, ... } (query kind, or nil)
    #   patterns: [[prefix, suffix, proxy, takes_arguments], ...]
    #   hand_written: generated-method names the model defines itself
    #   superclass: the parent model's name, if it's a model
    #   modules: the app's own modules among its ancestors (concerns)
    #   associations: { "site" => ["Site", "one"], "items" => ["Item", "many"] }, not polymorphic
    #   scopes: names defined with `scope` (they return relations of the model)
    #   shadows: generated-method names of other models' attributes that this
    #     model defines some other way (an enum predicate, a delegate, ...)
    Model = Data.define(:name, :attributes, :primary_key, :patterns, :hand_written, :superclass, :modules, :associations, :scopes, :shadows) do
      def initialize(superclass: nil, modules: [], associations: {}, scopes: [], shadows: [], **rest) = super
    end

    PUBLIC_ALIASES = { "attribute?" => "query_attribute" }.freeze

    # query_attribute on a real column comes down to: true -> true, false/nil
    # -> false, else !value.zero? if it has zero?, else !value.blank?. A
    # column's type fixes which of those can happen. Decorated types (enums,
    # time zone conversion, encrypts, serialize, normalizes) aren't listed and
    # keep query_attribute.
    QUERY = [
      [ActiveModel::Type::Boolean, :truthy], # true, false, nil
      [ActiveModel::Type::Date, :truthy], [ActiveModel::Type::DateTime, :truthy], [ActiveModel::Type::Time, :truthy],
      [ActiveModel::Type::Integer, :numeric], [ActiveModel::Type::Float, :numeric], [ActiveModel::Type::Decimal, :numeric],
      [ActiveModel::Type::ImmutableString, :string], # and String, Text
    ].freeze

    attr_reader :entries, :models, :keep

    def self.from_models(models = ActiveRecord::Base.descendants, keep: Slim.keep || Slim::DEFAULT_KEEP)
      new(describe_all(models), keep: keep)
    end

    def self.table?(model)
      model.table_exists?
    rescue StandardError
      false
    end

    def self.describe(model)
      attributes = model.attribute_names.to_h { [it, query_kind(model, it)] }
      patterns = model.attribute_method_patterns.map { [it.prefix, it.suffix, it.proxy_target, it.parameters != false] }
      names = patterns.flat_map { |prefix, suffix, _| attributes.keys.map { "#{prefix}#{it}#{suffix}" } }
      parent = model.superclass
      Model.new(name: constant_name(model), attributes: attributes, primary_key: Array(model.primary_key), patterns: patterns,
        hand_written: names.select { hand_written?(model, it) }.sort,
        superclass: (constant_name(parent) if parent < ActiveRecord::Base && !parent.abstract_class?),
        modules: app_modules(model), associations: associations(model), scopes: scopes(model))
    end

    def self.associations(model)
      model.reflect_on_all_associations.each_with_object({}) do |reflection, map|
        next if reflection.polymorphic?

        target = constant_name(reflection.klass)
        map[reflection.name.to_s] = [target, reflection.collection? ? "many" : "one"] if target
      rescue StandardError, NameError
        nil
      end.sort.to_h
    end

    # Class methods `scope` defined: on the model (or a parent model) itself,
    # with ActiveRecord's scoping code as their source.
    def self.scopes(model)
      model.singleton_methods.select do |name|
        method = model.method(name)
        owner = method.owner
        owner.singleton_class? && owner.attached_object.is_a?(Class) && model <= owner.attached_object &&
          method.source_location&.first.to_s.end_with?("active_record/scoping/named.rb")
      rescue StandardError
        false
      end.map(&:to_s).sort
    end

    # Named modules among the model's ancestors that the app defines (not gems
    # or Ruby): the concerns whose methods run with a record as self.
    def self.app_modules(model)
      model.ancestors.take_while { !it.equal?(ActiveRecord::Base) }.filter_map do |mod|
        next if mod.is_a?(Class) || !(name = constant_name(mod))

        file = Module.const_source_location(name)&.first.to_s
        name unless file.empty? || file.include?("/gems/") || file.start_with?(RbConfig::CONFIG["rubylibdir"])
      rescue StandardError
        nil
      end.sort
    end

    # The name, if it leads back to the class: call-site guards reference it
    # as a constant. HABTM join models all call themselves "HABTM_<Association>".
    def self.constant_name(model)
      name = model.name
      name if name && Object.const_get(name).equal?(model)
    rescue NameError
      nil
    end

    # The compiled form of name? calls the reader, so it must be the generated one.
    def self.query_kind(model, attr)
      return if hand_written?(model, attr) || model.defined_enums.key?(attr)

      type = model.type_for_attribute(attr)
      QUERY.find { |klass, _| type.is_a?(klass) }&.last
    end

    def self.hand_written?(model, name)
      return false unless model.method_defined?(name) || model.private_method_defined?(name)

      !model.instance_method(name).owner.is_a?(ActiveRecord::AttributeMethods::GeneratedAttributeMethods)
    end

    def initialize(models, keep:)
      @models = models.sort_by { it.name.to_s }.freeze
      @keep = keep.map(&:to_s).sort.freeze
      found = {} # name => [proxy, attr, args, classes, query]
      poisoned = Set.new
      @models.each do |model|
        model.patterns.each do |prefix, suffix, proxy, args|
          skip_all = @keep.include?(proxy)
          model.attributes.each do |attr, query|
            name = "#{prefix}#{attr}#{suffix}"
            next if poisoned.include?(name)
            next poisoned << name if skip_all || model.primary_key.include?(attr) || model.hand_written.include?(name)

            query = nil unless proxy == "attribute?"
            if (seen = found[name])
              next poisoned << name unless seen[0] == proxy && seen[1] == attr && seen[2] == args

              seen[3] << model.name if model.name
              seen[4] = nil unless seen[4] == query
            else
              found[name] = [proxy, attr, args, model.name ? [model.name] : [], query]
            end
          end
        end
      end
      @entries = found.each_with_object({}) do |(name, (proxy, attr, args, classes, query)), entries|
        entries[name] = Entry.new(proxy, attr, args, classes.sort!.freeze, query) unless poisoned.include?(name)
      end.freeze
    end

    def [](name) = @entries[name.to_s]

    def model?(name) = by_name.key?(name)

    def app_module?(name) = includers.key?(name)

    # The model and every model below it.
    def with_descendants(name)
      @with_descendants ||= {}
      @with_descendants[name] ||= begin
        children = @models.select { it.superclass == name }.map(&:name)
        ([name] + children.flat_map { with_descendants(it) }).uniq.freeze
      end
    end

    # [class name, "one" or "many"] for model#name, or nil.
    def association(model, name) = by_name[model]&.associations&.[](name.to_s)

    def scope?(model, name) = by_name[model]&.scopes&.include?(name.to_s) || false

    # Models (and their subclasses) that include the module.
    def includers_of(name) = includers.fetch(name, [])

    # Would the entry's method on any of these classes be the generated one?
    def covers?(entry, classes) = classes.all? { entry.classes.include?(it) }

    def ==(other) = other.is_a?(Index) && entries == other.entries

    # Same input, same index: what Manifest stores and compares.
    def self.describe_all(models = ActiveRecord::Base.descendants)
      described = models.reject { it.abstract_class? || !table?(it) }.to_h { [it, describe(it)] }
      generated = described.values.flat_map { |m| m.patterns.flat_map { |prefix, suffix, _| m.attributes.keys.map { "#{prefix}#{it}#{suffix}" } } }.uniq
      described.map do |model, m|
        own = m.patterns.flat_map { |prefix, suffix, _| m.attributes.keys.map { "#{prefix}#{it}#{suffix}" } }.to_set
        shadows = generated.select { !own.include?(it) && (model.method_defined?(it) || model.private_method_defined?(it)) && !ActiveRecord::Base.method_defined?(it) }
        shadows.empty? ? m : m.with(shadows: shadows.sort)
      end
    end

    # Models that define name without it being their attribute method.
    def shadowed(name)
      @shadowed ||= @models.each_with_object({}) { |m, map| m.shadows.each { (map[it] ||= []) << m.name } }
      @shadowed.fetch(name.to_s, [])
    end

    def size = @entries.size

    private

    def by_name = @by_name ||= @models.to_h { [it.name, it] }

    def includers
      @includers ||= @models.each_with_object(Hash.new { |h, k| h[k] = [] }) do |model, map|
        model.modules.each { map[it] |= with_descendants(model.name) }
      end
    end
  end
end

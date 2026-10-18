# frozen_string_literal: true

module ArMinimizer
  # Records that never need a Hash don't get one.
  #
  # A record loaded from the database owns two Hashes that most records never
  # put anything in, 160 bytes each on Ruby 4.0 (a fresh record owns about
  # 1,500 bytes all told):
  #
  #   @association_cache   filled when an association is loaded
  #   @attributes.@attributes   filled when an Attribute object is built:
  #                        dirty tracking, writes, keys, ... Plain reads go
  #                        through LazyAttributeSet#fetch_value and don't.
  #
  # Both start as one shared frozen empty Hash and get their own the first
  # time something goes in. Only that shared Hash is swapped: attributes
  # frozen by `destroy`/`freeze` still raise FrozenError on write, as in Rails.
  module SmallRecords
    EMPTY = {}.freeze

    class << self
      def install!
        @enabled = true
        ActiveModel::LazyAttributeSet.prepend(AttributeSet) unless ActiveModel::LazyAttributeSet < AttributeSet
        ActiveRecord::Associations.prepend(Associations) unless ActiveRecord::Associations < Associations
      end

      def disable! = @enabled = false

      def enabled? = @enabled == true
    end

    module AttributeSet
      # Rails 8.0/8.1 pass no attributes for a new set; main passes a fresh
      # {} (and default_keys after it). Either way, an empty Hash only this
      # set would own becomes the shared one.
      def initialize(values, types, additional_types, default_attributes, attributes = nil, *rest)
        attributes = EMPTY if SmallRecords.enabled? && (attributes.nil? || (attributes.empty? && !attributes.frozen?))
        super(values, types, additional_types, default_attributes, attributes || {}, *rest)
      end

      def []=(name, value)
        @attributes = {} if @attributes.equal?(EMPTY)
        super
      end

      def write_from_database(name, value)
        @attributes = {} if @attributes.equal?(EMPTY)
        super
      end

      def write_from_user(name, value)
        @attributes = {} if @attributes.equal?(EMPTY) && !frozen?
        super
      end

      def write_cast_value(name, value)
        @attributes = {} if @attributes.equal?(EMPTY)
        super
      end

      def reverse_merge!(target_attributes)
        @attributes = {} if @attributes.equal?(EMPTY)
        super
      end

      # Rails clones the Hash; a clone of the shared one would be frozen but
      # not the shared one, so writes would raise.
      def initialize_clone(other)
        super
        @attributes = EMPTY if other.instance_variable_get(:@attributes).equal?(EMPTY)
      end

      private

      def default_attribute(name, ...)
        @attributes = {} if @attributes.equal?(EMPTY)
        super
      end
    end

    module Associations
      # Only a Hash Rails allocated is replaced: Rails main leaves the cache
      # nil until an association is used.
      def initialize_dup(*)
        super
        @association_cache = EMPTY if SmallRecords.enabled? && @association_cache
      end

      private

      def init_internals
        super
        @association_cache = EMPTY if SmallRecords.enabled? && @association_cache # Rails' {} is dropped right away
      end

      def association_instance_set(name, association)
        @association_cache = {} if @association_cache.equal?(EMPTY)
        super
      end
    end
  end
end

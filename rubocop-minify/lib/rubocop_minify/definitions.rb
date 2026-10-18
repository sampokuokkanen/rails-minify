# frozen_string_literal: true

require "prism"

module RubocopMinify
  # Hand-written methods in the app, by name: { "featured?" => "app/models/poro.rb:12" }.
  # def, define_method, alias, alias_method, attr_*, delegate and def_delegator(s).
  module Definitions
    DEFINERS = %i[define_method alias_method attr_reader attr_writer attr_accessor delegate def_delegator def_delegators].freeze

    def self.scan(root, patterns)
      found = {}
      patterns.flat_map { Dir.glob(it, base: root) }.sort.each do |path|
        walk(Prism.parse_file(File.join(root, path)).value, path, found)
      end
      found
    end

    def self.walk(node, path, found)
      case node
      when Prism::DefNode
        found[node.name.to_s] ||= "#{path}:#{node.location.start_line}"
      when Prism::AliasMethodNode
        found[node.new_name.slice.delete_prefix(":")] ||= "#{path}:#{node.location.start_line}" if node.new_name.is_a?(Prism::SymbolNode)
      when Prism::CallNode
        if DEFINERS.include?(node.name)
          symbols = node.arguments&.arguments&.grep(Prism::SymbolNode) || []
          symbols = symbols.first(1) if %i[define_method alias_method].include?(node.name)
          symbols = symbols.drop(1) if node.name == :def_delegators # the accessor comes first
          symbols.each { found[it.unescaped] ||= "#{path}:#{node.location.start_line}" }
        end
      end
      node&.compact_child_nodes&.each { walk(it, path, found) }
    end
  end
end

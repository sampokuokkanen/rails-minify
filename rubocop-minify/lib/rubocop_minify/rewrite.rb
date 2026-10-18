# frozen_string_literal: true

require "prism"

module RubocopMinify
  # Finds calls to the attribute methods activerecord-minimizer's strict mode
  # removes and what each stood for:
  #
  #   venue.featured?            -> venue.featured.present?   (venue.featured in a condition)
  #   venue.name?                -> venue.name.present?
  #   venue.rank?                -> venue.query_attribute(:rank)
  #   venue.name_changed?(to: x) -> venue.attribute_changed?(:name, to: x)
  #   before_save :x, if: :name_changed?  -> if: -> { attribute_changed?(:name) }
  #
  # Which names are removed, for which attribute and with which column type
  # comes from the ar_minimizer manifest (an ArMinimizer::Index). Receivers
  # aren't typed: a name is rewritten wherever it's called on an explicit
  # receiver, unless the app also defines a method of that name somewhere
  # (+defined+), and then it's only reported. Calls without a receiver are
  # only rewritten inside models and the app modules they include.
  class Rewrite
    # Byte offsets into the source. replacement nil: reported, not rewritten.
    Edit = Data.define(:from, :to, :replacement, :message)

    SEND = %i[send public_send __send__ try try!].freeze
    # A removed name that core classes also define (key?, empty?, ...) is
    # far more often one of those.
    CORE = [Object, Kernel, Comparable, Enumerable, Hash, Array, String, Symbol, Integer, Float, NilClass, Range, Set].freeze
    CALLBACK_OPTIONS = %i[if unless].freeze

    # defined: { method name => "path:line" } of hand-written methods.
    # views: the source is template code (self is a view, never a record).
    def initialize(index, defined: {}, views: false)
      @index = index
      @defined = defined
      @views = views
    end

    def edits(source)
      root = Prism.parse(source).value
      @edits = []
      @nesting = []
      @class_level = 0
      @locals = locals(root)
      visit(root, false)
      @edits.sort_by(&:from)
    end

    # Applies the rewritable edits that don't overlap (nested ones are left
    # for the next pass), from the end so offsets stay valid.
    def self.apply(source, edits)
      out = source.b
      last = nil
      edits.select(&:replacement).sort_by { -it.from }.each do |edit|
        next if last && edit.to > last

        out.bytesplice(edit.from, edit.to - edit.from, edit.replacement.b)
        last = edit.from
      end
      out.force_encoding(source.encoding)
    end

    private

    # cond: only the value's truthiness matters here (if/unless/while
    # conditions, the operand of !, and/or inside those).
    def visit(node, cond)
      case node
      when Prism::IfNode, Prism::UnlessNode, Prism::WhileNode, Prism::UntilNode
        visit(node.predicate, true)
        node.compact_child_nodes.each { visit(it, false) unless it.equal?(node.predicate) }
      when Prism::AndNode, Prism::OrNode
        visit(node.left, cond)
        visit(node.right, cond)
      when Prism::ParenthesesNode
        body = node.body
        if body.is_a?(Prism::StatementsNode) && body.body.size == 1
          visit(body.body[0], cond)
        else
          visit_children(node)
        end
      when Prism::ClassNode, Prism::ModuleNode
        @nesting.push(node.constant_path.slice.delete_prefix("::"))
        outer, @class_level = @class_level, 0
        visit_children(node)
        @class_level = outer
        @nesting.pop
      when Prism::SingletonClassNode, Prism::DefNode
        # class << self and def self.x: self is the class, not a record
        class_level = node.is_a?(Prism::SingletonClassNode) || node.receiver
        @class_level += 1 if class_level
        visit_children(node)
        @class_level -= 1 if class_level
      when Prism::CallNode
        if node.name == :! && node.receiver && !node.arguments
          visit(node.receiver, true)
        elsif (edit = call_edit(node, cond))
          @edits << edit
          visit_children(node) unless edit.replacement # its parts are copied into the replacement
        else
          symbol_edits(node)
          visit_children(node)
        end
      when nil
      else
        visit_children(node)
      end
    end

    def visit_children(node) = node.compact_child_nodes.each { visit(it, false) }

    def call_edit(node, cond)
      name = node.name.to_s
      entry = @index[name] or return
      return if node.block || core?(name)
      return if node.arguments && !entry.args # the generated method takes none: something else

      receiver = node.receiver
      implicit = receiver.nil? || receiver.is_a?(Prism::SelfNode)
      if implicit
        return if @views

        case self_coverage(entry)
        when :all then nil # self is always a record with the attribute
        when :some then return edit(node, nil, "#{name} is removed by strict mode from #{models(entry)}, but not every class this code runs in has it: rewrite by hand")
        else return # not a record with the attribute: an enum predicate, a helper, ...
        end
      else
        if (where = @defined[name])
          return edit(node, nil, "#{name} is removed by strict mode from #{models(entry)}, but #{where} defines a method of that name: rewrite calls on those records by hand")
        end
        if (others = @index.shadowed(name)).any?
          return edit(node, nil, "#{name} is removed by strict mode from #{models(entry)}, but #{others.first(4).join(", ")} define#{"s" if others.size == 1} it otherwise (an enum, a delegate, ...): rewrite calls on those records by hand")
        end
      end

      replacement = call_replacement(node, entry, cond)
      message = replacement ? "#{name} is removed by strict mode; use #{replacement}" : "#{name} is removed by strict mode; call #{entry.proxy}(#{symbol(entry.attr)}, ...) on the record itself (it's private)"
      edit(node, replacement, message)
    end

    def call_replacement(node, entry, cond)
      receiver = node.receiver
      prefix = receiver ? "#{receiver.slice}#{node.call_operator}" : ""

      if entry.proxy == "attribute?"
        reader = receiver || !@locals.include?(entry.attr) ? "#{prefix}#{entry.attr}" : "self.#{entry.attr}"
        case entry.query
        when :truthy then return cond ? reader : "#{reader}.present?" # true, false, nil, or a date/time
        when :string then return "#{reader}.present?"
        end
      end

      args = [symbol(entry.attr), node.arguments&.slice].compact.join(", ")
      if (proxy = entry.public_proxy)
        "#{prefix}#{proxy}(#{args})"
      elsif receiver.nil? || receiver.is_a?(Prism::SelfNode)
        "#{prefix}#{entry.proxy}(#{args})" # private, callable on self
      end
    end

    # Method names passed as symbols: callback conditions become lambdas;
    # send/try/delegate are reported.
    def symbol_edits(node)
      if SEND.include?(node.name) && (first = node.arguments&.arguments&.first).is_a?(Prism::SymbolNode)
        report_symbol(first, "#{first.unescaped} is removed by strict mode; call what it stood for instead of #{node.name}")
      elsif node.name == :delegate && node.receiver.nil?
        node.arguments&.arguments&.grep(Prism::SymbolNode)&.each do
          report_symbol(it, "#{it.unescaped} is removed by strict mode, so delegating it raises; delegate the reader and define the method")
        end
      end

      keywords = node.arguments&.arguments&.grep(Prism::KeywordHashNode)&.flat_map(&:elements) || []
      keywords.each do |pair|
        next unless pair.is_a?(Prism::AssocNode) && pair.key.is_a?(Prism::SymbolNode) && CALLBACK_OPTIONS.include?(pair.key.unescaped.to_sym)

        values = pair.value.is_a?(Prism::ArrayNode) ? pair.value.elements : [pair.value]
        values.grep(Prism::SymbolNode).each { callback_edit(it) }
      end
    end

    def callback_edit(sym)
      name = sym.unescaped
      entry = @index[name] or return
      case self_coverage(entry)
      when :all then nil
      when :some then return report_symbol(sym, "#{name} is removed by strict mode from #{models(entry)}, but not every class this code runs in has it")
      else return
      end

      body =
        if entry.proxy == "attribute?" && entry.query == :truthy
          entry.attr # callback conditions only test truthiness
        elsif entry.proxy == "attribute?" && entry.query == :string
          "#{entry.attr}.present?"
        else
          "#{entry.public_proxy || entry.proxy}(#{symbol(entry.attr)})"
        end
      @edits << edit(sym, "-> { #{body} }", "#{name} is removed by strict mode; use -> { #{body} }")
    end

    def report_symbol(sym, message)
      @edits << edit(sym, nil, message) if @index[sym.unescaped] && !core?(sym.unescaped)
    end

    # On every record too (readonly?, frozen?, ...) when ActiveRecord is loaded.
    def core?(name)
      CORE.any? { it.method_defined?(name) || it.private_method_defined?(name) } ||
        (defined?(::ActiveRecord::Base) && ::ActiveRecord::Base.method_defined?(name))
    end

    def models(entry)
      names = entry.classes
      names.size > 4 ? "#{names.first(4).join(", ")} and #{names.size - 4} more" : names.join(", ")
    end

    def edit(node, replacement, message)
      loc = node.location
      Edit.new(loc.start_offset, loc.end_offset, replacement, message)
    end

    # :all when self is a record of a model with the entry's attribute
    # wherever this code runs (in the model, its subclasses, or every model
    # including this module), :some when only in some of them, nil otherwise.
    def self_coverage(entry)
      return if @nesting.empty? || @class_level.positive?

      name = @nesting.join("::")
      classes =
        if @index.model?(name) then @index.with_descendants(name)
        elsif @index.app_module?(name) then @index.includers_of(name)
        else return
        end
      covered = classes.count { entry.classes.include?(it) }
      if covered == classes.size then :all
      elsif covered.positive? then :some
      end
    end

    def symbol(attr) = attr.to_sym.inspect

    # Names of local variables and parameters anywhere in the file: a bare
    # reader call with one of these names would read the local instead.
    def locals(root)
      names = Set.new
      walk = lambda do |node|
        type = node.class.name
        names << node.name.to_s if (type.include?("LocalVariable") || type.end_with?("ParameterNode")) && node.respond_to?(:name) && node.name
        node.compact_child_nodes.each(&walk)
      end
      walk.(root)
      names
    end
  end
end

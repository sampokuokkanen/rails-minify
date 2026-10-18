# frozen_string_literal: true

require "prism"

module ArMinimizer
  # Source-to-source compiler. Replaces calls to attribute pattern methods
  # (anything in the Index: name?, name_changed?, saved_change_to_name?, ...)
  # with the proxy ActiveRecord itself would call, guarded so that any other
  # receiver gets the original call:
  #
  #   user.name_changed?
  #   # becomes
  #   (::User.equal?(user.class) || ::Post.equal?(user.class) ? user.attribute_changed?(-"name") : user.name_changed?)
  #
  # listing the models that have the attribute (when there are more than
  # MAX_CLASS_GUARD: `::ActiveRecord::Base === user && user.class._has_attribute?("name")`).
  #
  # Inside an instance method of a model that has the attribute, self is
  # known, so the guard goes away:
  #
  #   attribute_changed?(-"name")
  #
  # The guard checks the class, not the instance: generated methods exist for
  # every attribute of the class, loaded by this query or not. Line numbers
  # don't change: each replacement stays on its line, and the marker comment
  # is appended at the end of the file.
  class Rewriter
    MARKER = "# ar_minimizer v#{VERSION} (rewritten)"
    GENERATED_LINE = /^# ar_minimizer v\S+ \(rewritten\)$/
    MAX_CLASS_GUARD = 4

    Result = Data.define(:source, :sites, :skipped)

    # marker: false for source that is compiled, not written back (templates).
    # guards: also compile calls whose receiver class isn't known, behind a
    # runtime class check (off by default: each such site costs code for a
    # small gain, and a miss runs the check and the original call).
    def initialize(index:, path: "(source)", marker: true, guards: false)
      @index = index
      @path = path
      @marker = marker
      @guards = guards
    end

    def rewrite(source)
      return Result.new(source, 0, []) if source.match?(GENERATED_LINE)

      parse = Prism.parse(source)
      return Result.new(source, 0, ["#{@path}: does not parse, left untouched"]) unless parse.success?

      @source = source
      @sites = 0
      @temps = 0
      @skipped = []
      @nesting = []
      @nesting_kinds = []
      @self_kinds = [:unknown]
      @scopes = [scan_locals(parse.value.statements)]
      @block_types = nil
      body = splice(parse.value, 0, source.bytesize)
      return Result.new(source, 0, @skipped) if @sites.zero?

      rewritten = @marker ? append_marker(body, parse) : body
      # Never hand back code that would break the app on boot.
      unless Prism.parse(rewritten).success?
        return Result.new(source, 0, @skipped + ["#{@path}: rewritten source does not parse, left untouched"])
      end

      Result.new(rewritten, @sites, @skipped)
    end

    private

    # --- traversal -----------------------------------------------------------

    # The node's source with every compilable call inside it replaced.
    def render(node)
      case node
      when Prism::DefinedNode
        # defined?(user.name?) is "method", defined?((... ? ... : ...)) is "expression".
        text(node)
      when Prism::ClassNode, Prism::ModuleNode
        @nesting.push(constant_name(node.constant_path))
        @nesting_kinds.push(node.is_a?(Prism::ClassNode) ? :class : :module)
        scoped(scan_locals(node.body)) { within(:unknown) { splice(node) } }.tap { @nesting.pop; @nesting_kinds.pop }
      when Prism::SingletonClassNode
        scoped(scan_locals(node.body)) { within(:unknown) { splice(node) } }
      when Prism::DefNode
        scoped(scan_locals(node.body, untyped: parameter_names(node.parameters))) do
          within(node.receiver ? :unknown : :instance) { splice(node) }
        end
      when Prism::BlockNode, Prism::LambdaNode
        typed, @block_types = @block_types, nil
        params = parameter_names(node.parameters.respond_to?(:parameters) ? node.parameters.parameters : nil)
        # instance_exec/instance_eval DSLs can change self inside a block.
        typed ||= {}
        scoped(scan_locals(node.body, untyped: params - typed.keys, typed: typed)) { within(:unknown) { splice(node) } }
      when Prism::CallNode
        if (entry = compilable(node))
          compile(node, entry)
        else
          @block_types = iteration_types(node) if node.block.is_a?(Prism::BlockNode)
          splice(node)
        end
      else
        splice(node)
      end
    end

    def splice(node, from = node.location.start_offset, to = node.location.end_offset)
      out = +""
      cursor = from
      node.compact_child_nodes.sort_by { it.location.start_offset }.each do |child|
        start = child.location.start_offset
        stop = child.location.end_offset
        # Heredoc bodies live outside their node's range; leave them as they are.
        next if start < cursor || stop > to

        out << @source.byteslice(cursor, start - cursor) << render(child)
        cursor = stop
      end
      out << @source.byteslice(cursor, to - cursor)
    end

    def within(kind)
      @self_kinds.push(kind)
      yield
    ensure
      @self_kinds.pop
    end

    def scoped(locals)
      @scopes.push(locals)
      yield
    ensure
      @scopes.pop
    end

    def text(node) = @source.byteslice(node.location.start_offset, node.location.length)

    # --- matching ------------------------------------------------------------

    def compilable(node)
      entry = @index[node.name]
      return unless entry
      return if node.block # a block (or &blk) changes what the call means
      return if node.arguments && !entry.args
      return if node.receiver && !node.call_operator # `Foo::bar` style
      return if heredoc?(node)

      entry
    end

    def heredoc?(node)
      return true if node.respond_to?(:opening_loc) && node.opening_loc && node.opening_loc.slice.start_with?("<<")

      node.compact_child_nodes.any? { heredoc?(it) }
    end

    # --- code generation -----------------------------------------------------

    def compile(node, entry)
      @sites += 1
      args = node.arguments && splice(node.arguments)
      # -"name": a deduplicated frozen string, no allocation per call even
      # without the frozen_string_literal comment (generated methods don't allocate either).
      proxy_args = ["-#{entry.attr.inspect}", args].compact.join(", ")
      original = "#{node.name}#{"(#{args})" if args}"

      receiver = node.receiver
      if receiver.nil? || receiver.is_a?(Prism::SelfNode)
        dot = receiver ? "self." : ""
        # Private proxies are callable on self, implicit or explicit.
        call = query_on("self", entry) || "#{dot}#{entry.public_proxy || entry.proxy}(#{proxy_args})"
        case self_type(entry)
        when :known then return call # self is a record of a model with the attribute: no guard
        when :not_a_model then return as_written(node) # never the attribute method
        end
        return as_written(node) unless @guards

        return "(#{guard(entry, "self", "self")} ? #{call} : #{dot}#{original})"
      end

      type = expr_type(receiver)
      if type&.kind == :record
        case coverage(entry, with_descendants(type.model))
        when :known then return typed_call(node, entry, type, proxy_args, original)
        when :not_a_model then return as_written(node) # a record of a model without it: something else
        end
      end
      return as_written(node) unless @guards

      first, again = receiver_refs(receiver)
      fast = fast_call(again, entry, proxy_args)
      body = "#{guard(entry, first, again)} ? #{fast} : #{again}.#{original}"
      if node.safe_navigation?
        "(nil == #{first} ? nil : #{body.sub(first, again)})"
      else
        "(#{body})"
      end
    end

    def fast_call(ref, entry, proxy_args)
      query_on(ref, entry) ||
        (entry.public_proxy ? "#{ref}.#{entry.public_proxy}(#{proxy_args})" : "#{ref}.__send__(:#{entry.proxy}, #{proxy_args})")
    end

    # The call as written (nested rewrites inside it still apply).
    def as_written(node)
      @sites -= 1
      splice(node)
    end

    # A receiver of known model: no class check. Never nil: the call alone.
    # Maybe nil: nil takes the original call, which raises (or, with &.,
    # returns nil) exactly as before.
    def typed_call(node, entry, type, proxy_args, original)
      first, again = receiver_refs(node.receiver)
      fast = fast_call(again, entry, proxy_args)
      if type.nilable || node.safe_navigation?
        fallback = node.safe_navigation? ? "nil" : "#{again}.#{original}"
        "(nil == #{first} ? #{fallback} : #{fast})"
      elsif first == again
        fast
      else
        "(#{first}; #{fast})"
      end
    end

    # name? straight from the reader, when the column type allows (Index::QUERY).
    # Parenthesized: `age?.to_s` and `!age?` must still apply to the whole thing.
    def query_on(receiver, entry)
      reader = "#{receiver}.#{entry.attr}"
      case entry.query
      when :truthy then "(!!#{reader})"
      when :numeric then "((#{reader} || 0) != 0)"
      when :string then "(!#{reader}.blank?)"
      end
    end

    # Few models with the attribute: compare classes (pointer checks, inline
    # cached constants). Subclasses and models the build didn't see take the
    # original call. Many models: ask the class.
    def guard(entry, first, again)
      if entry.classes.size.between?(1, MAX_CLASS_GUARD)
        entry.classes.each_with_index.map { |name, i| "::#{name}.equal?(#{i.zero? ? first : again}.class)" }.join(" || ")
      else
        "::ActiveRecord::Base === #{first} && #{again}.class._has_attribute?(#{entry.attr.inspect})"
      end
    end

    # How to refer to the receiver the first time and afterwards. Plain
    # variables are repeated; anything else is evaluated once into a temp.
    def receiver_refs(receiver)
      case receiver
      when Prism::LocalVariableReadNode, Prism::InstanceVariableReadNode
        [text(receiver), text(receiver)]
      else
        temp = "__arm#{@temps += 1}"
        ["(#{temp} = #{render(receiver)})", temp]
      end
    end

    # What self is in this instance method, from the class or module around it:
    #   :known        a model with the attribute (and its subclasses), or an app
    #                 concern whose including models all have it: no guard;
    #   :not_a_model  a class that isn't a model: the call is never the
    #                 attribute method, so it stays as written;
    #   nil           can't tell (modules not known to be concerns,
    #                 `class Foo::Bar` inside a namespace): guard.
    # From the index alone, without loading constants: the Loader runs while
    # files are being required, models included.
    def self_type(entry)
      return unless @self_kinds.last == :instance
      return if @nesting.empty? || @nesting.any?(&:nil?)
      return if @nesting.size > 1 && @nesting.any? { it.include?("::") }

      name = @nesting.join("::").delete_prefix("::")
      if model?(name) || entry.classes.include?(name)
        coverage(entry, with_descendants(name))
      elsif app_module?(name)
        includers = @index.includers_of(name)
        coverage(entry, includers) if includers.any?
      elsif @nesting_kinds.last == :class && @index.respond_to?(:model?) # only a full index knows every model
        :not_a_model
      end
    end

    # :known when every possible class has the attribute method, :not_a_model
    # when none does (the call is something else: an enum predicate, a
    # hand-written method), nil when some do.
    def coverage(entry, classes)
      covered = classes.count { entry.classes.include?(it) }
      if covered == classes.size then :known
      elsif covered.zero? then :not_a_model
      end
    end

    # The index may be a plain Hash (tests): no model knowledge then.
    def model?(name) = @index.respond_to?(:model?) && @index.model?(name)
    def app_module?(name) = @index.respond_to?(:app_module?) && @index.app_module?(name)
    def with_descendants(name) = @index.respond_to?(:with_descendants) ? @index.with_descendants(name) : [name]
    def covers?(entry, classes) = classes.all? { entry.classes.include?(it) }

    # --- types ------------------------------------------------------------------

    # What an expression is, when provable from the source and the index:
    # a model's class, a relation of its records, or one record (maybe nil).
    Type = Data.define(:model, :nilable, :kind)

    # Calls on a model or relation that return one of its records, never nil.
    RECORD_METHODS = %i[find find_by! first! last! take! sole find_sole_by].freeze
    # ... or a record or nil.
    MAYBE_RECORD_METHODS = %i[find_by first last take].freeze
    # Relation methods whose result is still a relation of the same model
    # (friendly: friendly_id's finder relation).
    RELATION_METHODS = %i[all where not order reorder includes preload eager_load joins left_joins left_outer_joins
                          limit offset distinct readonly references unscope rewhere none friendly].freeze
    # Iterations whose block gets the relation's records as first parameter.
    ITERATIONS = %i[each find_each map flat_map filter_map each_with_index each_with_object select reject sort_by
                    group_by index_by partition min_by max_by sum find detect any? all? none? count].freeze

    def expr_type(node)
      case node
      when Prism::LocalVariableReadNode then local_type(node)
      when Prism::ConstantReadNode, Prism::ConstantPathNode
        (model = model_constant(node)) && Type.new(model, false, :class)
      when Prism::ParenthesesNode
        body = node.body
        expr_type(body.body.last) if body.is_a?(Prism::StatementsNode) && body.body.size == 1
      when Prism::SelfNode then self_record_type
      when Prism::CallNode
        return if node.block || node.safe_navigation?

        receiver_type = node.receiver ? expr_type(node.receiver) : self_record_type
        receiver_type && call_type(receiver_type, node)
      end
    end

    def call_type(receiver, node)
      args = node.arguments&.arguments || []
      model = receiver.model
      case receiver.kind
      when :class, :relation
        if RELATION_METHODS.include?(node.name) || scope?(model, node.name)
          Type.new(model, false, :relation)
        elsif RECORD_METHODS.include?(node.name)
          Type.new(model, false, :record) if record_arguments?(node.name, args)
        elsif %i[new create create!].include?(node.name) && receiver.kind == :class
          # an Array of attributes would return an Array
          Type.new(model, false, :record) if args.empty? || (args.size == 1 && (args[0].is_a?(Prism::KeywordHashNode) || args[0].is_a?(Prism::HashNode)))
        elsif MAYBE_RECORD_METHODS.include?(node.name)
          Type.new(model, true, :record) if node.name == :find_by || args.empty? # first(2) is an Array
        end
      when :record
        return if receiver.nilable || !args.empty?

        target, many = association(model, node.name)
        return unless target

        many == "many" ? Type.new(target, false, :relation) : Type.new(target, true, :record)
      end
    end

    def record_arguments?(name, args)
      case name
      when :find # find([1, 2]) and find(1, 2) return Arrays
        args.size == 1 && [Prism::ArrayNode, Prism::SplatNode, Prism::RangeNode].none? { args[0].is_a?(it) }
      when :first!, :last!, :take! then args.empty?
      else true
      end
    end

    # self inside an instance method of one model (not a concern: several models).
    def self_record_type
      return unless @self_kinds.last == :instance && @nesting_kinds.last == :class
      return if @nesting.empty? || @nesting.any?(&:nil?) || (@nesting.size > 1 && @nesting.any? { it.include?("::") })

      name = @nesting.join("::").delete_prefix("::")
      Type.new(name, false, :record) if model?(name)
    end

    def scope?(model, name) = @index.respond_to?(:scope?) && @index.scope?(model, name)
    def association(model, name) = @index.respond_to?(:association) ? @index.association(model, name) : nil

    def local_type(node)
      scope = @scopes[-1 - node.depth]
      scope && scope[node.name]
    end

    # { name => Type } for this scope's locals whose every assignment has
    # the same provable type; untyped: names that start unknown
    # (parameters); typed: block parameters known from the iteration.
    def scan_locals(body, untyped: [], typed: {})
      writes = Hash.new { |h, k| h[k] = [] }
      untyped.each { writes[it] << nil }
      typed.each { |name, type| writes[name] << type }
      collect_writes(body, 0, writes) if body
      writes.filter_map { |name, types| [name, types.first] if types.first&.kind == :record && types.uniq.size == 1 }.to_h
    end

    def collect_writes(node, depth, writes)
      case node
      when Prism::DefNode, Prism::ClassNode, Prism::ModuleNode, Prism::SingletonClassNode
        return # their own scopes
      when Prism::BlockNode, Prism::LambdaNode
        depth += 1
      when Prism::LocalVariableWriteNode
        writes[node.name] << expr_type(node.value) if node.depth == depth
      when Prism::LocalVariableOperatorWriteNode, Prism::LocalVariableOrWriteNode, Prism::LocalVariableAndWriteNode,
           Prism::LocalVariableTargetNode
        writes[node.name] << nil if node.depth == depth
      end
      node.compact_child_nodes.each { collect_writes(it, depth, writes) }
    end

    def parameter_names(params)
      return [] unless params

      [*params.requireds, *params.optionals, params.rest, *params.posts, *params.keywords, params.keyword_rest, params.block]
        .compact.filter_map { it.respond_to?(:name) ? it.name : nil }
    end

    # { block parameter => record Type } for <relation>.each { |record| }.
    def iteration_types(node)
      return unless ITERATIONS.include?(node.name)

      params = node.block.parameters
      first = params.respond_to?(:parameters) && params.parameters&.requireds&.first
      return unless first.is_a?(Prism::RequiredParameterNode)

      type = node.receiver && expr_type(node.receiver)
      { first.name => Type.new(type.model, false, :record) } if type && %i[class relation].include?(type.kind)
    end

    # A model, by its constant as written. Unqualified names inside a namespace
    # could mean Namespace::Name, so they count only when no such model or
    # concern exists.
    def model_constant(node)
      return unless (name = constant_name(node))

      name = name.delete_prefix("::")
      return unless model?(name)
      unless node.is_a?(Prism::ConstantPathNode) && node.parent.nil? # ::Name is unambiguous
        prefixes = @nesting.compact
        return if (1..prefixes.size).any? { |n| (other = "#{prefixes.first(n).join("::")}::#{name}") != name && (model?(other) || app_module?(other)) }
      end
      name
    end

    def constant_name(path)
      case path
      when Prism::ConstantReadNode then path.name.to_s
      when Prism::ConstantPathNode
        parent = path.parent ? constant_name(path.parent) : ""
        parent && "#{parent}::#{path.name}"
      end
    end

    def append_marker(body, parse)
      if (data = parse.data_loc)
        head = body.byteslice(0, body.bytesize - (@source.bytesize - data.start_offset))
        tail = @source.byteslice(data.start_offset, @source.bytesize - data.start_offset)
        "#{head}#{"\n" unless head.end_with?("\n")}#{MARKER}\n#{tail}"
      else
        "#{body}#{"\n" unless body.end_with?("\n")}#{MARKER}\n"
      end
    end
  end
end

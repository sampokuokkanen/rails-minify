# frozen_string_literal: true

require "prism"
require "bigdecimal"
require "json"

module ApMinimizer
  # Rewrites each template's compiled Ruby as ActionView compiles it:
  #
  #   render "comments/comment", comment: c   ->  __ap_render_partial("comments/comment", { comment: c })
  #   render partial: "comments/comment", locals: { comment: c }   (same)
  #   link_to post.title, post_path(post)     ->  __ap_link_to(post.title, post_path(post))
  #   link_to "Edit", edit_path, class: "btn" ->  the attributes string, built once by Rails'
  #                                              tag_options when the template compiles
  #
  # __ap_render_partial looks the partial up once per path, local names and
  # lookup details (formats, locale, variants, handlers), then does what
  # PartialRenderer does after its lookup: the render_partial.action_view
  # event with the same payload, and template.render. It skips building the
  # renderer and the options hashes. Partials named without a directory
  # are looked up under the controller's prefixes, which are part of the cache key.
  #
  # __ap_link_to builds `<a href="...">...</a>` directly when the URL is a
  # String, with link_to's escaping; anything else calls link_to.
  #
  # Both call the stock helper instead in a view class that overrides render,
  # link_to, url_for or content_tag.
  module Views
    STOCK_OWNERS = {
      render: ["ActionView::Helpers::RenderingHelper"],
      link_to: ["ActionView::Helpers::UrlHelper"],
      url_for: ["ActionView::Helpers::UrlHelper", "ActionView::RoutingUrlFor"],
      content_tag: ["ActionView::Helpers::TagHelper"],
    }.freeze

    NO_PREFIXES = [].freeze

    # Literal html options of block-form link_to sites, for the fallback.
    LINK_OPTIONS = []
    LINK_OPTIONS_MUTEX = Mutex.new

    class << self
      def register_link_options(options)
        LINK_OPTIONS_MUTEX.synchronize { (LINK_OPTIONS << options.freeze).size - 1 }
      end

      def install!
        @enabled = true
        @stock = {}
        @templates = {}
        @objects = {}
        @mutex = Mutex.new
        ActionView::Template.prepend(TemplateHook) unless ActionView::Template < TemplateHook
        ActionView::Base.include(Helpers) unless ActionView::Base < Helpers
      end

      def disable! = @enabled = false

      def enabled? = @enabled == true

      # True when render/link_to/url_for/content_tag are ActionView's own in this view class.
      def stock?(klass)
        @stock.fetch(klass) do
          @stock[klass] = STOCK_OWNERS.all? { |name, owners| owners.include?(klass.instance_method(name).owner.name) }
        end
      end

      # As PartialRenderer#find_template: a name without a directory is
      # looked up under the controller's prefixes, so they're in the key.
      def template_for(view, path, locals, keys = locals.keys)
        lookup = view.lookup_context
        prefixes = path.include?("/") ? NO_PREFIXES : lookup.prefixes
        key = [lookup.details_key, path, keys, prefixes]
        @templates.fetch(key) do
          template = lookup.find_template(path, prefixes, true, keys, {})
          @mutex.synchronize { @templates[key.dup.tap { it[3] = prefixes.dup.freeze }] = template }
        end
      end

      # For render(record): [partial path, local name, [local name]], worked
      # out by Rails' ObjectRenderer once per to_partial_path and controller
      # prefix; false when Rails would raise or look in the controller's
      # directory (no "/" in the path), so the stock render runs.
      def object_partial(view, object, partial_path)
        lookup = view.lookup_context
        prefixed = view.prefix_partial_path_with_controller_namespace
        prefix = lookup.prefixes.first
        key = [prefixed, prefix, partial_path]
        @objects.fetch(key) do
          info =
            begin
              renderer = ActionView::ObjectRenderer.new(lookup, {})
              path = renderer.send(:partial_path, object, view)
              local = renderer.send(:local_variable, path)
              path.include?("/") ? [path.freeze, local, [local].freeze].freeze : false
            rescue StandardError
              false
            end
          @mutex.synchronize { @objects[key] = info }
        end
      end

      def rewrite(source) = Rewriter.new(source).rewrite

      # What link_to's html options become in the tag, from Rails itself.
      def static_attributes(options)
        @tag_builder ||= ActionView::Helpers::TagHelper::TagBuilder.new(ActionView::Base.empty)
        @tag_builder.tag_options(options.transform_keys(&:to_s)) || ""
      end

      # [rewritten source, stats] for the census.
      def rewrite_with_stats(source)
        rewriter = Rewriter.new(source)
        [rewriter.rewrite, rewriter.stats]
      end
    end

    module TemplateHook
      private

      def compiled_source
        source = super
        Views.enabled? ? Views.rewrite(source) : source
      end
    end

    module Helpers
      private

      def __ap_render_partial(path, locals = {})
        return render(path, locals) unless Views.enabled? && ::Hash === locals && Views.stock?(self.class)

        template = Views.template_for(self, path, locals)
        ActiveSupport::Notifications.instrument("render_partial.action_view",
          identifier: template.identifier, layout: nil, locals: locals) do |payload|
          content = template.render(self, locals, add_to_stack: true) { |*name| _layout_for(*name) }
          payload[:cache_hit] = view_renderer.cache_hits[template.virtual_path]
          content
        end
      end

      def __ap_fast_links? = Views.enabled? && Views.stock?(self.class)

      # link_to(name, url, literal options): attrs is Rails' rendering of the
      # options; link_to appends href after them.
      def __ap_link_to_attrs(name, url, attrs)
        href = ERB::Util.unwrapped_html_escape(url)
        href = href.gsub('"', "&quot;") if href.include?('"')
        content = name || url
        content = ERB::Util.unwrapped_html_escape(content) if content.present?
        "<a#{attrs} href=\"#{href}\">#{content}</a>".html_safe
      end

      # link_to(url[, literal options]) do ... end. Content as content_tag
      # makes it: capture(&block).
      def __ap_link_to_block(url, attrs, options_index, &block)
        unless Views.enabled? && ::String === url && Views.stock?(self.class)
          return link_to(url, &block) unless options_index

          return link_to(url, LINK_OPTIONS[options_index].dup, &block)
        end

        href = ERB::Util.unwrapped_html_escape(url)
        href = href.gsub('"', "&quot;") if href.include?('"')
        content = capture(&block)
        content = ERB::Util.unwrapped_html_escape(content) if content.present?
        "<a#{attrs} href=\"#{href}\">#{content}</a>".html_safe
      end

      # render(record) / render(record, locals): what ObjectRenderer does
      # after working out the partial: the object goes into the locals under
      # the partial's name, then the same event and template.render.
      def __ap_render_object(object, locals = nil)
        unless Views.enabled? && Views.stock?(self.class) && (locals.nil? || ::Hash === locals) &&
            !(::String === object) && !(::Hash === object) && !object.respond_to?(:render_in) && !object.respond_to?(:to_ary)
          return locals.nil? ? render(object) : render(object, locals)
        end

        model = object.respond_to?(:to_model) ? object.to_model : object
        info = model.respond_to?(:to_partial_path) && Views.object_partial(self, object, model.to_partial_path)
        return (locals.nil? ? render(object) : render(object, locals)) unless info

        path, local, keys = info
        if locals
          keys = locals.keys << local
        else
          locals = {}
        end
        template = Views.template_for(self, path, locals, keys)
        locals[local] = object
        ActiveSupport::Notifications.instrument("render_partial.action_view",
          identifier: template.identifier, layout: nil, locals: locals) do |payload|
          content = template.render(self, locals, add_to_stack: true) { |*name| _layout_for(*name) }
          payload[:cache_hit] = view_renderer.cache_hits[template.virtual_path]
          content
        end
      end

      # One html option with a value known only at runtime, as Rails'
      # tag_options renders it (it renders each pair on its own). Plain
      # Strings and Symbols under an ordinary key take the short way.
      def __ap_attr(key, escaped_key, plain, value)
        if plain && (::String === value || ::Symbol === value)
          v = ERB::Util.unwrapped_html_escape(value)
          v = v.gsub('"', "&quot;") if v.include?('"')
          " #{escaped_key}=\"#{v}\""
        else
          tag_builder.tag_options({ key => value }) || ""
        end
      end

      # Block-form link_to with options not all literal: the fallback gets them as a Hash.
      def __ap_link_to_block_dyn(url, attrs, options, &block)
        return link_to(url, options, &block) unless Views.enabled? && ::String === url && Views.stock?(self.class)

        href = ERB::Util.unwrapped_html_escape(url)
        href = href.gsub('"', "&quot;") if href.include?('"')
        content = capture(&block)
        content = ERB::Util.unwrapped_html_escape(content) if content.present?
        "<a#{attrs} href=\"#{href}\">#{content}</a>".html_safe
      end

      def __ap_link_to(name, url)
        return link_to(name, url) unless Views.enabled? && ::String === url && Views.stock?(self.class)

        href = ERB::Util.unwrapped_html_escape(url)
        href = href.gsub('"', "&quot;") if href.include?('"')
        content = name || url
        content = ERB::Util.unwrapped_html_escape(content) if content.present?
        "<a href=\"#{href}\">#{content}</a>".html_safe
      end
    end

    class Rewriter
      # { "render partial" => n, "link_to" => n, "render: <why not>" => n, ... }
      attr_reader :stats

      NotLiteral = Class.new(StandardError)
      SPECIAL_LINK_OPTIONS = %w[method remote href].freeze

      def initialize(source)
        @source = source
        @edits = []
        @stats = Hash.new(0)
        @temps = 0
      end

      def rewrite
        result = Prism.parse(@source)
        return @source unless result.success?

        visit(result.value)
        return @source if @edits.empty?

        out = @source.b
        @edits.sort_by { -it[0] }.each { |start, stop, text| out[start...stop] = text.b }
        out.force_encoding(@source.encoding)
        return out if Prism.parse(out).success?

        # A bug here must not break the template: keep it as written, and say so in the census.
        @stats = Hash.new(0).merge("templates left as written (their rewrite didn't parse)" => 1)
        @source
      end

      private

      def visit(node)
        return unless node

        if node.is_a?(Prism::CallNode) && node.receiver.nil? && node.name == :link_to && node.block.is_a?(Prism::BlockNode) &&
            (head = link_to_block_head(node))
          @stats["link_to with a block"] += 1
          @edits << [node.location.start_offset, node.block.location.start_offset, head]
          visit(node.block) # its body keeps its own rewrites
          return
        end

        if node.is_a?(Prism::CallNode) && node.receiver.nil? && %i[render link_to].include?(node.name)
          if node.block
            @stats["#{node.name}: with a block#{" (#{@reason})" if @reason && node.name == :link_to}"] += 1
          elsif (text = replacement(node))
            @stats[node.name == :render ? "render partial" : "link_to"] += 1 unless @counted
            @counted = false
            @edits << [node.location.start_offset, node.location.end_offset, text]
            return # arguments keep their source; nested calls in them stay as written
          else
            @stats["#{node.name}: #{@reason || "other arguments"}"] += 1
          end
          @reason = nil
        end
        node.compact_child_nodes.each { visit(it) }
      end

      def replacement(node)
        args = node.arguments&.arguments || []
        case node.name
        when :render then render_replacement(args)
        when :link_to then link_to_replacement(args)
        end
      end

      # render "dir/name" | render "dir/name", locals | render "dir/name", k: v
      # render partial: "dir/name" [, locals: {...}]
      def render_replacement(args)
        if (text = render_object_replacement(args))
          @stats["render record"] += 1
          @counted = true
          return text
        end
        @reason = render_reason(args)
        if args.size.between?(1, 2) && (path = partial_path(args[0]))
          return "__ap_render_partial(#{path.inspect})" if args.size == 1

          locals = args[1]
          return if locals.is_a?(Prism::BlockArgumentNode) || locals.is_a?(Prism::SplatNode)

          text = locals.is_a?(Prism::KeywordHashNode) ? "{ #{slice(locals)} }" : "(#{slice(locals)})"
          return "__ap_render_partial(#{path.inspect}, #{text})"
        end
        hash = args[0] if args.size == 1
        return unless hash.is_a?(Prism::KeywordHashNode) || hash.is_a?(Prism::HashNode)

        pairs = hash.elements.to_h do |el|
          return nil unless el.is_a?(Prism::AssocNode) && el.key.is_a?(Prism::SymbolNode)

          [el.key.unescaped.to_sym, el.value]
        end
        return unless pairs.keys.include?(:partial) && (pairs.keys - %i[partial locals]).empty?
        return unless (path = partial_path(pairs[:partial]))

        pairs[:locals] ? "__ap_render_partial(#{path.inspect}, (#{slice(pairs[:locals])}))" : "__ap_render_partial(#{path.inspect})"
      end

      # render @comment, render comment, render(comment, extra: 1): anything
      # that isn't a partial name or an options hash. Collections and
      # components are told apart at runtime and keep the stock render.
      NOT_OBJECTS = [Prism::StringNode, Prism::InterpolatedStringNode, Prism::HashNode, Prism::KeywordHashNode,
                     Prism::SymbolNode, Prism::NilNode, Prism::SplatNode, Prism::BlockArgumentNode, Prism::ArrayNode].freeze

      def render_object_replacement(args)
        object, locals = args
        return unless args.size.between?(1, 2) && NOT_OBJECTS.none? { object.is_a?(it) }
        return "__ap_render_object((#{slice(object)}))" if args.size == 1
        return unless locals.is_a?(Prism::KeywordHashNode) || locals.is_a?(Prism::HashNode)

        text = locals.is_a?(Prism::KeywordHashNode) ? "{ #{slice(locals)} }" : slice(locals)
        "__ap_render_object((#{slice(object)}), #{text})"
      end

      def render_reason(args)
        first = args[0]
        case first
        when Prism::StringNode
          return "a partial name with unusual characters"
        when Prism::KeywordHashNode, Prism::HashNode
          keys = first.elements.filter_map { it.key.unescaped.to_sym if it.is_a?(Prism::AssocNode) && it.key.is_a?(Prism::SymbolNode) }
          return "collection:/object:/as:/layout: options" if (keys - %i[partial locals]).any?
        when Prism::InterpolatedStringNode then return "an interpolated partial name"
        when nil then return "no arguments"
        else return "a record, collection or component (render @x)"
        end
        "other arguments"
      end

      def partial_path(node)
        return unless node.is_a?(Prism::StringNode) && !node.opening_loc&.slice&.start_with?("<<")

        path = node.unescaped
        path if path.match?(%r{\A[\w/\-.]+\z})
      end

      def link_to_replacement(args)
        return link_to_with_options(args) if args.size == 3
        @reason = args.size == 2 ? "an options hash or splat" : "#{args.size} arguments (name only, or url options)"
        return unless args.size == 2
        return if args.any? { it.is_a?(Prism::KeywordHashNode) || it.is_a?(Prism::HashNode) || it.is_a?(Prism::BlockArgumentNode) || it.is_a?(Prism::SplatNode) }

        "__ap_link_to((#{slice(args[0])}), (#{slice(args[1])}))"
      end

      OPTIONS_REASON = "html options with computed keys, **splats, or method:/remote:/href:"

      # link_to(name, url, class: "btn", data: { ... }). Name, url and option
      # values are evaluated once, in order; a url that isn't a String at
      # runtime goes to link_to with the same options.
      def link_to_with_options(args)
        name, url, options = args
        @reason = OPTIONS_REASON
        return unless options.is_a?(Prism::KeywordHashNode) || options.is_a?(Prism::HashNode)
        return if [name, url].any? { it.is_a?(Prism::KeywordHashNode) || it.is_a?(Prism::HashNode) || it.is_a?(Prism::SplatNode) || it.is_a?(Prism::BlockArgumentNode) }
        return unless (pairs = option_pairs(options))

        n = "__apn#{@temps += 1}"
        u = "__apu#{@temps}"
        assigns = pairs.filter_map { |pair| "#{pair[:temp]} = (#{slice(pair[:node])}); " if pair[:temp] }.join
        "(#{n} = (#{slice(name)}); #{u} = (#{slice(url)}); #{assigns}__ap_fast_links? && ::String === #{u} ? " \
          "__ap_link_to_attrs(#{n}, #{u}, #{attributes_expression(pairs)}) : link_to(#{n}, #{u}, #{rebuilt_options(pairs)}))"
      end

      # link_to(url[, options]) do ... end: the call up to the block, as a
      # call to __ap_link_to_block (literal options) or __ap_link_to_block_dyn.
      def link_to_block_head(node)
        @reason = nil
        args = node.arguments&.arguments || []
        url, options = args
        @reason =
          if node.block.parameters then "block parameters"
          elsif !args.size.between?(1, 2) then "#{args.size} arguments"
          elsif [Prism::KeywordHashNode, Prism::HashNode, Prism::SplatNode, Prism::BlockArgumentNode].any? { url.is_a?(it) }
            "a hash or splat as the url"
          elsif options && !(options.is_a?(Prism::KeywordHashNode) || options.is_a?(Prism::HashNode))
            OPTIONS_REASON
          end
        return if @reason
        return "__ap_link_to_block((#{slice(url)}), \"\", nil) " unless options
        return unless (pairs = option_pairs(options))

        if pairs.none? { it[:temp] }
          hash = pairs.to_h { [it[:key], it[:value]] }
          return "__ap_link_to_block((#{slice(url)}), #{Views.static_attributes(hash).inspect}, #{Views.register_link_options(hash)}) "
        end

        assigns = pairs.filter_map { |pair| "#{pair[:temp]} = (#{slice(pair[:node])}); " if pair[:temp] }.join
        "__ap_link_to_block_dyn((#{slice(url)}), (#{assigns}#{attributes_expression(pairs)}), #{rebuilt_options(pairs)}) "
      end

      # [{ key:, value: } for literal values, { key:, node:, temp: } for the rest],
      # or nil (and @reason) for keys link_to treats specially or that aren't literal.
      def option_pairs(options)
        options.elements.map do |el|
          unless el.is_a?(Prism::AssocNode) && (el.key.is_a?(Prism::SymbolNode) || el.key.is_a?(Prism::StringNode))
            @reason = OPTIONS_REASON
            return nil
          end
          key = literal(el.key)
          if SPECIAL_LINK_OPTIONS.include?(key.to_s) || key.to_s.empty?
            @reason = OPTIONS_REASON
            return nil
          end
          begin
            { key: key, value: literal(el.value), value_node: el.value }
          rescue NotLiteral
            { key: key, node: el.value, temp: "__apa#{@temps += 1}" }
          end
        end
      rescue NotLiteral
        @reason = OPTIONS_REASON
        nil
      end

      # Ruby for the attributes string: Rails' rendering of each literal pair,
      # __ap_attr for each computed one, in the options' order.
      def attributes_expression(pairs)
        pieces = pairs.map do |pair|
          key = pair[:key].to_s
          if pair[:temp]
            plain = ActionView::Helpers::TagHelper::TAG_TYPES[key].nil?
            "__ap_attr(#{key.inspect}, #{ERB::Util.xml_name_escape(key).inspect}, #{plain}, #{pair[:temp]})"
          else
            Views.static_attributes({ key => pair[:value] }).inspect
          end
        end
        return pieces.first if pieces.size == 1 && !pairs.first[:temp]

        %("#{pieces.map { "\#{#{it}}" }.join}")
      end

      # The options as link_to gets them in the fallback: computed values from their temps.
      def rebuilt_options(pairs)
        "{ #{pairs.map { |pair| "#{pair[:key].inspect} => #{pair[:temp] || slice(pair[:value_node])}" }.join(", ")} }"
      end

      def literal(node)
        case node
        when Prism::StringNode
          raise NotLiteral if node.opening_loc&.slice&.start_with?("<<")

          node.unescaped
        when Prism::SymbolNode then node.unescaped.to_sym
        when Prism::IntegerNode, Prism::FloatNode then node.value
        when Prism::TrueNode then true
        when Prism::FalseNode then false
        when Prism::NilNode then nil
        when Prism::ArrayNode then node.elements.map { literal(it) }
        when Prism::HashNode, Prism::KeywordHashNode
          node.elements.to_h do |el|
            raise NotLiteral unless el.is_a?(Prism::AssocNode) && (el.key.is_a?(Prism::SymbolNode) || el.key.is_a?(Prism::StringNode))

            [literal(el.key), literal(el.value)]
          end
        else raise NotLiteral
        end
      end

      def slice(node) = @source.byteslice(node.location.start_offset, node.location.length)
    end
  end
end

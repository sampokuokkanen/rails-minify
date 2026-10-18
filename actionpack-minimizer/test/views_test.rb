# frozen_string_literal: true

require "test_helper"
require_relative "routes_test"

Note = Struct.new(:body) do
  def to_partial_path = "notes/note"
end

NoteComponent = Struct.new(:body) do
  def render_in(view) = "<b>component #{body}</b>".html_safe
end

class ViewsTest < Minitest::Test
  VIEWS = File.expand_path("fixtures/views", __dir__)
  LOCALS = {
    comments: ["a", "<b>", "c & d"],
    local_hash: { comment: "from a hash" },
    nil_locals: nil,
    safe_name: "<i>safe</i>".html_safe,
    safe_url: "/safe?a=1&b=2".html_safe,
    notes: [Note.new("n1"), Note.new("<n2>")],
    note_component: NoteComponent.new("c"),
    plain_object: Object.new,
  }.freeze

  # [html or error, render_partial events]
  def render_page(enabled, prefixes: ["pages"])
    enabled ? ApMinimizer::Views.install! : ApMinimizer::Views.disable!
    events = []
    sub = ActiveSupport::Notifications.subscribe("render_partial.action_view") do |*, payload|
      events << payload.slice(:identifier, :layout, :locals, :cache_hit)
    end
    # As in a request: the lookup context carries the controller's prefixes.
    view = ActionView::Base.with_empty_template_cache.new(ActionView::LookupContext.new([VIEWS], {}, prefixes), {}, nil)
    html = begin
      view.render(template: "pages/show", locals: LOCALS)
    rescue StandardError => e
      [:raised, e.class, e.message]
    end
    [html, events]
  ensure
    ActiveSupport::Notifications.unsubscribe(sub)
  end

  def test_same_html_and_events_as_actionview
    stock = render_page(false)
    calls = Hash.new(0)
    counter = Module.new do
      %i[__ap_render_partial __ap_render_object __ap_link_to __ap_link_to_attrs __ap_link_to_block __ap_link_to_block_dyn __ap_attr].each do |name|
        private define_method(name) { |*args, &block| calls[name] += 1; super(*args, &block) }
      end
    end
    ApMinimizer::Views::Helpers.prepend(counter)
    compiled = render_page(true)
    # Each compiled form really ran (a rewrite that failed to parse would leave the template as written).
    assert_operator calls[:__ap_render_partial], :>=, 15
    assert_operator calls[:__ap_link_to], :>=, 9
    assert_operator calls[:__ap_link_to_attrs], :>=, 5
    assert_operator calls[:__ap_link_to_block], :>=, 6
    assert_operator calls[:__ap_render_object], :>=, 6
    assert_operator calls[:__ap_attr], :>=, 20
    assert_operator calls[:__ap_link_to_block_dyn], :>=, 2
    assert_equal stock, compiled
    assert_operator stock.last.size, :>, 15
    assert_includes compiled.first, %(<a href="/a?b=1&amp;c=&quot;2&quot;">&lt;b&gt;x&lt;/b&gt;</a>)
  end

  def test_namespaced_controller_prefix
    stock = render_page(false, prefixes: ["admin/pages", "pages"])
    compiled = render_page(true, prefixes: ["admin/pages", "pages"])
    assert_equal stock, compiled
    assert_includes compiled.first, "<em>admin n1</em>" # Rails' prefix merge: admin/notes/_note
    assert_includes compiled.first, "admin shared 1" # render "shared": admin/pages/_shared first
    assert_includes compiled.first, "only in pages" # then pages/_fallthrough
  end

  # The same partial name in two controllers, in one process: each gets its own template.
  def test_partials_without_a_directory_follow_the_controller
    ApMinimizer::Views.install!
    view_class = ActionView::Base.with_empty_template_cache
    html = lambda do |prefixes|
      view_class.new(ActionView::LookupContext.new([VIEWS], {}, prefixes), {}, nil).render(inline: '<%= render "shared", x: 3 %>')
    end
    assert_equal "<i>pages shared 3</i>\n", html.(["pages"])
    assert_equal "<i>admin shared 3</i>\n", html.(["admin/pages", "pages"])
    assert_equal "<i>pages shared 3</i>\n", html.(["pages"])
  end

  def test_rewrites
    out = ApMinimizer::Views.rewrite(<<~'RUBY')
      render "comments/comment", comment: c
      render("comments/comment", { comment: c })
      render partial: "comments/comment", locals: { comment: c }
      __ap_render_partial("comment", { comment: c })
      __ap_render_object((@comments))
      render partial: "comments/comment", collection: list
      link_to "Home", root_path
      link_to "Home", root_path, class: "x"
      __ap_link_to_block((post), "", nil) { "x" }
      render "comments/comment" do end
    RUBY
    assert_equal <<~'RUBY', out
      __ap_render_partial("comments/comment", { comment: c })
      __ap_render_partial("comments/comment", ({ comment: c }))
      __ap_render_partial("comments/comment", ({ comment: c }))
      __ap_render_partial("comment", { comment: c })
      __ap_render_object((@comments))
      render partial: "comments/comment", collection: list
      __ap_link_to(("Home"), (root_path))
      (__apn1 = ("Home"); __apu1 = (root_path); __ap_fast_links? && ::String === __apu1 ? __ap_link_to_attrs(__apn1, __apu1, " class=\"x\"") : link_to(__apn1, __apu1, { :class => "x" }))
      __ap_link_to_block((post), "", nil) { "x" }
      render "comments/comment" do end
    RUBY
  end

  def test_overridden_helpers_use_the_stock_path
    ApMinimizer::Views.install!
    klass = Class.new(ActionView::Base.with_empty_template_cache) do
      def link_to(name, url) = "custom #{name} #{url}"
    end
    assert_equal "custom A /a", klass.with_view_paths([VIEWS]).render(inline: "<%= link_to 'A', '/a' %>")
  end
end

class CensusTest < Minitest::Test
  def test_views_and_routes
    views = ApMinimizer::Census.views([File.expand_path("fixtures/views", __dir__)])
    assert_operator views["render partial"], :>=, 10
    assert_operator views["link_to"], :>=, 9
    assert views.key?("render: with a block")
    routes = ApMinimizer::Census.routes(ROUTES).to_h
    assert_nil routes["post_path"]
    assert_equal "constraints on segments arguments fill (id)", routes["strict_user_path"]
    assert_equal "a glob segment (or unknown: AST already freed)", routes["file_path"]
    assert_includes ApMinimizer::Census::Result.new(routes.to_a, views).lines.first, "route helpers:"
  end
end

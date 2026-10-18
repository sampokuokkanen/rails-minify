# frozen_string_literal: true

require "test_helper"
require "action_view"

class ViewsTest < Minitest::Test
  def setup
    super
    ArMinimizer::Views.install!(index: index, guards: true)
  end

  def template(source, locals: [:user])
    ActionView::Template.new(source, "users/_card.html.erb", ActionView::Template::Handlers::ERB, locals: locals, format: :html)
  end

  def render(template, **locals)
    @view_class ||= ActionView::Base.with_empty_template_cache # templates compile into this class
    template.render(@view_class.with_view_paths([]), locals)
  end

  def test_compiles_template_calls_with_locals_as_locals
    t = template("<% if user.name? %><%= user.name %> (<%= user.age_changed? ? 1 : 0 %>)<% end %>\n<p><%= user.active? %></p>")
    code = t.send(:compiled_source)
    assert_includes code, '::Post.equal?(user.class) || ::User.equal?(user.class) ? (!user.name.blank?) : user.name?'
    assert_includes code, "user.age_changed?" # hand-written in User: left alone
    refute_includes code, "# ar_minimizer v"
    with_slim(true) do
      assert_equal "a (0)\n<p>true</p>", render(t, user: User.create!(name: "a", active: true))
      assert_equal "\n<p>poro</p>", render(t, user: Struct.new(:name?, :active?).new(false, "poro"))
    end
  end

  def test_line_numbers_survive
    t = template("<p>\n<%= user.name? %>\n<%= user.nope! %>\n</p>")
    error = assert_raises(ActionView::Template::Error) { render(t, user: User.new) }
    assert_equal 3, error.cause.backtrace_locations.find { it.path == "users/_card.html.erb" }.lineno
  end
end

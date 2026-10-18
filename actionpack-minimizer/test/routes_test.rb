# frozen_string_literal: true

require "test_helper"

Record = Struct.new(:to_param)

ROUTES = ActionDispatch::Routing::RouteSet.new
ROUTES.draw do
  root to: "home#index"
  resources :posts do
    resources :comments, only: %i[index show]
    get :preview, on: :member
  end
  get "archive(/:year)" => "archive#index", as: :archive
  get "pages/:slug(.:format)" => "pages#show", as: :page
  get "users/:id" => "users#show", as: :strict_user, constraints: { id: /\d+/ } # not optimized by Rails
  get "files/*path" => "files#show", as: :file # glob: not optimized either
end

# A helper context like a controller or view: url_options memoized per instance.
class Context
  include ROUTES.url_helpers

  def initialize(options) = @options = options
  def url_options = @url_options ||= ROUTES.default_url_options.merge(@options).freeze
end

class RoutesTest < Minitest::Test
  CALLS = [
    [:root_path], [:root_url], [:posts_path], [:posts_url],
    [:post_path, Record.new("1")], [:post_path, 42], [:post_path, Record.new("a b/c?d#é")],
    [:post_url, Record.new("1")], [:edit_post_path, 7], [:preview_post_path, 7],
    [:post_comments_path, 1], [:post_comment_path, 1, 2], [:post_comment_url, "x y", "ä"],
    [:archive_path], [:archive_path, 2024], [:page_path, "about"], [:page_path, "about", { format: :json }],
    [:post_path, 1, { anchor: "top" }], [:post_path, { id: 3 }], [:post_path, ActionController::Parameters.new(id: 4).permit!],
    [:post_path], [:post_path, 1, 2], [:post_path, nil], [:post_path, ""], [:post_path, Record.new(nil)],
    [:post_comment_path, 1], [:strict_user_path, 5], [:file_path, "a/b.txt"],
  ].freeze

  OPTIONS = [
    { host: "example.com" },
    { host: "example.com", protocol: "https", port: 8443 },
    { host: "example.com", script_name: "/blog" },
    { host: "example.com", trailing_slash: true },
    { host: "example.com", anchor: "x" },
    { host: "example.com", params: { locale: "fi" } },
    { only_path: true },
  ].freeze

  def outcome
    yield
  rescue StandardError => e
    [:raised, e.class, e.message]
  end

  def test_same_results_as_the_original_helpers
    OPTIONS.each do |options|
      CALLS.each do |name, *args|
        context = Context.new(options)
        compiled = outcome { context.public_send(name, *args.map { it.dup rescue it }) }
        original_name = Context.private_method_defined?(:"__ap_original_#{name}") ? :"__ap_original_#{name}" : name
        original = outcome { Context.new(options).__send__(original_name, *args) }
        assert_equal original, compiled, "#{name}(#{args.inspect}) with #{options}"
        # and again, now from the cache
        assert_equal original, outcome { context.public_send(name, *args) }, "#{name} cached"
      end
    end
  end

  def test_declines_globs_and_constrained_argument_segments
    context = Context.new(host: "example.com")
    context.post_path(1)
    context.strict_user_path(5)
    context.file_path("a/b")
    parts = context.instance_variable_get(:@__ap_route_parts)[2]
    assert_equal ["/posts/", ""], parts[:post_path][1]
    assert_equal false, parts[:strict_user_path][1] # :id is constrained to digits
    assert_equal false, parts[:file_path][1] # glob
  end

  def test_parts_are_shared_across_requests
    first = Context.new(host: "example.com", _recall: { controller: "posts", action: "show", id: "1" })
    first.post_path(1)
    second = Context.new(host: "example.com", _recall: { controller: "home", action: "index" })
    misses = 0
    ApMinimizer::Routes.singleton_class.prepend(Module.new { private define_method(:literal_parts) { |*a| misses += 1; super(*a) } })
    assert_equal "/posts/2", second.post_path(2)
    assert_equal 0, misses
    assert_equal "http://other.example/posts/2", Context.new(host: "other.example").post_url(2)
    assert_equal 1, misses # other url_options: other parts
  end

  # Most apps with a locale in their URLs: a constrained (:locale) scope and
  # default_url_options returning the locale, so Rails never takes its optimized path.
  LOCALE_ROUTES = ActionDispatch::Routing::RouteSet.new.tap do |routes|
    routes.draw do
      scope "(:locale)", locale: /en|ja/, defaults: { locale: nil } do
        resources :trips do
          resources :days, only: %i[index show]
        end
        get "about" => "pages#about", as: :about
      end
      get "trips/:trip_id/summary" => "trips#summary", as: :summary
    end
  end

  class LocaleContext
    include LOCALE_ROUTES.url_helpers

    def initialize(locale, recall) = (@locale, @recall = locale, recall)
    def default_url_options(options = {}) = options.merge(locale: @locale)
    def url_options = @url_options ||= { host: "example.com", _recall: @recall }.merge!(default_url_options).freeze
  end

  def test_locale_scopes_and_recall_like_rails
    recalls = [{}, { controller: "trips", action: "show", id: "5" }, { controller: "days", action: "index", trip_id: "7", locale: "ja" }]
    calls = [[:trip_path, 1], [:trip_path, "a b"], [:trips_path], [:trip_days_path, 3], [:trip_day_path, 3, 4], [:about_path],
             [:about_url], [:summary_path], [:summary_path, 9], [:trip_days_path], [:trip_path, 1, 2], [:trip_path, nil]]
    [nil, "ja", "en"].each do |locale|
      recalls.each do |recall|
        calls.each do |name, *args|
          compiled = outcome { LocaleContext.new(locale, recall).public_send(name, *args) }
          original = outcome { LocaleContext.new(locale, recall).__send__(:"__ap_original_#{name}", *args) }
          assert_equal original, compiled, "#{name}(#{args.inspect}) locale=#{locale.inspect} recall=#{recall}"
        end
      end
    end
  end

  def test_parts_depend_on_the_recall_rails_uses
    # Inside a request for trip 7, trip_days_path with no argument takes trip_id from the request.
    seven = LocaleContext.new(nil, { controller: "days", action: "index", trip_id: "7" })
    eight = LocaleContext.new(nil, { controller: "days", action: "index", trip_id: "8" })
    assert_equal seven.__send__(:__ap_original_trip_days_path), seven.trip_days_path
    assert_equal eight.__send__(:__ap_original_trip_days_path), eight.trip_days_path
    refute_equal seven.trip_days_path, eight.trip_days_path
    # With the argument given, the request's trip_id plays no part: one cache entry.
    assert_equal "/trips/3/days", LocaleContext.new(nil, { trip_id: "9" }).trip_days_path(3)
  end

  def test_locale_helpers_take_the_fast_path
    context = LocaleContext.new("ja", { controller: "trips", action: "show", id: "5" })
    expected = context.__send__(:__ap_original_trip_path, 1) # the route's locale: nil default wins, as in Rails
    assert_equal expected, context.trip_path(1)
    assert_equal [expected.delete_suffix("1"), ""], context.instance_variable_get(:@__ap_route_parts)[2][:trip_path][1]
  end

  # With eager loading, Rails frees route ASTs after finalizing (Route#glob? then raises).
  def test_works_after_rails_frees_route_asts
    routes = ActionDispatch::Routing::RouteSet.new
    routes.draw { resources :posts; get "files/*path" => "files#show", as: :file }
    routes.routes.each { it.path.instance_variable_set(:@ast, nil) } # what clear_ast leaves behind
    assert_raises(NoMethodError) { routes.named_routes.get(:post).glob? }
    klass = Class.new do
      include routes.url_helpers
      def url_options = @url_options ||= { host: "h" }.freeze
    end
    assert_equal "/posts/1", klass.new.post_path(1)
    assert_equal ["/posts/", ""], klass.new.tap { it.post_path(1) }.instance_variable_get(:@__ap_route_parts)[2][:post_path][1]
    assert_equal false, klass.new.tap { it.file_path("a") }.instance_variable_get(:@__ap_route_parts)[2][:file_path][1]
  end

  def test_results_are_new_strings
    context = Context.new(host: "example.com")
    a = context.root_path
    a << "?x"
    assert_equal "/", context.root_path
  end

  def test_default_url_options_turn_it_off_like_rails
    routes = ActionDispatch::Routing::RouteSet.new
    routes.draw { resources :posts }
    routes.default_url_options = { host: "h", trailing_slash: true }
    klass = Class.new do
      include routes.url_helpers
      def url_options = @url_options ||= _routes.default_url_options.dup.freeze
    end
    assert_equal klass.new.__send__(:__ap_original_post_path, 1), klass.new.post_path(1)
    assert_equal ["/posts/", "/"], klass.new.send(:__ap_route_parts, :post_path, 1) # Rails' full path, cached too
  end
end

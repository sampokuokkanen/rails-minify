# frozen_string_literal: true

require "test_helper"

class ActionTextPlainTextTest < Minitest::Test
  HTML = [
    "<div>Hello <b>world</b></div>",
    "<h1>Title</h1><p>One</p><p>Two &amp; three</p>",
    "<ul><li>a</li><li>b<ul><li>c</li></ul></li></ul><ol><li>x</li></ol>",
    "<blockquote>quote</blockquote><pre>  code\n  here</pre><a href='/x'>link</a>",
    "<div>line<br>break</div>   <div>  spaced  </div>",
    "",
  ].freeze
  WITH_ATTACHMENT = '<div>before<action-text-attachment content-type="text/plain" caption="cap"></action-text-attachment>after</div>'

  def plain(html) = ActionText::Content.new(html).to_plain_text

  def test_same_text_as_rails
    stock = (HTML + [WITH_ATTACHMENT]).map { plain(it) }
    RailsMinify::Patches::ActionTextPlainText.install!
    RailsMinify::Patches::ActionTextPlainText.clear!
    2.times { assert_equal stock, (HTML + [WITH_ATTACHMENT]).map { plain(it) } } # computed, then cached
  end

  def test_cached_once_per_html_and_results_are_fresh_strings
    RailsMinify::Patches::ActionTextPlainText.install!
    RailsMinify::Patches::ActionTextPlainText.clear!
    a = plain(HTML[1])
    a << " changed"
    refute_includes plain(HTML[1]), "changed"
    calls = 0
    ActionText::Fragment.prepend(Module.new { define_method(:to_plain_text) { calls += 1; super() } })
    3.times { plain(HTML[2]) }
    assert_equal 1, calls
    3.times { plain(WITH_ATTACHMENT) }
    assert_equal 4, calls # an attachment of a missing record: not cached
  end
end

class ActionTextPlainTextAttachmentsTest < Minitest::Test
  def setup
    @blob = ActiveStorage::Blob.create_and_upload!(io: StringIO.new("x"), filename: "beach.jpg", content_type: "image/jpeg")
    @captioned = ActiveStorage::Blob.create_and_upload!(io: StringIO.new("y"), filename: "hill.jpg", content_type: "image/jpeg")
    @html = "<div>Day one</div>#{tag(@blob)}<p>Day two</p>#{tag(@captioned, caption: "The hill")}" \
            '<action-text-attachment url="https://example.com/x.png" content-type="image/png"></action-text-attachment>'
    @stock = plain(@html)
    @calls = 0
    calls = -> { @calls += 1 }
    RailsMinify::Patches::ActionTextPlainText.install!
    RailsMinify::Patches::ActionTextPlainText.clear!
    ActionText::Fragment.prepend(Module.new { define_method(:to_plain_text) { calls.(); super() } })
  end

  def teardown = ActiveStorage::Blob.delete_all

  def tag(blob, caption: nil)
    %(<action-text-attachment sgid="#{blob.attachable_sgid}" content-type="image/jpeg"#{%( caption="#{caption}") if caption}></action-text-attachment>)
  end

  def plain(html) = ActionText::Content.new(html).to_plain_text

  def test_blobs_and_remote_images_are_cached_with_the_same_text
    assert_includes @stock, "[beach.jpg]"
    assert_includes @stock, "[The hill]"
    3.times { assert_equal @stock, plain(@html) }
    assert_equal 1, @calls
  end

  def test_a_renamed_or_deleted_blob_is_computed_again
    plain(@html)
    @blob.update!(filename: "sea.jpg")
    assert_includes plain(@html), "[sea.jpg]"
    assert_equal 2, @calls
    @captioned.update!(filename: "other.jpg") # captioned: its filename isn't in the text
    plain(@html)
    assert_equal 2, @calls
    ActiveStorage::Blob.where(id: @blob.id).delete_all # the row (Blob#delete deletes the file)
    refute_includes plain(@html), "sea.jpg"
    assert_equal 3, @calls
  end

  def test_only_captioned_blobs_need_no_query
    html = tag(@captioned, caption: "Only")
    plain(html)
    queries = 0
    counter = ->(*) { queries += 1 }
    ActiveSupport::Notifications.subscribed(counter, "sql.active_record") { 2.times { plain(html) } }
    assert_equal [1, 0], [@calls, queries]
  end

  def test_other_attachables_are_not_cached
    record = Class.new { include GlobalID::Identification; def id = 1; def attachable_plain_text_representation(_) = "[#{rand}]" }
    content = ActionText::Content.new(@html)
    content.define_singleton_method(:attachments) { [Struct.new(:attachable, :caption).new(record.new, nil)] }
    2.times { content.to_plain_text }
    assert_equal 2, @calls
  end
end

class OmniAuthPassthroughTest < Minitest::Test
  class Probe
    include OmniAuth::Strategy
    option :name, "probe"
    def request_phase = [200, {}, ["request phase"]]
    def callback_phase = [200, {}, ["callback phase"]]
  end

  def setup
    OmniAuth.config.test_mode = false
    OmniAuth.config.request_validation_phase = nil
    @app_calls = 0
    @dups = 0
    inner = ->(_env) { @app_calls += 1; [200, {}, ["app"]] }
    @strategy = Probe.new(inner)
    dups = -> { @dups += 1 }
    @strategy.define_singleton_method(:dup) { dups.call; super() }
  end

  def call(path, session: {}, method: "GET")
    env = Rack::MockRequest.env_for(path, method: method)
    env["rack.session"] = session if session
    _, _, body = @strategy.call(env)
    body.join
  end

  def test_other_paths_skip_omniauth
    RailsMinify::Patches::OmniAuthPassthrough.install!
    assert_equal "app", call("/trips/1")
    assert_equal "app", call("/")
    assert_equal 0, @dups
  end

  def test_omniauth_paths_run_omniauth
    RailsMinify::Patches::OmniAuthPassthrough.install!
    assert_equal "request phase", call("/auth/probe", method: "POST")
    assert_equal "callback phase", call("/auth/probe/callback")
    assert_equal "callback phase", call("/AUTH/probe/callback")
    assert_equal "app", call("/auth/other") # under the prefix: OmniAuth decides (passes it on)
    assert_equal 4, @dups
  end

  def test_no_session_still_raises_like_omniauth
    RailsMinify::Patches::OmniAuthPassthrough.install!
    assert_raises(OmniAuth::NoSessionError) { call("/trips/1", session: nil) }
  end

  def test_not_installed_when_omniauth_skips_these_requests_itself
    patch = RailsMinify::Patches::OmniAuthPassthrough
    upstream = Module.new { def passthrough?(_env) = false }
    released = Module.new
    patch.install!(upstream)
    patch.install!(released)
    refute upstream < patch
    assert released < patch
  end

  # A strategy that decides for itself which requests are its own (here: any
  # path ending in /sso) always runs.
  class OwnPaths < Probe
    option :name, "own"
    def on_callback_path? = current_path.end_with?("/sso")
  end

  def test_strategies_with_their_own_path_logic_always_run
    RailsMinify::Patches::OmniAuthPassthrough.install!
    strategy = OwnPaths.new(->(_env) { [200, {}, ["app"]] })
    env = Rack::MockRequest.env_for("/accounts/sso").merge("rack.session" => {})
    assert_equal ["callback phase"], strategy.call(env)[2]
  end
end

class RequestHostTest < Minitest::Test
  def setup = RailsMinify::Patches::RequestHost.install!

  def request(env) = ActionDispatch::Request.new(env)

  def test_same_hosts_as_rails
    {
      { "HTTP_HOST" => "example.com" } => "example.com",
      { "HTTP_HOST" => "example.com:8080" } => "example.com",
      { "HTTP_HOST" => "[::1]" } => "[::1]",
      { "HTTP_HOST" => "[::1]:3000" } => "[::1]",
      { "SERVER_NAME" => "example.org", "SERVER_PORT" => "443" } => "example.org",
      { "HTTP_HOST" => "a.com", "HTTP_X_FORWARDED_HOST" => "b.com:81, c.com" } => "c.com",
    }.each { |env, host| assert_equal host, request(env).host, env.inspect }
  end

  def test_no_allocations_without_a_port_and_on_repeated_reads
    plain = request("HTTP_HOST" => "example.com")
    ported = request("HTTP_HOST" => "example.com:8080")
    [plain, ported].each(&:host)
    before = GC.stat(:total_allocated_objects)
    1000.times { plain.host; ported.host }
    assert_operator GC.stat(:total_allocated_objects) - before, :<, 10 # none per call (the measurement itself allocates)
  end

  def test_a_changed_host_is_seen
    req = ActionDispatch::TestRequest.create("HTTP_HOST" => "a.com")
    assert_equal "a.com", req.host
    req.host = "b.com:3000"
    assert_equal "b.com", req.host
  end
end

# frozen_string_literal: true

# A page rendering 50 partials with two link_to each.
#   ruby -Ilib bench/views.rb stock|compiled [--yjit]   (one process per mode)
require "benchmark/ips"
require "action_view"
require "ap_minimizer"

mode = ARGV[0] || "compiled"
ApMinimizer::Views.install! if mode == "compiled"
dir = ENV.fetch("VIEWS", "/tmp/apv/views")
view_class = ActionView::Base.with_empty_template_cache
comments = (1..50).map { "comment-#{it}" }
# As in an app: one resolver (templates compiled once), a new view per request.
lookup = ActionView::LookupContext.new([dir])
render = -> { view_class.new(lookup, {}, nil).render(template: "pages/list", locals: { comments: comments }) }
render.call
ips = Benchmark.ips(quiet: true) do |x|
  x.config(warmup: 1, time: 3)
  x.report(mode, &render)
end.entries.first.ips
printf "  %-9s YJIT=%-5s %7.1f µs per page\n", mode, !!(defined?(RubyVM::YJIT) && RubyVM::YJIT.enabled?), 1e6 / ips

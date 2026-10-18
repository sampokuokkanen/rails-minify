# frozen_string_literal: true

# 50 link_to calls with literal html options in one template.
#   ruby -Ilib bench/links.rb stock|compiled [--yjit]   (one process per mode)
require "benchmark/ips"
require "action_view"
require "ap_minimizer"

mode = ARGV[0] || "compiled"
ApMinimizer::Views.install! if mode == "compiled"
lookup = ActionView::LookupContext.new([ENV.fetch("VIEWS", "/tmp/apv3/views")])
view_class = ActionView::Base.with_empty_template_cache
render = -> { view_class.new(lookup, {}, nil).render(template: "pages/links") }
render.call
ips = Benchmark.ips(quiet: true) { |x| x.config(warmup: 1, time: 3); x.report(mode, &render) }.entries.first.ips
printf "  %-9s YJIT=%-5s %6.1f µs per page (%.2f µs per link)\n", mode, !!(defined?(RubyVM::YJIT) && RubyVM::YJIT.enabled?), 1e6 / ips, 1e6 / ips / 50

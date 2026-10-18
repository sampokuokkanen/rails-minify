# frozen_string_literal: true

# Named route helpers, Rails' optimized path vs compiled. ruby -Ilib bench/routes.rb [--yjit]
require "benchmark/ips"
require "action_controller"
require "ap_minimizer"

ApMinimizer::Routes.install!
ROUTES = ActionDispatch::Routing::RouteSet.new
ROUTES.draw do
  root to: "home#index"
  resources(:posts) { resources :comments }
end

class Context
  include ROUTES.url_helpers
  def url_options = @url_options ||= { host: "example.com", protocol: "https" }.freeze
end

Post = Struct.new(:to_param)
post = Post.new("123")
c = Context.new
puts "YJIT: #{!!(defined?(RubyVM::YJIT) && RubyVM::YJIT.enabled?)}"
{
  "root_path" => [-> { c.__send__(:__ap_original_root_path) }, -> { c.root_path }],
  "post_path(post)" => [-> { c.__send__(:__ap_original_post_path, post) }, -> { c.post_path(post) }],
  "post_comment_path(post, 7)" => [-> { c.__send__(:__ap_original_post_comment_path, post, 7) }, -> { c.post_comment_path(post, 7) }],
  "post_url(post)" => [-> { c.__send__(:__ap_original_post_url, post) }, -> { c.post_url(post) }],
}.each do |label, (stock, compiled)|
  r = Benchmark.ips(quiet: true) do |x|
    x.config(warmup: 1, time: 2)
    x.report("stock", &stock)
    x.report("compiled", &compiled)
  end.entries.to_h { [it.label, 1e9 / it.ips] }
  printf "  %-28s stock %6.0f ns   compiled %5.0f ns   (%.1fx)\n", label, r["stock"], r["compiled"], r["stock"] / r["compiled"]
end

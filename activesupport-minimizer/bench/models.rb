# frozen_string_literal: true

# Model callback chains through ActiveSupport vs unrolled.
#   ruby -Ilib bench/models.rb [--yjit]
require "benchmark/ips"
require "active_record"
require "as_minimizer"

ActiveRecord::Base.establish_connection(adapter: "sqlite3", database: ":memory:")
ActiveRecord::Migration.verbose = false
ActiveRecord::Base.logger = nil
ActiveRecord::Schema.define { create_table(:posts) { |t| t.string :title; t.string :state; t.string :slug; t.text :body } }

class Post < ActiveRecord::Base
  after_initialize :set_defaults
  before_validation :normalize_title
  validates :title, presence: true, length: { maximum: 200 }
  validates :state, inclusion: { in: %w[draft published] }
  validate :body_not_spam, if: -> { body.present? }
  before_save :set_slug
  before_save :touch_published, if: :published?
  after_save :enqueue_indexing
  after_save :bust_cache, unless: -> { state == "draft" }

  private

  def set_defaults = (self.state ||= "draft")
  def normalize_title = (self.title = title&.strip)
  def body_not_spam = nil
  def set_slug = (self.slug = title&.parameterize)
  def published? = state == "published"
  def touch_published = nil
  def enqueue_indexing = nil
  def bust_cache = nil
end

AsMinimizer::Unroller.install!
post = Post.new(title: "Hello", body: "x")
puts "YJIT: #{!!(defined?(RubyVM::YJIT) && RubyVM::YJIT.enabled?)}"
results = {}
{ "valid?" => -> { post.valid? }, "Post.new" => -> { Post.new }, "create (SQLite :memory:)" => -> { Post.create!(title: "Hi") } }.each do |label, work|
  Benchmark.ips(quiet: true) do |x|
    x.config(warmup: 1, time: 2)
    x.report("stock") { AsMinimizer::Unroller.disable!; work.call }
    x.report("unrolled") { AsMinimizer::Unroller.install!; work.call }
  end.entries.each { results[[label, it.label]] = 1e6 / it.ips }
  printf "  %-26s stock %7.2f µs   unrolled %7.2f µs   (%+.0f%%)\n", label, results[[label, "stock"]], results[[label, "unrolled"]],
    (results[[label, "unrolled"]] / results[[label, "stock"]] - 1) * 100
end

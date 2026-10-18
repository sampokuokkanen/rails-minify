# frozen_string_literal: true

# Enum predicates: Rails' closures vs compiled. ruby -Ilib bench/enums.rb [--yjit]
require "benchmark/ips"
require "active_record"
require "ar_minimizer"

ActiveRecord::Base.establish_connection(adapter: "sqlite3", database: ":memory:")
ActiveRecord::Migration.verbose = false
ActiveRecord::Schema.define { create_table(:posts) { |t| t.integer :status, default: 1; t.string :kind, default: "article" } }

ENUMS = proc do
  self.table_name = "posts"
  enum :status, { draft: 0, published: 1, archived: 2 }
  enum :kind, { article: "article", video: "video" }
end
class StockPost < ActiveRecord::Base; class_eval(&ENUMS); end
ArMinimizer::Enums.install!
class CompiledPost < ActiveRecord::Base; class_eval(&ENUMS); end

StockPost.create!
stock = StockPost.first
compiled = CompiledPost.first
puts "YJIT: #{!!(defined?(RubyVM::YJIT) && RubyVM::YJIT.enabled?)}"
{ "published? (integer)" => :published?, "video? (string)" => :video? }.each do |label, m|
  r = Benchmark.ips(quiet: true) do |x|
    x.config(warmup: 1, time: 2)
    x.report("stock") { stock.public_send(m) }
    x.report("compiled") { compiled.public_send(m) }
  end.entries.to_h { [it.label, 1e9 / it.ips] }
  printf "  %-22s stock %5.0f ns   compiled %5.0f ns   (%.1fx)\n", label, r["stock"], r["compiled"], r["stock"] / r["compiled"]
end

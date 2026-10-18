# frozen_string_literal: true

# Load 1,000 records and read three attributes from each, stock vs SmallRecords.
#   ruby -Ilib bench/small_records.rb stock|small [--yjit]
require "benchmark/ips"
require "objspace"
require "active_record"
require "ar_minimizer"

mode = ARGV[0] || "small"
ArMinimizer::SmallRecords.install! if mode == "small"
ActiveRecord::Base.establish_connection(adapter: "sqlite3", database: ":memory:")
ActiveRecord::Migration.verbose = false
ActiveRecord::Base.logger = nil
ActiveRecord::Schema.define { create_table(:users) { |t| 20.times { t.string "c#{it}" }; t.timestamps } }
class User < ActiveRecord::Base; end
User.insert_all(Array.new(1000) { |i| { c0: "x#{i}", c1: "y#{i}", created_at: Time.now, updated_at: Time.now } })

load = -> { User.all.to_a.each { |u| u.c0; u.c1; u.created_at } }
load.call
GC.start
before = ObjectSpace.memsize_of_all
records = User.all.to_a.each { |u| u.c0; u.c1; u.created_at }
GC.start
retained = ObjectSpace.memsize_of_all - before
ips = Benchmark.ips(quiet: true) { |x| x.config(warmup: 1, time: 3); x.report(mode, &load) }.entries.first.ips
printf "  %-6s YJIT=%-5s load+read 1000: %6.2f ms   retained by 1000 records: %5.0f KB\n", mode,
  !!(defined?(RubyVM::YJIT) && RubyVM::YJIT.enabled?), 1000 / ips, retained / 1024.0
records.size

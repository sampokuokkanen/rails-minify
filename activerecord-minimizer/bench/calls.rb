# frozen_string_literal: true

# Per-call cost of attribute pattern methods, plain call site vs compiled one.
# Slim is process-wide, so run each mode in its own process:
#   ruby -Ilib bench/calls.rb stock|slim [--yjit]
require "benchmark/ips"
require "active_record"
require "ar_minimizer"

mode = ARGV[0] || "slim"
ArMinimizer::Slim.enable!(strict: false) if mode == "slim"

ActiveRecord::Base.establish_connection(adapter: "sqlite3", database: ":memory:")
ActiveRecord::Migration.verbose = false
ActiveRecord::Schema.define { create_table(:users) { |t| t.string :name; t.integer :age; t.boolean :active } }
class User < ActiveRecord::Base; end

CALLS = %w[name? age? active? name_changed?].freeze
SOURCE = CALLS.each_with_index.map { |call, i| "def m#{i}(u) = u.#{call}\n" }.join
module Plain; extend self; class_eval(SOURCE); end
module Compiled; extend self
  class_eval(ArMinimizer::Rewriter.new(index: ArMinimizer::Index.from_models([User])).rewrite(SOURCE).source)
end

u = User.create!(name: "a", age: 1, active: true)
puts "#{mode}, YJIT: #{!!(defined?(RubyVM::YJIT) && RubyVM::YJIT.enabled?)}, generated name?: #{User.method_defined?(:name?)}"
Benchmark.ips(quiet: true) do |x|
  x.config(warmup: 1, time: 2)
  CALLS.each_with_index do |call, i|
    x.report("#{mode} #{call} plain") { Plain.public_send(:"m#{i}", u) }
    x.report("#{mode} #{call} compiled") { Compiled.public_send(:"m#{i}", u) }
  end
end.entries.each { printf "  %-32s %7.0f ns\n", it.label, 1e9 / it.ips }

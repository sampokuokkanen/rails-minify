# frozen_string_literal: true

# Memory and time ActiveRecord spends generating attribute methods, stock vs slim.
#   ruby -Ilib bench/memory.rb [stock|slim] [models] [columns]
# Run each mode in its own process.
require "objspace"
require "active_record"
require "ar_minimizer"

mode, models, columns = ARGV[0] || "slim", Integer(ARGV[1] || 100), Integer(ARGV[2] || 30)
ArMinimizer::Slim.enable!(strict: false) if mode == "slim"

ActiveRecord::Base.establish_connection(adapter: "sqlite3", database: ":memory:")
ActiveRecord::Migration.verbose = false
classes = Array.new(models) do |i|
  ActiveRecord::Schema.define do
    create_table("t#{i}") { |t| columns.times { t.string "col_#{it}" } }
  end
  Class.new(ActiveRecord::Base) { self.table_name = "t#{i}" }.tap { Object.const_set("M#{i}", it) }
end
classes.each(&:load_schema)

GC.start
GC.compact if GC.respond_to?(:compact)
rss = -> { Integer(`ps -o rss= -p #{Process.pid}`) * 1024 }
rss_before = rss.call
iseq_before = ObjectSpace.memsize_of_all(RubyVM::InstructionSequence)
total_before = ObjectSpace.memsize_of_all
t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
classes.each(&:define_attribute_methods)
elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0
GC.start

methods = classes.sum { it.send(:generated_attribute_methods).instance_methods(false).size }
iseq = ObjectSpace.memsize_of_all(RubyVM::InstructionSequence) - iseq_before
total = ObjectSpace.memsize_of_all - total_before
rss_delta = rss.call - rss_before
printf "%-5s %d models x %d cols: %6d generated methods, iseq +%4.1f MB, heap +%4.1f MB, RSS +%5.1f MB, define_attribute_methods %4.0f ms\n",
  mode, models, columns, methods, iseq / 1e6, total / 1e6, rss_delta / 1e6, elapsed * 1000

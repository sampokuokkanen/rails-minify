# frozen_string_literal: true

require "test_helper"

ArMinimizer::Enums.install!

ActiveRecord::Schema.define do
  create_table(:tasks, force: true) do |t|
    t.integer :status, default: 0
    t.string :kind, default: "chore"
    t.integer :priority, default: 0
    t.string :stage, default: "in progress"
    t.integer :level, default: 0
    t.float :weight
  end
end

class Task < ActiveRecord::Base
  enum :status, { pending: 0, active: 1, done: 2 }
  enum :kind, { chore: "chore", bug: "bug" }, prefix: true
  enum :priority, %i[low high], suffix: :priority
  enum :stage, { "in progress" => "in progress", "done!" => "finished" }, prefix: :stage
  enum :level, { beginner: 0, expert: 1 }, instance_methods: false
  enum :weight, { light: 1.5, heavy: Float::INFINITY }, scopes: false

  # An override the predicate must still go through.
  def priority_for_database = super
end

# The same enums with Rails' own closures, for comparison.
ArMinimizer::Enums.disable!
class StockTask < ActiveRecord::Base
  self.table_name = "tasks"
  enum :status, { pending: 0, active: 1, done: 2 }
  enum :kind, { chore: "chore", bug: "bug" }, prefix: true
  enum :priority, %i[low high], suffix: :priority
  enum :stage, { "in progress" => "in progress", "done!" => "finished" }, prefix: :stage
  enum :level, { beginner: 0, expert: 1 }, instance_methods: false
  enum :weight, { light: 1.5, heavy: Float::INFINITY }, scopes: false
  def priority_for_database = super
end
ArMinimizer::Enums.install!

class EnumsTest < Minitest::Test
  PREDICATES = %i[pending? active? done? kind_chore? kind_bug? low_priority? high_priority? stage_in_progress? light? heavy?].freeze

  def snapshot(task) = PREDICATES.to_h { [it, task.public_send(it)] }

  def test_compiled_where_the_data_is_literal
    assert_includes Task.instance_method(:active?).source_location.first, "enum Task.status"
    assert_includes Task.instance_method(:kind_bug!).source_location.first, "enum Task.kind"
    assert_includes Task.instance_method(:stage_in_progress?).source_location.first, "enum Task.stage" # the alias of "in progress"
    assert_includes Task.instance_method(:light?).source_location.first, "enum Task.weight" # 1.5
    refute_includes Task.instance_method(:heavy?).source_location.first, "enum Task" # Infinity has no literal: Rails' closure
    refute Task.method_defined?(:beginner?) # instance_methods: false
  end

  def test_same_answers_as_rails
    task = Task.create!
    expected = { pending?: true, active?: false, done?: false, kind_chore?: true, kind_bug?: false, low_priority?: true,
                 high_priority?: false, stage_in_progress?: true, light?: false, heavy?: false }
    assert_equal expected, snapshot(task)

    task.active!
    task.kind_bug!
    task.high_priority!
    task.heavy!
    assert task.reload.active?
    assert_equal({ "status" => "active", "kind" => "bug", "priority" => "high" }, task.attributes.slice("status", "kind", "priority"))
    assert task.heavy?
    assert task.high_priority?
    task.status = :done
    assert task.done? # before save: reads the in-memory value, as Rails does
    refute task.active?
  end

  def test_matches_rails_closures_in_every_state
    assert StockTask.instance_method(:active?).source_location.first.end_with?("active_record/enum.rb") # Rails' closure
    bangs = %i[pending! active! done! kind_chore! kind_bug! low_priority! high_priority! stage_in_progress! light! heavy!]
    bangs.each do |bang|
      compiled = Task.create!
      stock = StockTask.find(compiled.id)
      assert_equal snapshot(stock), snapshot(compiled), "fresh"
      compiled.public_send(bang)
      stock.public_send(bang)
      assert_equal snapshot(stock), snapshot(compiled), bang.to_s
      assert_equal StockTask.find(stock.id).attributes, Task.find(compiled.id).attributes, "#{bang} saved"
    end
  end

  def test_bang_methods_raise_like_rails
    task = Task.create!
    Task.class_eval { validate { errors.add(:base, "no") if done? } }
    assert_raises(ActiveRecord::RecordInvalid) { task.done! }
  ensure
    Task.clear_validators!
    Task._validate_callbacks.clear
  end
end

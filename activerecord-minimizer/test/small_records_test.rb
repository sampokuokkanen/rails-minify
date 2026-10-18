# frozen_string_literal: true

require "test_helper"
require "objspace"

ArMinimizer::SmallRecords.install!

ActiveRecord::Schema.define do
  create_table(:authors, force: true) { |t| t.string :name; t.integer :rank, default: 0 }
  create_table(:books, force: true) { |t| t.references :author; t.string :title }
end

class Author < ActiveRecord::Base
  has_many :books
end

class Book < ActiveRecord::Base
  belongs_to :author
end

class SmallRecordsTest < Minitest::Test
  EMPTY = ArMinimizer::SmallRecords::EMPTY

  def setup
    super
    Book.delete_all
    Author.delete_all
    ActiveRecord::Base.connection.execute("DELETE FROM sqlite_sequence WHERE name IN ('authors', 'books')") # same ids each run
    a = Author.create!(name: "Ann")
    Book.create!(author: a, title: "One")
    Author.create!(name: "Bob")
  end

  def with_small(on)
    on ? ArMinimizer::SmallRecords.install! : ArMinimizer::SmallRecords.disable!
    yield
  ensure
    ArMinimizer::SmallRecords.install!
  end

  def outcome
    [yield]
  rescue StandardError => e
    [:raised, e.class]
  end

  SCENARIOS = {
    "read" => -> { a = Author.order(:id).first; [a.name, a.rank, a.attributes, a.changed?] },
    "write and save" => -> { a = Author.order(:id).first; a.name = "Ann 2"; [a.changes, a.save, a.reload.name, a.saved_changes.keys] },
    "dirty checks only" => -> { a = Author.order(:id).first; [a.name_changed?, a.changed_attributes, a.attribute_names] },
    "association" => -> { a = Author.order(:id).first; [a.books.map(&:title), a.association(:books).loaded?, a.association_cached?(:books)] },
    "includes" => -> { Author.includes(:books).order(:id).map { [it.name, it.books.size] } },
    "belongs_to" => -> { Book.first.author.name },
    "partial select" => -> { a = Author.select(:id).first; [a.id, (a.name rescue :missing), a.has_attribute?(:name)] },
    "dup" => -> { d = Author.order(:id).first.dup; d.name = "Copy"; [d.new_record?, d.save, Author.count] },
    "clone" => -> { a = Author.order(:id).first; c = a.clone; c.name = "Clone"; [a.name, c.name] },
    "destroy then write" => -> { a = Author.order(:id).last; a.destroy; a.name = "x" },
    "freeze then write" => -> { a = Author.order(:id).first; a.freeze; a.name = "x" },
    "reload" => -> { a = Author.order(:id).first; a.books.to_a; Author.where(id: a.id).update_all(name: "R"); a.reload; [a.name, a.association_cached?(:books)] },
    "new record" => -> { a = Author.new(name: "N"); [a.attributes, a.save, a.books.to_a] },
    "to_json" => -> { Author.order(:id).first.as_json },
  }.freeze

  def test_same_behavior_as_rails
    SCENARIOS.each do |name, scenario|
      stock = with_small(false) { setup; outcome(&scenario) }
      small = with_small(true) { setup; outcome(&scenario) }
      assert_equal stock, small, name
    end
    assert_equal [:raised, FrozenError], SCENARIOS["destroy then write"].then { |s| setup; outcome(&s) }
  end

  def test_read_only_records_share_the_empty_hashes
    a = Author.order(:id).first
    a.name
    cache = a.instance_variable_get(:@association_cache)
    assert cache.nil? || cache.equal?(EMPTY), "no association cache of its own (Rails main: none at all)"
    assert a.instance_variable_get(:@attributes).instance_variable_get(:@attributes).equal?(EMPTY)
    a.books.to_a
    assert_kind_of Hash, a.instance_variable_get(:@association_cache)
    refute a.instance_variable_get(:@association_cache).equal?(EMPTY)
    a.name = "changed"
    refute a.instance_variable_get(:@attributes).instance_variable_get(:@attributes).equal?(EMPTY)
    refute EMPTY.any?
  end

  def own_bytes(record, other)
    reach = lambda do |root|
      seen = {}.compare_by_identity
      stack = [root]
      until stack.empty?
        o = stack.pop
        next if seen[o] || o.is_a?(Module) || o.nil? || o == true || o == false || o.is_a?(Integer) || o.is_a?(Symbol)
        seen[o] = true
        ObjectSpace.reachable_objects_from(o)&.each { stack << it unless it.is_a?(ObjectSpace::InternalObjectWrapper) }
      end
      seen
    end
    mine = reach.(record)
    theirs = reach.(other)
    mine.keys.reject { theirs.key?(it) }.sum { ObjectSpace.memsize_of(it) }
  end

  def test_records_are_smaller
    stock = with_small(false) { a, b = Author.order(:id).to_a; a.name; b.name; own_bytes(a, b) }
    small = with_small(true) { a, b = Author.order(:id).to_a; a.name; b.name; own_bytes(a, b) }
    # The attribute set's Hash, and the association cache where Rails
    # allocates one up front (8.0, 8.1; main leaves it nil until used).
    hashes = with_small(false) { Author.new.instance_variable_get(:@association_cache) } ? 2 : 1
    assert_operator stock - small, :>=, hashes * 160 - 1, "stock #{stock} B, small #{small} B"
  end
end

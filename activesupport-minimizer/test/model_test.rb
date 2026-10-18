# frozen_string_literal: true

require "test_helper"

ActiveRecord::Schema.define do
  create_table(:articles) { |t| t.string :title; t.string :state; t.integer :views, default: 0 }
end

class AuditTrail
  def self.before_save(record) = record.log << :audit_before_save
  def self.after_save(record) = record.log << :audit_after_save
  def self.around_save(record) = (record.log << :audit_in; yield; record.log << :audit_out)
end

class TitleValidator < ActiveModel::Validator
  def validate(record) = (record.log << :title_validator; record.errors.add(:title, "bad") if record.title == "bad")
end

class Article < ActiveRecord::Base
  attr_accessor :abort_at, :log

  after_initialize { @log = [] }
  before_validation :strip_title
  before_validation :default_state, on: :create
  validates :title, presence: true
  validates_with TitleValidator
  validate :not_spam, unless: -> { title.to_s.start_with?("ok") }
  validate(on: :update) { log << :update_only_validation }
  after_validation { log << :after_validation }

  before_save :first
  before_save :maybe_abort
  before_save AuditTrail
  before_save :if_published, if: :published?
  around_save :wrap_save
  around_save AuditTrail
  after_save :after_one
  after_save :unless_draft, unless: -> { state == "draft" }
  after_save AuditTrail

  before_create { log << :before_create }
  around_create :wrap_create
  around_create ->(record, block) { record.log << :yields_an_argument; block.call(record) } # as ActiveJob's logging does
  after_create { log << :after_create }
  before_update { maybe(:update); log << :before_update }
  after_update { log << :after_update }

  before_destroy { maybe(:destroy); log << :before_destroy }
  after_destroy { log << :after_destroy }

  after_commit { log << :after_commit }
  after_rollback { log << :after_rollback }

  private

  def maybe(at) = (throw(:abort) if abort_at == at)
  def strip_title = (log << :strip_title; self.title = title&.strip)
  def default_state = (log << :default_state; self.state ||= "draft")
  def not_spam = (log << :not_spam; errors.add(:title, "spam") if title == "spam")
  def first = log << :first
  def maybe_abort = (log << :maybe_abort; maybe(:save))
  def published? = state == "published"
  def if_published = log << :if_published
  def wrap_save = (log << :wrap_save_in; yield; log << :wrap_save_out)
  def wrap_create = (log << :wrap_create_in; maybe(:around_create); yield; log << :wrap_create_out)
  def after_one = log << :after_one
  def unless_draft = log << :unless_draft
end

class ModelTest < Minitest::Test
  include Compare

  def setup = Article.delete_all

  SCENARIOS = {
    "create" => -> { a = Article.new(title: " t "); [a.save, a.log, a.errors.to_a, a.persisted?] },
    "create published" => -> { a = Article.new(title: "ok", state: "published"); [a.save, a.log] },
    "create invalid" => -> { a = Article.new(title: ""); [a.save, a.log, a.errors.to_a] },
    "create spam" => -> { a = Article.new(title: "spam"); [a.save, a.log, a.errors.to_a] },
    "validator" => -> { a = Article.new(title: "bad"); [a.valid?, a.log, a.errors.to_a] },
    "abort in before_save" => -> { a = Article.new(title: "t", abort_at: :save); [a.save, a.log, a.persisted?] },
    "abort in around_create" => -> { a = Article.new(title: "t", abort_at: :around_create); [a.save, a.log, a.persisted?] },
    "save! aborted" => -> { a = Article.new(title: "t", abort_at: :save); a.save!; a.log },
    "update" => -> { a = Article.create!(title: "t"); a.log.clear; [a.update(title: "u", state: "published"), a.log] },
    "abort in before_update" => -> { a = Article.create!(title: "t"); a.log.clear; a.abort_at = :update; [a.update(title: "u"), a.log, a.reload.title] },
    "destroy" => -> { a = Article.create!(title: "t"); a.log.clear; [a.destroy.destroyed?, a.log] },
    "abort destroy" => -> { a = Article.create!(title: "t"); a.log.clear; a.abort_at = :destroy; [a.destroy, a.log, Article.exists?(a.id)] },
    "rollback" => -> { a = Article.new(title: "t"); Article.transaction { a.save!; raise ActiveRecord::Rollback }; a.log },
    "find runs initialize" => -> { Article.create!(title: "t"); Article.first.log },
  }.freeze

  def test_same_behavior_as_activesupport
    SCENARIOS.each do |name, scenario|
      stock, unrolled = stock_and_unrolled { setup; scenario.call }
      assert_equal stock, unrolled, name
    end
  end

  def test_the_scenarios_exercise_things
    _, unrolled = stock_and_unrolled { setup; SCENARIOS["create"].call }
    saved, log, errors, persisted = unrolled
    assert saved
    assert persisted
    assert_empty errors
    assert_equal %i[strip_title default_state title_validator not_spam after_validation first maybe_abort audit_before_save
                    wrap_save_in audit_in before_create wrap_create_in], log.first(12)
    assert_equal [:raised, ActiveRecord::RecordNotSaved, "Failed to save the record"],
      stock_and_unrolled { setup; SCENARIOS["save! aborted"].call }.last
    assert_includes AsMinimizer::Unroller.source_for(Article, :save), "catch(:abort)"
  end

  def test_backtraces_name_the_unrolled_chain
    AsMinimizer::Unroller.install!
    klass = Class.new(Article) { def self.name = "Exploding"; before_save { raise "boom" } }
    error = assert_raises(RuntimeError) { klass.new(title: "t").save }
    assert error.backtrace.any? { it.start_with?("unrolled: Exploding#save:") }, error.backtrace.first(8).join("\n")
  end

  def test_source_dir
    Dir.mktmpdir do |dir|
      AsMinimizer::Unroller.source_dir = dir
      klass = Class.new(Article) { def self.name = "Written"; before_save { raise "boom" } }
      error = assert_raises(RuntimeError) { klass.new(title: "t").save }
      path = File.join(dir, "Written/save.rb")
      assert File.exist?(path)
      assert error.backtrace.any? { it.start_with?("#{path}:") }
      assert_includes File.read(path), "def __as_save"
    ensure
      AsMinimizer::Unroller.source_dir = nil
    end
  end
end

# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)

require "minitest/autorun"
require "fileutils"
require "tmpdir"
require "delegate"
require "active_record"
require "ar_minimizer"

ActiveRecord::Base.establish_connection(adapter: "sqlite3", database: ":memory:")
ActiveRecord::Migration.verbose = false
ActiveRecord::Base.logger = nil

ActiveRecord::Schema.define do
  create_table :users do |t|
    t.string :name
    t.integer :age
    t.boolean :active
    t.integer :status, default: 0
    t.decimal :balance, precision: 10, scale: 2
    t.datetime :born_at
    t.timestamps
  end

  create_table :posts do |t|
    t.references :user
    t.string :title
    t.string :name # same column name as users.name: one index entry serves both
  end
end

class User < ActiveRecord::Base
  enum :status, { pending: 0, verified: 1 }
  alias_attribute :title, :name
  has_many :posts

  # Hand-written, calls the generated method: must keep working, must not be compiled.
  def age_changed? = super || false

  def summary = [name?, self.active?, saved_change_to_name?, title_changed?]
end

class Post < ActiveRecord::Base
  belongs_to :user, optional: true
end

# Not a model, but answers name? too: compiled call sites must still reach it.
class Poro
  def name? = :poro
  def name_changed? = :poro
  def saved_change_to_name?(**) = :poro
end

module SlimHelpers
  # Not strict: these tests compare the fallback against stock Rails.
  def with_slim(on)
    was = ArMinimizer::Slim.enabled?
    on ? ArMinimizer::Slim.enable!(strict: false) : ArMinimizer::Slim.disable!
    yield
  ensure
    was ? ArMinimizer::Slim.enable!(strict: false) : ArMinimizer::Slim.disable!
  end

  # [value] or [:raised, ErrorClass]
  def outcome
    [yield]
  rescue StandardError => e
    [:raised, e.class]
  end

  def index = ArMinimizer::Index.from_models([User, Post])

  # With guards: these tests are about the guarded form.
  def rewrite(source, path: "x.rb") = ArMinimizer::Rewriter.new(index: index, path: path, guards: true).rewrite(source)
end

class Minitest::Test
  include SlimHelpers

  def setup
    Post.delete_all
    User.delete_all
  end
end

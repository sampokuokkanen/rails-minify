# frozen_string_literal: true

require "test_helper"

ActiveRecord::Schema.define do
  create_table(:loop_trips) { |t| t.string :title; t.integer :total, default: 0 }
end

class LongChainController < ActionController::Base
  before_action :one
  before_action :two
  before_action :three, only: :index
  before_action :four
  before_action :five
  before_action :six, only: :index
  def index = head(:ok)
  def show = head(:ok)

  private

  def one = nil
  def two = nil
  def three = nil
  def four = nil
  def five = nil
  def six = nil
end
class LongChainCopyController < LongChainController; end

# A base every controller inherits, like ApplicationController: excluded by name.
class BasicsController < ActionController::Base
  before_action :zone
  before_action :locale
  around_action :tag_logs
  before_action :current_user
  before_action :variant
  after_action :track

  private

  def zone = nil
  def locale = nil
  def tag_logs = yield
  def current_user = nil
  def variant = nil
  def track = nil
end

class TripsCheckController < BasicsController
  before_action :set_trip
  def show = head(:ok)

  private

  def set_trip = nil
end

class LoopTrip < ActiveRecord::Base
  after_save :recalculate                            # save on self: runs after_save again
  after_save :touch_total, if: :saved_change_to_title? # guarded
  after_save :safe_total                             # update_column skips callbacks
  before_validation :normalize

  private

  def recalculate = update!(total: total + 1)
  def touch_total = save
  def safe_total = update_column(:total, total)
  def normalize = self.title = title.to_s.strip
end

class ChainCheckTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)

  def long(limit) = AsMinimizer::Check.long_chains([LongChainController, LongChainCopyController, LoopTrip], limit: limit, root: ROOT, exclude: [])

  def test_chains_with_more_of_the_apps_callbacks_than_the_limit
    found = long(5)
    assert_equal 1, found.size # the copy has the same chain: reported once
    report = found.first
    assert_equal [LongChainController, :process_action, "index", [LongChainCopyController]], [report.klass, report.chain, report.action, report.also]
    assert_equal 6, report.callbacks.size # index has all six; show four
    assert_match(%r{before_process_action :six \(test/chain_check_test.rb:\d+\)}, report.to_s)
    assert_includes report.to_s, "(inherited by 1: LongChainCopyController)"
    assert_empty long(6)
  end

  def test_callbacks_inherited_from_excluded_classes_dont_count
    classes = [BasicsController, TripsCheckController]
    assert_empty AsMinimizer::Check.long_chains(classes, limit: 5, root: ROOT, exclude: ["BasicsController"])
    found = AsMinimizer::Check.long_chains(classes, limit: 5, root: ROOT, exclude: [])
    assert_equal [[BasicsController, [TripsCheckController]]], found.map { [it.klass, it.also] } # the base, once
    assert_equal 6, found.first.callbacks.size
  end

  def test_only_the_apps_own_callbacks_count
    # LoopTrip's save chain also holds Rails' autosave/counter callbacks; only its three after_save count.
    assert_empty AsMinimizer::Check.long_chains([LoopTrip], limit: 3, root: ROOT)
    assert_equal :save, AsMinimizer::Check.long_chains([LoopTrip], limit: 2, root: ROOT).first.chain
  end

  def test_model_callbacks_that_save_the_record_again
    loops = AsMinimizer::Check.callback_loops([LoopTrip], root: ROOT)
    assert_equal [["after_save :recalculate", "update!", nil], ["after_save :touch_total", "save", "if: :saved_change_to_title?"]],
      loops.map { [it.callback, it.call, it.guard] }.sort
    recalculate, touch = loops.partition { it.call == "update!" }.map(&:first)
    assert_match(%r{LoopTrip: after_save :recalculate calls update! on the record itself \(test/chain_check_test.rb:\d+\), which runs the save callbacks again\z}, recalculate.to_s)
    assert_includes touch.to_s, "guarded by if: :saved_change_to_title?"
  end

  def test_allowed_loops
    assert_equal ["save"], AsMinimizer::Check.callback_loops([LoopTrip], root: ROOT, allow: ["LoopTrip#recalculate"]).map(&:call)
  end
end

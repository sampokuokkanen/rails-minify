# frozen_string_literal: true

require "test_helper"

class CheckBaseController < ActionController::Base
  self.abstract_class = true if respond_to?(:abstract_class=)
  abstract!
  before_action :authenticate_user! # no Devise: every subclass action raises
end

class CheckPostsController < CheckBaseController
  before_action :set_post, only: %i[show edit]
  before_action :load_draft, only: :edit # missing, only for edit
  before_action :track, if: :tracking_enabled? # condition missing
  before_action :ghost, only: :nonexistent # missing but never runs

  def show = head(:ok)
  def edit = head(:ok)

  private

  def set_post = nil
  def track = nil
end

class CheckDelegatingController < ActionController::Base
  before_action :maybe_proxied
  def index = head(:ok)

  private

  def method_missing(name, ...) = name == :maybe_proxied ? nil : super
  def respond_to_missing?(name, priv = false) = name == :maybe_proxied || super
end

ActiveRecord::Schema.define { create_table(:check_notes, force: true) { |t| t.string :title } }

class CheckNote < ActiveRecord::Base
  before_save :normalize, if: :title_changed? # attribute method: present even if not generated
  after_save :notify_followers # missing
  def normalize = nil
end

class CheckTest < Minitest::Test
  def problems = AsMinimizer::Check.callback_targets([CheckBaseController, CheckPostsController, CheckDelegatingController, CheckNote]).map(&:to_s)

  def test_reports_missing_targets_where_they_would_run
    assert_equal [
      "CheckPostsController: before_process_action filter :authenticate_user! names no method (edit, show)",
      "CheckPostsController: before_process_action filter :load_draft names no method (edit)",
      "CheckPostsController: before_process_action condition :tracking_enabled? names no method (edit, show)",
      "CheckDelegatingController: before_process_action filter :maybe_proxied may be answered by method_missing (index)",
      "CheckNote: after_save filter :notify_followers names no method",
    ].sort, problems.sort
  end

  def test_status
    assert_equal :present, AsMinimizer::Check.status(CheckNote, :title_changed?)
    assert_equal :present, AsMinimizer::Check.status(CheckNote, :saved_change_to_title?)
    assert_equal :missing, AsMinimizer::Check.status(CheckNote, :body_changed?)
    assert_equal :unknown, AsMinimizer::Check.status(CheckDelegatingController, :anything)
  end

  def test_unroller_warns_once_when_it_generates_the_chain
    AsMinimizer::Unroller.install!
    AsMinimizer::Unroller.instance_variable_set(:@warned, nil)
    warnings = []
    AsMinimizer.singleton_class.alias_method(:__original_warn, :warn)
    AsMinimizer.define_singleton_method(:warn) { |message| warnings << message }
    2.times { CheckNote.create!(title: "x") rescue NoMethodError }
    assert_equal ["activesupport-minimizer: CheckNote's after_save filter :notify_followers names no method; running the chain will raise NoMethodError"], warnings
  ensure
    AsMinimizer.singleton_class.alias_method(:warn, :__original_warn)
  end
end

class CensusTest < Minitest::Test
  def test_counts_chains_and_reasons
    klass = Class.new(ActionController::Base) do
      def self.name = "CensusOddController"
      before_action ->(c, extra) { nil } # a two-parameter before proc: ActiveSupport raises, the unroller declines
      def index = head(:ok)
    end
    result = AsMinimizer::Census.report([CheckPostsController, CheckNote, klass], routed: { "CheckPostsController" => Set["show"] })
    assert_equal 4, result.unrolled # CheckPostsController#show and CheckNote's three chains
    assert_equal({ "a before/after proc with 2 parameters" => ["CensusOddController#process_action[index]"] }, result.fallbacks)
    assert_equal 3, result.problems.size
    assert_includes result.lines.join("\n"), "callback chains: 4/5 unrolled"
  end
end

# frozen_string_literal: true

require "test_helper"

class Auditor
  def self.before(controller) = controller.log << :auditor_before
  def self.after(controller) = controller.log << :auditor_after
  def self.around(controller) = (controller.log << :auditor_in; yield; controller.log << :auditor_out)
end

class OnlyAdmin
  def self.before(controller) = controller.action_name == "admin"
end

class EverythingController < TrackingController
  prepend_before_action { log << :prepended }
  before_action :first
  before_action :maybe_halt
  before_action :only_show, only: :show
  before_action :except_show, except: [:show]
  before_action :if_sym, if: :flag?
  before_action :unless_proc, unless: -> { params[:skip] }
  before_action :proc_arity1, if: ->(c) { c.params[:one] }
  before_action Auditor
  before_action :object_condition, if: OnlyAdmin
  after_action :after_one
  after_action :after_two, only: %i[show edit]
  after_action Auditor
  around_action :wrap
  before_action :inside_around
  around_action ->(controller, block) { controller.log << :proc_in; block.call; controller.log << :proc_out }, except: :admin
  around_action Auditor, only: :edit
  around_action :maybe_no_yield
  after_action :inner_after

  private

  def first = log << :first
  def maybe_halt = (log << :maybe_halt; redirect_to("/gone") if params[:halt] == "1")
  def only_show = log << :only_show
  def except_show = log << :except_show
  def if_sym = log << :if_sym
  def flag? = params[:flag].present?
  def unless_proc = log << :unless_proc
  def proc_arity1 = log << :proc_arity1
  def object_condition = log << :object_condition
  def after_one = log << :after_one
  def after_two = log << :after_two
  def wrap = (log << :wrap_in; yield; log << :wrap_out)
  def inside_around = (log << :inside_around; render(plain: "halted inside") if params[:halt] == "2")
  def maybe_no_yield = (log << :no_yield_in; yield unless params[:noyield]; log << :no_yield_out)
  def inner_after = log << :inner_after
end

class ChildController < EverythingController
  skip_before_action :first
  skip_after_action :after_one, only: :edit
  before_action :child_only
  around_action :child_wrap, if: -> { params[:wrap] }

  private

  def child_only = log << :child_only
  def child_wrap = (log << :child_in; yield; log << :child_out)
end

class RaisingController < TrackingController
  before_action :boom, only: :admin
  after_action -> { log << :after }

  private

  def boom = raise(ArgumentError, "boom")
end

class ControllerTest < Minitest::Test
  include Compare

  PARAMS = [{}, { halt: "1" }, { halt: "2" }, { flag: "1" }, { skip: "1" }, { one: "1" }, { noyield: "1" },
            { wrap: "1" }, { flag: "1", one: "1", wrap: "1", halt: "2" }].freeze

  def test_same_behavior_as_activesupport
    assert_same_behavior(EverythingController, %i[show edit admin], PARAMS)
  end

  def test_inheritance_and_skips
    assert_same_behavior(ChildController, %i[show edit admin], PARAMS)
  end

  def test_exceptions
    assert_same_behavior(RaisingController, %i[show admin])
  end

  def test_halted_callback_instrumentation
    events = []
    subscriber = ActiveSupport::Notifications.subscribe("halted_callback.action_controller") { |*, payload| events << payload[:filter] }
    both(EverythingController, :show, halt: "1")
    assert_equal %i[maybe_halt maybe_halt], events
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber)
  end

  def test_the_matrix_exercises_things
    _, unrolled = both(EverythingController, :edit, flag: "1")
    log = unrolled.last
    assert_equal %i[prepended first maybe_halt except_show if_sym unless_proc auditor_before], log.first(7)
    assert_includes log, :auditor_in
    refute_includes log, :only_show
    assert_equal 302, both(EverythingController, :show, halt: "1").last.first
    assert_equal [:raised, ArgumentError, "boom"], both(RaisingController, :admin).last
  end

  def test_generated_code_drops_filters_for_other_actions
    source = AsMinimizer::Unroller.source_for(EverythingController, :process_action, "show")
    assert_includes source, "self.only_show"
    refute_includes source, "except_show"
    assert_includes AsMinimizer::Unroller.source_for(EverythingController, :process_action, "admin"), "self.except_show"
  end

  def test_regenerates_when_the_chain_changes
    klass = Class.new(TrackingController) do
      def self.name = "LateController"
      before_action -> { log << :one }
    end
    klass.call_action(:show)
    klass.before_action -> { log << :two }
    assert_equal %i[one two show], klass.call_action(:show).last
  end

  def test_raise_on_missing_callback_actions_checks_at_runtime
    # A global setting, on in development and test by default since Rails 7.1.
    ActionController::Base.raise_on_missing_callback_actions = true
    klass = Class.new(TrackingController) do
      def self.name = "StrictController"
      before_action -> { log << :one }, only: :show
      before_action -> { log << :typo }, only: :shwo
    end
    stock, unrolled = stock_and_unrolled { klass.call_action(:show) }
    assert_equal stock, unrolled
    assert_equal AbstractController::ActionNotFound, unrolled[1]
    assert AsMinimizer::Unroller.method_for(klass.new.tap { it.action_name = "show" }, :process_action)
  ensure
    ActionController::Base.raise_on_missing_callback_actions = false
  end
end

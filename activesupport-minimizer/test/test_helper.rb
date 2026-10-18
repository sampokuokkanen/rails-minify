# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)

require "minitest/autorun"
require "action_controller"
require "active_record"
require "as_minimizer"

ActiveRecord::Base.establish_connection(adapter: "sqlite3", database: ":memory:")
ActiveRecord::Migration.verbose = false

AsMinimizer::Unroller.install!

# Logs every callback, so runs with and without unrolling can be compared.
class TrackingController < ActionController::Base
  attr_reader :log

  # Anything raised in a callback should reach the test.
  def self.call_action(name, params = {})
    env = Rack::MockRequest.env_for("/#{name}?#{Rack::Utils.build_query(params)}")
    status, headers, body = action(name).call(env)
    text = +""
    body.each { text << it }
    body.close if body.respond_to?(:close)
    [status, headers["location"], text, env["tracking.log"]]
  end

  def process_action(...)
    @log = request.env["tracking.log"] = []
    super
  end

  def show = (log << :show; render plain: "show")
  def edit = (log << :edit; render plain: "edit")
  def admin = (log << :admin; render plain: "admin")
end

module Compare
  # [status, location, body, callback log] with and without unrolling.
  def both(controller, action, params = {})
    stock_and_unrolled { controller.call_action(action, params) }
  end

  def stock_and_unrolled(&block)
    AsMinimizer::Unroller.disable!
    stock = outcome(&block)
    AsMinimizer::Unroller.install!
    unrolled = outcome(&block)
    [stock, unrolled]
  end

  def outcome
    yield
  rescue StandardError => e
    [:raised, e.class, e.message]
  end

  def assert_same_behavior(controller, actions, params_list = [{}])
    actions.each do |action|
      params_list.each do |params|
        stock, unrolled = both(controller, action, params)
        assert_equal stock, unrolled, "#{controller}##{action} #{params.inspect}"
      end
    end
  end
end

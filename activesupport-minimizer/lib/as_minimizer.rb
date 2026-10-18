# frozen_string_literal: true

require "active_support"
require "active_support/callbacks"
require "as_minimizer/version"

module AsMinimizer
  autoload :Unroller, "as_minimizer/unroller"
  autoload :Check, "as_minimizer/check"
  autoload :Census, "as_minimizer/census"

  def self.warn(message)
    logger = defined?(Rails) && Rails.respond_to?(:logger) && Rails.logger
    logger ? logger.warn(message) : Kernel.warn(message)
  end
end

require "as_minimizer/railtie" if defined?(Rails::Railtie)

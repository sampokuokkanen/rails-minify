# frozen_string_literal: true

require "lint_roller"

module RuboCop
  module Minify
    # `plugins: [rubocop-minify]` in .rubocop.yml.
    class Plugin < LintRoller::Plugin
      def about
        LintRoller::About.new(name: "rubocop-minify", version: RubocopMinify::VERSION,
          homepage: "https://github.com/sampokuokkanen/rails-minify",
          description: "Rewrites code relying on what rails-minify removes from Rails")
      end

      def supported?(context) = context.engine == :rubocop

      def rules(_context)
        LintRoller::Rules.new(type: :path, config_format: :rubocop, value: Pathname.new(__dir__).join("../../../config/default.yml"))
      end
    end
  end
end

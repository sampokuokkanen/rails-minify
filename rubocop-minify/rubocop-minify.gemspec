# frozen_string_literal: true

require_relative "lib/rubocop_minify/version"

Gem::Specification.new do |spec|
  spec.name = "rubocop-minify"
  spec.version = RubocopMinify::VERSION
  spec.authors = ["Sampo Kuokkanen"]
  spec.summary = "RuboCop cops (and an ERB fixer) that rewrite code relying on what rails-minify removes from Rails"
  spec.license = "MIT"
  spec.description = "RuboCop cop and ERB fixer that rewrite calls to the attribute methods activerecord-minimizer's strict mode removes (name?, name_changed?, ...) into the calls they stood for, from the app's manifest."
  spec.homepage = "https://github.com/sampokuokkanen/rails-minify/tree/main/rubocop-minify"
  spec.metadata = {
    "source_code_uri" => "https://github.com/sampokuokkanen/rails-minify/tree/main/rubocop-minify",
    "changelog_uri" => "https://github.com/sampokuokkanen/rails-minify/blob/main/rubocop-minify/CHANGELOG.md",
    "bug_tracker_uri" => "https://github.com/sampokuokkanen/rails-minify/issues",
    "rubygems_mfa_required" => "true",
    "default_lint_roller_plugin" => "RuboCop::Minify::Plugin",
  }
  spec.required_ruby_version = ">= 3.4"
  spec.files = Dir["lib/**/*.rb", "config/*.yml", "exe/*", "README.md", "CHANGELOG.md", "LICENSE.txt"]
  spec.bindir = "exe"
  spec.executables = ["minify-erb"]

  spec.add_dependency "activerecord-minimizer", "~> 0.1"
  spec.add_dependency "herb", ">= 0.10"
  spec.add_dependency "lint_roller", "~> 1.1"
  spec.add_dependency "prism", ">= 1.4"
  spec.add_dependency "rubocop", ">= 1.72"
end

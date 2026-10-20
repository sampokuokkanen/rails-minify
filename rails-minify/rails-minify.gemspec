# frozen_string_literal: true

require_relative "lib/rails_minify/version"

Gem::Specification.new do |spec|
  spec.name = "rails-minify"
  spec.version = RailsMinify::VERSION
  spec.authors = ["Sampo Kuokkanen"]
  spec.summary = "Strict Active Record attribute methods, ZJIT after boot, and checks for callback problems"
  spec.license = "MIT"
  spec.description = "One switch for what held up in production: Active Record strict mode (only readers and writers per column), enum methods without closures and ZJIT turned on after boot. minify:check finds callback problems. Experimental: patches for parts of Rails and common gems that redo work on every request, and the other minimizer parts."
  spec.homepage = "https://github.com/sampokuokkanen/rails-minify/tree/main/rails-minify"
  spec.metadata = {
    "source_code_uri" => "https://github.com/sampokuokkanen/rails-minify/tree/main/rails-minify",
    "changelog_uri" => "https://github.com/sampokuokkanen/rails-minify/blob/main/rails-minify/CHANGELOG.md",
    "bug_tracker_uri" => "https://github.com/sampokuokkanen/rails-minify/issues",
    "rubygems_mfa_required" => "true",
  }
  spec.required_ruby_version = ">= 3.4"
  spec.files = Dir["lib/**/*.rb", "README.md", "CHANGELOG.md", "LICENSE.txt"]

  spec.add_dependency "activerecord-minimizer", "~> 0.2"
  spec.add_dependency "activesupport-minimizer", "~> 0.2"
end

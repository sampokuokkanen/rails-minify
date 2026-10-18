# frozen_string_literal: true

require_relative "lib/rails_minify/version"

Gem::Specification.new do |spec|
  spec.name = "rails-minify"
  spec.version = RailsMinify::VERSION
  spec.authors = ["Sampo Kuokkanen"]
  spec.summary = "Precompile what Rails works out at runtime: attribute methods, callback chains"
  spec.license = "MIT"
  spec.description = "Turns on activerecord-, activesupport- and actionpack-minimizer, and patches parts of Rails and common gems that redo work on every request (Action Text plain text, Request#host, OmniAuth strategies)."
  spec.homepage = "https://github.com/sampokuokkanen/rails-minify/tree/main/rails-minify"
  spec.metadata = {
    "source_code_uri" => "https://github.com/sampokuokkanen/rails-minify/tree/main/rails-minify",
    "changelog_uri" => "https://github.com/sampokuokkanen/rails-minify/blob/main/rails-minify/CHANGELOG.md",
    "bug_tracker_uri" => "https://github.com/sampokuokkanen/rails-minify/issues",
    "rubygems_mfa_required" => "true",
  }
  spec.required_ruby_version = ">= 3.4"
  spec.files = Dir["lib/**/*.rb", "README.md", "CHANGELOG.md", "LICENSE.txt"]

  spec.add_dependency "activerecord-minimizer", "~> 0.1"
  spec.add_dependency "actionpack-minimizer", "~> 0.1"
  spec.add_dependency "activesupport-minimizer", "~> 0.1", ">= 0.1.1"
end

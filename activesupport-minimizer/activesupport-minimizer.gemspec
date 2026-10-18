# frozen_string_literal: true

require_relative "lib/as_minimizer/version"

Gem::Specification.new do |spec|
  spec.name = "activesupport-minimizer"
  spec.version = AsMinimizer::VERSION
  spec.authors = ["Sampo Kuokkanen"]
  spec.summary = "Run ActiveSupport callback chains (controllers, models, validations, jobs) as generated methods"
  spec.license = "MIT"
  spec.description = "Runs ActiveSupport::Callbacks chains (controller filters, model and validation callbacks, Active Job callbacks) as one generated method per chain instead of the filter and lambda objects Rails walks on every run."
  spec.homepage = "https://github.com/sampokuokkanen/rails-minify/tree/main/activesupport-minimizer"
  spec.metadata = {
    "source_code_uri" => "https://github.com/sampokuokkanen/rails-minify/tree/main/activesupport-minimizer",
    "changelog_uri" => "https://github.com/sampokuokkanen/rails-minify/blob/main/activesupport-minimizer/CHANGELOG.md",
    "bug_tracker_uri" => "https://github.com/sampokuokkanen/rails-minify/issues",
    "rubygems_mfa_required" => "true",
  }
  spec.required_ruby_version = ">= 3.4"
  spec.files = Dir["lib/**/*.rb", "README.md", "CHANGELOG.md", "LICENSE.txt"]

  spec.add_dependency "activesupport", ">= 8.0", "< 8.3"
end

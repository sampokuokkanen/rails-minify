# frozen_string_literal: true

require_relative "lib/ap_minimizer/version"

Gem::Specification.new do |spec|
  spec.name = "actionpack-minimizer"
  spec.version = ApMinimizer::VERSION
  spec.authors = ["Sampo Kuokkanen"]
  spec.summary = "Precompile named route helpers and template rendering"
  spec.license = "MIT"
  spec.description = "Turns named route helpers into string interpolation over cached URL parts, and compiles render and link_to calls in templates to direct calls without their option-hash machinery."
  spec.homepage = "https://github.com/sampokuokkanen/rails-minify/tree/main/actionpack-minimizer"
  spec.metadata = {
    "source_code_uri" => "https://github.com/sampokuokkanen/rails-minify/tree/main/actionpack-minimizer",
    "changelog_uri" => "https://github.com/sampokuokkanen/rails-minify/blob/main/actionpack-minimizer/CHANGELOG.md",
    "bug_tracker_uri" => "https://github.com/sampokuokkanen/rails-minify/issues",
    "rubygems_mfa_required" => "true",
  }
  spec.required_ruby_version = ">= 3.4"
  spec.files = Dir["lib/**/*.rb", "README.md", "CHANGELOG.md", "LICENSE.txt"]

  spec.add_dependency "actionpack", ">= 8.0", "< 8.3"
end

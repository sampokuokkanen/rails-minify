# frozen_string_literal: true

require_relative "lib/ar_minimizer/version"

Gem::Specification.new do |spec|
  spec.name = "activerecord-minimizer"
  spec.version = ArMinimizer::VERSION
  spec.authors = ["Sampo Kuokkanen"]
  spec.summary = "Stop generating ~20 attribute methods per column; compile the call sites instead"
  spec.description = <<~DESC
    ActiveRecord generates a reader, a writer and about twenty helper methods
    (name?, name_changed?, saved_change_to_name?, name_before_type_cast, ...)
    for every column of every model. activerecord-minimizer generates only the
    readers and writers, and at deploy time rewrites static call sites of the
    rest into the proxy ActiveRecord would call anyway (name? -> attribute?("name")).
    Calls it can't see (send, views, callback symbols) keep working through
    ActiveModel's method_missing.
  DESC
  spec.license = "MIT"
  spec.description = "Generates only the reader and writer per Active Record column (strict mode removes the other 19 attribute methods), compiles call sites to the calls those methods stood for, turns enum closures into plain methods and stops records allocating Hashes they never fill."
  spec.homepage = "https://github.com/sampokuokkanen/rails-minify/tree/main/activerecord-minimizer"
  spec.metadata = {
    "source_code_uri" => "https://github.com/sampokuokkanen/rails-minify/tree/main/activerecord-minimizer",
    "changelog_uri" => "https://github.com/sampokuokkanen/rails-minify/blob/main/activerecord-minimizer/CHANGELOG.md",
    "bug_tracker_uri" => "https://github.com/sampokuokkanen/rails-minify/issues",
    "rubygems_mfa_required" => "true",
  }
  spec.required_ruby_version = ">= 3.4"
  spec.files = Dir["lib/**/*.rb", "README.md", "CHANGELOG.md", "LICENSE.txt"]

  spec.add_dependency "activerecord", ">= 8.0", "< 8.3"
  spec.add_dependency "prism", ">= 1.2"
  spec.add_dependency "require-hooks", ">= 0.4" # Loader only
end

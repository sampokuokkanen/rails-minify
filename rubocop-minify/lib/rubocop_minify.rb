# frozen_string_literal: true

require "rubocop_minify/version"
require "rubocop_minify/rewrite"
require "rubocop_minify/definitions"

module RubocopMinify
  autoload :ERB, "rubocop_minify/erb"

  # One Rewrite per app root and settings: reading the manifest and scanning
  # the app for definitions happens once per process.
  def self.rewrite_for(root, manifest:, definition_paths:, views: false)
    @rewrites ||= {}
    @rewrites[[root, manifest, definition_paths, views]] ||= begin
      path = File.expand_path(manifest, root)
      if File.exist?(path)
        require "ar_minimizer"
        Rewrite.new(ArMinimizer::Manifest.load(path), defined: definitions(root, definition_paths), views: views)
      end
    end
  end

  def self.definitions(root, paths)
    @definitions ||= {}
    @definitions[[root, paths]] ||= Definitions.scan(root, paths)
  end
end

# frozen_string_literal: true

require "rubocop_minify/version"
require "rubocop_minify/rewrite"
require "rubocop_minify/definitions"

module RubocopMinify
  autoload :ERB, "rubocop_minify/erb"

  # One Rewrite per app root and settings: reading the manifest and scanning
  # the app for definitions happens once per process.
  def self.rewrite_for(root, manifest:, definition_paths:, views: false, keep_list: "config/ar_minimizer_keep.txt")
    @rewrites ||= {}
    @rewrites[[root, manifest, definition_paths, views, keep_list]] ||= begin
      path = File.expand_path(manifest, root)
      if File.exist?(path)
        require "ar_minimizer"
        index = ArMinimizer::Manifest.load(path)
        Rewrite.new(index, defined: definitions(root, definition_paths), views: views,
          kept: kept_names(index, File.expand_path(keep_list, root)))
      end
    end
  end

  # Names strict mode still generates on every model that has them, from
  # activerecord-minimizer's keep list: a bare "name" keeps it everywhere,
  # "Model#name" only there (the name counts once every model with that
  # attribute is listed). Calls of those names are left alone.
  def self.kept_names(index, path)
    return Set.new unless File.exist?(path)

    bare, scoped = ArMinimizer::Slim.parse_keep_file(File.read(path)).partition { !it.include?("#") }
    kept = Set.new(bare)
    scoped.map { it.split("#", 2) }.group_by(&:last).each do |name, pairs|
      entry = index[name]
      kept << name if entry && (entry.classes - pairs.map(&:first)).empty?
    end
    kept
  end

  def self.definitions(root, paths)
    @definitions ||= {}
    @definitions[[root, paths]] ||= Definitions.scan(root, paths)
  end
end

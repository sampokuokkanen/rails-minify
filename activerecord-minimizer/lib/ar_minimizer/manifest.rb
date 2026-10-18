# frozen_string_literal: true

require "json"
require "digest"

module ArMinimizer
  # The Index as a file, so source can be compiled where no model is loaded
  # yet (Loader, while Ruby requires each file) or no database is around.
  # It stores what the index is computed from (each model's columns, patterns
  # and hand-written methods), one model per line. Generate it like
  # db/schema.rb and commit it:
  #
  #   bin/rails ar_minimizer:manifest        # writes config/ar_minimizer.json
  #   bin/rails ar_minimizer:manifest:check  # in CI: fails when out of date
  #
  # It goes stale when the schema changes, or when a model gets a hand-written
  # method with a generated method's name, or overrides a reader.
  module Manifest
    FORMAT = 1

    class << self
      def dump(index) = dump_models(index.models, keep: index.keep)

      # From Index.describe_all, without building the index (the boot-time check).
      def dump_models(models, keep:)
        pattern_sets = models.map(&:patterns).uniq.sort
        lines = models.map do |m|
          JSON.generate({ "name" => m.name, "patterns" => pattern_sets.index(m.patterns), "primary_key" => m.primary_key,
                          # sorted: column order differs between a migrated database and one loaded from schema.rb
                          "attributes" => m.attributes.sort.to_h, "hand_written" => m.hand_written,
                          "superclass" => m.superclass, "modules" => m.modules,
                          "associations" => m.associations, "scopes" => m.scopes, **({ "shadows" => m.shadows } if m.shadows.any?) })
        end.sort
        <<~JSON
          {"format": #{FORMAT}, "ar_minimizer": #{VERSION.to_json}, "keep": #{keep.map(&:to_s).sort.to_json},
          "patterns": #{JSON.generate(pattern_sets)},
          "models": [
          #{lines.join(",\n")}
          ]}
        JSON
      end

      def parse(json)
        data = JSON.parse(json)
        raise ArgumentError, "ar_minimizer manifest format #{data["format"]}, expected #{FORMAT}" unless data["format"] == FORMAT

        models = data["models"].map do |m|
          Index::Model.new(name: m["name"], attributes: m["attributes"].transform_values { it&.to_sym }, primary_key: m["primary_key"],
            patterns: data["patterns"].fetch(m["patterns"]), hand_written: m["hand_written"],
            superclass: m["superclass"], modules: m["modules"] || [],
            associations: m["associations"] || {}, scopes: m["scopes"] || [], shadows: m["shadows"] || [])
        end
        Index.new(models, keep: data["keep"])
      end

      def load(path) = parse(File.read(path))

      # Changes whenever the compiled output could: the models and this gem's
      # version (both in the dump). Of a dump or a manifest file's contents.
      def digest(index_or_json)
        Digest::SHA256.hexdigest(index_or_json.is_a?(String) ? index_or_json : dump(index_or_json))[0, 16]
      end
    end
  end
end

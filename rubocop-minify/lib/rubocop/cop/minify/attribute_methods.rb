# frozen_string_literal: true

module RuboCop
  module Cop
    module Minify
      # Calls to the attribute methods activerecord-minimizer's strict mode
      # removes, rewritten into what they stood for. See RubocopMinify::Rewrite.
      #
      # @example
      #   # bad
      #   venue.featured?
      #   venue.name_changed?
      #   before_save :geocode, if: :address_changed?
      #
      #   # good
      #   venue.featured.present?
      #   venue.attribute_changed?(:name)
      #   before_save :geocode, if: -> { attribute_changed?(:address) }
      class AttributeMethods < Base
        extend AutoCorrector

        def on_new_investigation
          rewrite = RubocopMinify.rewrite_for(config.base_dir_for_path_parameters,
            manifest: cop_config.fetch("Manifest", "config/ar_minimizer.json"),
            definition_paths: Array(cop_config.fetch("DefinitionPaths", ["app/**/*.rb", "lib/**/*.rb"])),
            keep_list: cop_config.fetch("KeepList", "config/ar_minimizer_keep.txt"))
          return unless rewrite

          source = processed_source.raw_source
          rewrite.edits(source).each do |edit|
            range = range_between(source.byteslice(0, edit.from).length, source.byteslice(0, edit.to).length)
            if edit.replacement
              add_offense(range, message: edit.message) { it.replace(range, edit.replacement) }
            else
              add_offense(range, message: edit.message)
            end
          end
        end

        private

        def range_between(from, to) = Parser::Source::Range.new(processed_source.buffer, from, to)
      end
    end
  end
end

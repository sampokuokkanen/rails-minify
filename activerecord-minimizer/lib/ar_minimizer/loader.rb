# frozen_string_literal: true

module ArMinimizer
  # Compiles each matching file as Ruby loads it, instead of Build rewriting
  # files in place, the way ruby-next's runtime mode works: through
  # require-hooks, which also makes bootsnap cache the compiled result. The
  # bootsnap cache key includes the manifest digest, so a new manifest
  # recompiles everything.
  #
  #   config.ar_minimizer.load_time = true   # needs config/ar_minimizer.json
  module Loader
    class << self
      # index: an Index, or something that returns one when called: with a
      # warm bootsnap cache nothing gets compiled and the index is never needed.
      # version: changes when the index does (Manifest.digest of the file).
      def install!(index:, patterns:, exclude_patterns: nil, version: nil, guards: false)
        require "require-hooks/setup"
        @index = index
        @guards = guards
        @mutex = Mutex.new
        if defined?(RequireHooks::Bootsnap) && RequireHooks::Bootsnap.respond_to?(:add_version_hash)
          RequireHooks::Bootsnap.add_version_hash("ar_minimizer-#{version || Manifest.digest(self.index)}-guards-#{guards}")
        end
        RequireHooks.source_transform(patterns: patterns, exclude_patterns: exclude_patterns) do |path, source|
          Loader.transform(path, source)
        end
      end

      def index
        return @index unless @index.respond_to?(:call)

        @mutex.synchronize { @index = @index.call if @index.respond_to?(:call) }
        @index
      end

      # nil leaves the file as it is.
      def transform(path, source)
        result = Rewriter.new(index: index, path: path, marker: false, guards: @guards).rewrite(source || File.read(path))
        result.source if result.sites.positive?
      end
    end
  end
end

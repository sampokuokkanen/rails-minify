# frozen_string_literal: true

module ArMinimizer
  # Rewrites application files in place. Run once per release on the
  # production host (or image build), after the app has booted with every model
  # loaded and the schema in place. Never commit the output.
  class Build
    NotProduction = Class.new(StandardError)
    Report = Data.define(:files_changed, :sites, :skipped)

    def initialize(root:, index: Index.from_models, paths: %w[app lib], env: ENV["RAILS_ENV"] || ENV["RACK_ENV"],
      dry_run: false, force: false, out: nil, guards: false)
      @root = root.to_s
      @index = index
      @paths = paths
      @env = env
      @dry_run = dry_run
      @force = force
      @out = out
      @guards = guards
    end

    def run
      unless @force || @env == "production"
        raise NotProduction, "ar_minimizer rewrites source in place; run it with RAILS_ENV=production, " \
          "or override with FORCE=1 (rake) or force: true (Ruby)"
      end

      files_changed = sites = 0
      skipped = []
      files.each do |file|
        relative = file.delete_prefix("#{@root}/")
        result = Rewriter.new(index: @index, path: relative, guards: @guards).rewrite(File.read(file))
        skipped.concat(result.skipped)
        result.skipped.each { @out&.puts "ar_minimizer: skipped #{it}" }
        next if result.sites.zero?

        files_changed += 1
        sites += result.sites
        @out&.puts "ar_minimizer: #{relative} (#{result.sites} calls)"
        File.write(file, result.source) unless @dry_run
      end
      @out&.puts "ar_minimizer: #{sites} calls in #{files_changed} files, " \
        "#{@index.size} compilable method names#{" (dry run)" if @dry_run}"
      Report.new(files_changed, sites, skipped)
    end

    private

    def files
      @paths.flat_map { Dir.glob(File.join(@root, it, "**", "*.rb")) }.sort
    end
  end
end

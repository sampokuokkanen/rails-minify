# frozen_string_literal: true

module ArMinimizer
  # What the attribute-method and enum compilers cover in an app.
  module Census
    Result = Data.define(:models, :columns, :stock_methods, :generated_methods, :enum_methods, :enum_compiled,
      :sites, :files, :manifest) do
      def lines(verbose: false)
        [
          "models: #{models}, #{columns} columns",
          "attribute methods: #{stock_methods} in stock Rails, #{generated_methods || "n/a (slim off)"} generated with slim",
          "enum methods: #{enum_compiled}/#{enum_methods} compiled",
          "attribute call sites: #{sites} compilable in #{files} files under app/ and lib/",
          "manifest: #{manifest}",
        ]
      end
    end

    def self.report(root:, models: ActiveRecord::Base.descendants, guards: false)
      models = models.reject { it.abstract_class? || !Index.table?(it) }
      index = Index.new(models.map { Index.describe(it) }, keep: Slim.keep || Slim::DEFAULT_KEEP)
      stock = models.sum { it.attribute_method_patterns.count * (it.attribute_names.size + it.attribute_aliases.size) }
      generated = if Slim.enabled?
        models.each(&:define_attribute_methods)
        models.sum { it.send(:generated_attribute_methods).instance_methods(false).size }
      end
      enum_methods = enum_compiled = 0
      models.each do |model|
        mod = model.instance_variable_get(:@_enum_methods_module) or next
        mod.instance_methods(false).each do |name|
          enum_methods += 1
          enum_compiled += 1 if mod.instance_method(name).source_location&.first.to_s.start_with?("enum ")
        end
      end
      sites = files = 0
      Dir.glob(File.join(root.to_s, "{app,lib}", "**", "*.rb")).each do |file|
        n = Rewriter.new(index: index, path: file, guards: guards).rewrite(File.read(file)).sites
        sites += n
        files += 1 if n.positive?
      end
      Result.new(models.size, models.sum { it.attribute_names.size }, stock, generated, enum_methods, enum_compiled,
        sites, files, manifest_state(root, index))
    end

    def self.manifest_state(root, index)
      path = File.join(root.to_s, "config/ar_minimizer.json")
      return "none (config/ar_minimizer.json; needed for load-time compilation)" unless File.exist?(path)

      File.read(path) == Manifest.dump(index) ? "up to date" : "out of date: run bin/rails ar_minimizer:manifest"
    end
  end
end

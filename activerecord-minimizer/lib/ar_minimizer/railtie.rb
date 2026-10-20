# frozen_string_literal: true

module ArMinimizer
  class Railtie < Rails::Railtie
    config.ar_minimizer = ActiveSupport::OrderedOptions.new

    # In config/environments/production.rb:
    #
    #   config.ar_minimizer.slim = true       # generate only readers and writers
    #   config.ar_minimizer.strict = false    # ... and generate the rest when first called, instead of removing them
    #   config.ar_minimizer.load_time = true  # compile app/ and lib/ as they load (needs the manifest)
    #   config.ar_minimizer.views = true      # compile templates as ActionView loads them
    #   config.ar_minimizer.enums = true      # enum predicates/bang methods as plain methods
    #   config.ar_minimizer.small_records = true  # no Hashes for records that never fill them
    #   config.ar_minimizer.guards = true     # also compile calls on receivers of unknown class, behind a class check
    #
    # config/ar_minimizer.json is the manifest (ar_minimizer:manifest). With it,
    # load_time and views need no database or loaded models; without it, views
    # index the models loaded when each template compiles.
    #
    # config/ar_minimizer_keep.txt, if present, lists methods to generate at
    # boot (one "name" or "Model#name" per line; see ar_minimizer:profile).
    initializer "ar_minimizer", before: :load_config_initializers do |app|
      options = app.config.ar_minimizer
      keep_file = app.root.join("config/ar_minimizer_keep.txt")
      keep_methods = keep_file.exist? ? ArMinimizer::Slim.parse_keep_file(keep_file.read) : []
      manifest_file = app.root.join("config/ar_minimizer.json")
      # Read now (a few KB), indexed only when something has to be compiled.
      manifest_json = manifest_file.read if manifest_file.exist? && (options.load_time || options.views)
      manifest = -> { ArMinimizer::Manifest.parse(manifest_json) } if manifest_json

      ActiveSupport.on_load(:active_record) do
        ArMinimizer::Enums.install! if options.enums
        ArMinimizer::SmallRecords.install! if options.small_records
        ArMinimizer::Slim.enable!(keep_methods: keep_methods, strict: options.strict != false) if options.slim
        ArMinimizer::Profile.start!(ENV["AR_MINIMIZER_PROFILE"]) if ENV["AR_MINIMIZER_PROFILE"]
      end
      ActiveSupport.on_load(:action_view) { ArMinimizer::Views.install!(index: manifest, guards: !!options.guards) } if options.views

      if options.load_time
        raise "config.ar_minimizer.load_time needs #{manifest_file}: run bin/rails ar_minimizer:manifest" unless manifest

        roots = [app.root.join("app"), app.root.join("lib")].map { File.realpath(it) if it.exist? }.compact
        # File.fnmatch? without FNM_PATHNAME: `*` crosses directories.
        ArMinimizer::Loader.install!(index: manifest, patterns: roots.map { "#{it}/*.rb" }, guards: !!options.guards,
          version: ArMinimizer::Manifest.digest(manifest_json))
        app.config.after_initialize { ArMinimizer::Loader.release_index! if app.config.eager_load }
      end

      # Every model is loaded after eager loading: say so if the manifest no
      # longer describes them (the compiled code may skip a new hand-written method).
      if manifest && options.verify_manifest != false
        app.config.after_initialize do
          next unless app.config.eager_load

          live = ArMinimizer::Manifest.dump_models(ArMinimizer::Index.describe_all, keep: ArMinimizer::Slim.keep || ArMinimizer::Slim::DEFAULT_KEEP)
          if live != manifest_json
            Rails.logger.error("ar_minimizer: #{manifest_file} is out of date; run bin/rails ar_minimizer:manifest")
          end
        end
      end
    end

    rake_tasks do
      namespace :ar_minimizer do
        desc "Compile attribute pattern calls (name?, name_changed?, ...) in place " \
          "(production only unless FORCE=1; DRY_RUN=1 to preview; AR_MINIMIZER_PATHS=app,lib)"
        task build: :environment do
          Rails.application.eager_load!
          ArMinimizer::Build.new(
            root: Rails.root,
            paths: ENV.fetch("AR_MINIMIZER_PATHS", "app,lib").split(","),
            env: Rails.env,
            dry_run: ENV["DRY_RUN"] == "1",
            force: ENV["FORCE"] == "1",
            out: $stdout,
            guards: ENV["GUARDS"] == "1" || !!Rails.application.config.ar_minimizer.guards,
          ).run
        end

        desc "Write config/ar_minimizer.json from the loaded models (commit it, like db/schema.rb)"
        task manifest: :environment do
          Rails.application.eager_load!
          path = Rails.root.join("config/ar_minimizer.json")
          index = ArMinimizer::Index.from_models
          # Models whose tables can't be read are left out: with none readable
          # (no database set up yet), the manifest would describe no models.
          if ActiveRecord::Base.descendants.any? { !it.abstract_class? } &&
              ActiveRecord::Base.descendants.none? { !it.abstract_class? && ArMinimizer::Index.table?(it) }
            abort "ar_minimizer: no model's table exists in the #{Rails.env} database; set it up (bin/rails db:prepare) first"
          end
          File.write(path, ArMinimizer::Manifest.dump(index))
          puts "ar_minimizer: #{path.relative_path_from(Rails.root)} (#{index.size} methods, #{ArMinimizer::Manifest.digest(index)})"
        end

        namespace :manifest do
          desc "Fail if config/ar_minimizer.json doesn't match the models (for CI)"
          task check: :environment do
            Rails.application.eager_load!
            path = Rails.root.join("config/ar_minimizer.json")
            live = ArMinimizer::Manifest.dump(ArMinimizer::Index.from_models)
            abort "ar_minimizer: #{path} is missing or out of date; run bin/rails ar_minimizer:manifest" unless path.exist? && path.read == live
            puts "ar_minimizer: manifest up to date"
          end
        end

        desc "Print slow-path calls recorded with AR_MINIMIZER_PROFILE=dir, as a keep list " \
          "(DIR=tmp/ar_minimizer, MIN=1)"
        task :profile do
          min = Integer(ENV.fetch("MIN", "1"))
          ArMinimizer::Profile.report(ENV.fetch("DIR", "tmp/ar_minimizer")).each do |name, n|
            puts "#{name} # #{n} calls" if n >= min
          end
        end
      end
    end
  end
end

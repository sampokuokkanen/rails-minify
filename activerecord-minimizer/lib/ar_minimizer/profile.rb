# frozen_string_literal: true

module ArMinimizer
  # Counts calls that take Slim's slow path (method_missing), per
  # Model#method, and writes them out at exit, one file per process. With
  # lazy generation (the default) that is one call per method and model: the
  # list of methods generated at runtime. Put it in Slim.keep_methods to
  # generate them at boot instead, before a forking server forks, so the
  # workers share them.
  #
  #   AR_MINIMIZER_PROFILE=tmp/ar_minimizer bin/rails test
  #   bin/rails ar_minimizer:profile MIN=100 > config/ar_minimizer_keep.txt
  module Profile
    class << self
      attr_reader :tally

      def start!(dir)
        @dir = dir.to_s
        @tally = Hash.new(0)
        @mutex = Mutex.new
        # Counter must sit in front of Slim::Record (inert while Slim is off),
        # which resolves aliases without calling super.
        ActiveRecord::Base.prepend(Slim::Record) unless ActiveRecord::Base < Slim::Record
        ActiveRecord::Base.prepend(Counter) unless ActiveRecord::Base < Counter
        at_exit { write }
      end

      def stop!
        write
        @tally = nil
      end

      def count(model, name)
        @mutex.synchronize { @tally["#{model.name}##{name}"] += 1 } if @tally
      end

      def write
        return if @tally.nil? || @tally.empty?

        FileUtils.mkdir_p(@dir)
        File.write(File.join(@dir, "#{Process.pid}.tsv"), @tally.map { |name, n| "#{n}\t#{name}\n" }.join)
      end

      # Merged counts from every file in +dir+, most called first.
      def report(dir)
        Dir.glob(File.join(dir.to_s, "*.tsv")).each_with_object(Hash.new(0)) do |file, sum|
          File.foreach(file) do |line|
            n, name = line.chomp.split("\t", 2)
            sum[name] += Integer(n)
          end
        end.sort_by { |name, n| [-n, name] }
      end
    end

    module Counter
      def attribute_missing(match, ...)
        Profile.count(self.class, match.proxy_target.sub("attribute", match.attr_name))
        super
      end
    end
  end
end

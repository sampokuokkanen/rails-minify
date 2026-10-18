# frozen_string_literal: true

module ArMinimizer
  # Compiles attribute pattern calls in templates (ERB, or any other handler)
  # the way Build does for app/ and lib/, when ActionView compiles each
  # template, so views need no build step. The index covers the models loaded
  # when a template compiles and is rebuilt when more get loaded; templates
  # compiled before a model loaded leave its calls on the slow path.
  module Views
    class << self
      def install!(index: nil, guards: false)
        @guards = guards
        @fixed_index = index
        @index = nil
        @mutex = Mutex.new
        ActionView::Template.prepend(Template) unless ActionView::Template < Template
      end

      # index: an Index, something that returns one when called (loaded on
      # the first template compile), or nil to index the loaded models.
      def index
        if @fixed_index.respond_to?(:call)
          @mutex.synchronize { @fixed_index = @fixed_index.call if @fixed_index.respond_to?(:call) }
        end
        return @fixed_index if @fixed_index

        @mutex.synchronize do
          models = ActiveRecord::Base.descendants.size
          @index = nil unless @models == models
          @models = models
          @index ||= Index.from_models
        end
      end

      def rewrite(source, path)
        Rewriter.new(index: index, path: path, marker: false, guards: @guards).rewrite(source).source
      end
    end

    module Template
      private

      # The whole `def _app_views_...(local_assigns, output_buffer) ... end`,
      # so template locals parse as locals.
      def compiled_source
        Views.rewrite(super, short_identifier)
      end
    end
  end
end

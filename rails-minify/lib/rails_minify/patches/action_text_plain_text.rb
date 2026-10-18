# frozen_string_literal: true

module RailsMinify
  module Patches
    # ActionText::Content#to_plain_text walks the whole HTML tree with
    # Nokogiri on every call, and looks up the record behind every attachment:
    # in golf-buddy, 13% of all allocations on its pages came from it
    # (excerpts, meta descriptions, cards). The text is computed once per
    # distinct HTML and kept, up to MAX_BYTES of HTML.
    #
    # Without attachments the text depends on the HTML alone. An attachment
    # adds its record's text: for Active Storage blobs "[caption]" (from the
    # HTML) or, without a caption, "[filename]". So content whose attachments
    # are all blobs, remote images or inline content is cached too, with the
    # filenames it used: a hit with caption-less blobs checks them in one
    # query (renamed or deleted: computed again). Attachments of other
    # records (an app's own attachables, whose text can be anything) aren't
    # cached.
    module ActionTextPlainText
      MAX_BYTES = 8 * 1024 * 1024
      ATTACHMENT = /<action-text-attachment|data-trix-attachment/

      @cache = {}   # [html, canonicalize] => text, or [text, { blob id => filename }] with attachments
      @bytes = 0
      @mutex = Mutex.new

      class << self
        def install!
          ActionText::Content.prepend(Content) unless ActionText::Content < Content
        end

        def fetch(key)
          @cache.fetch(key) { store(key, yield.freeze) }
        end

        # The text, from the cache when the blobs it named are unchanged.
        def fetch_with_attachments(key, content)
          if (entry = @cache[key]) && filenames_unchanged?(entry[1])
            return entry[0]
          end

          text = yield.freeze
          filenames = blob_filenames(content)
          store(key, [text, filenames]) if filenames
          text
        end

        def clear! = @mutex.synchronize { @cache = {}; @bytes = 0 }

        private

        def store(key, value)
          @mutex.synchronize do
            if @bytes + key[0].bytesize > MAX_BYTES
              @cache = {}
              @bytes = 0
            end
            @bytes += key[0].bytesize unless @cache.key?(key)
            @cache[key] = value
          end
          value
        end

        # { blob id => filename } for the caption-less blobs, or nil when an
        # attachment's text could depend on more than that.
        def blob_filenames(content)
          content.attachments.each_with_object({}) do |attachment, filenames|
            case attachable = attachment.attachable
            when ActiveStorage::Blob
              filenames[attachable.id] = attachable[:filename] unless attachment.caption
            when ActionText::Attachables::RemoteImage, ActionText::Attachables::ContentAttachment
              # the text comes from the HTML
            else
              return nil
            end
          end
        end

        def filenames_unchanged?(filenames)
          filenames.empty? || ActiveStorage::Blob.where(id: filenames.keys).pluck(:id, :filename).to_h == filenames
        end
      end

      module Content
        def initialize(content = nil, options = {})
          super
          return unless content.is_a?(String)

          @plain_text_key = [content.frozen? ? content : content.dup.freeze, options.fetch(:canonicalize, true)]
          @plain_text_attachments = content.match?(ATTACHMENT)
        end

        def to_plain_text
          return super unless @plain_text_key
          return ActionTextPlainText.fetch(@plain_text_key) { super }.dup unless @plain_text_attachments

          ActionTextPlainText.fetch_with_attachments(@plain_text_key, self) { super }.dup
        end
      end
    end
  end
end

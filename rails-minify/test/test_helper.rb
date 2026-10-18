# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)

require "minitest/autorun"
require "rails"
require "active_record/railtie"
require "active_storage/engine"
require "action_text/engine"
require "omniauth"
require "rails_minify"

class TestApp < Rails::Application
  config.root = File.expand_path("..", __dir__)
  config.eager_load = false
  config.logger = Logger.new(nil)
  config.secret_key_base = "x" * 64
  config.active_storage.service = :test
  config.active_storage.service_configurations = { test: { service: "Disk", root: Dir.mktmpdir } }
end
ENV["DATABASE_URL"] = "sqlite3::memory:"
Rails.application.initialize!

ActiveRecord::Schema.verbose = false
ActiveRecord::Schema.define do
  create_table :active_storage_blobs do |t|
    t.string :key, null: false
    t.string :filename, null: false
    t.string :content_type
    t.text :metadata
    t.string :service_name, null: false
    t.bigint :byte_size, null: false
    t.string :checksum
    t.datetime :created_at, null: false
  end
  create_table :active_storage_attachments do |t|
    t.string :name, null: false
    t.references :record, null: false, polymorphic: true, index: false
    t.references :blob, null: false
    t.datetime :created_at, null: false
  end
end

# frozen_string_literal: true

require_relative "test_helper"
require "rubocop-minify"
require "tmpdir"
require "json"

class CopTest < Minitest::Test
  def test_autocorrects_through_rubocop
    Dir.mktmpdir do |dir|
      manifest = { "format" => ArMinimizer::Manifest::FORMAT, "keep" => ["attribute", "attribute="], "patterns" => [RewriteHelpers::PATTERNS],
        "models" => [{ "name" => "Venue", "patterns" => 0, "primary_key" => ["id"], "attributes" => { "featured" => "truthy", "name" => "string" }, "hand_written" => [] }] }
      Dir.mkdir("#{dir}/config")
      File.write("#{dir}/config/ar_minimizer.json", JSON.dump(manifest))
      File.write("#{dir}/.rubocop.yml", "plugins:\n  - rubocop-minify\nAllCops:\n  NewCops: disable\n  SuggestExtensions: false\n")
      File.write("#{dir}/x.rb", "# ゴルフ\nputs v.featured? if w.name_changed?\n")
      out = Dir.chdir(dir) { capture_io { RuboCop::CLI.new.run(["--only", "Minify/AttributeMethods", "-a", "x.rb"]) }.first }
      assert_equal "# ゴルフ\nputs v.featured.present? if w.attribute_changed?(:name)\n", File.read("#{dir}/x.rb"), out
    end
  end
end

# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
require "minitest/autorun"
require "ar_minimizer"
require "rubocop_minify"

module RewriteHelpers
  PATTERNS = [
    ["", "", "attribute", true], ["", "=", "attribute=", true], ["", "?", "attribute?", false],
    ["", "_changed?", "attribute_changed?", true], ["", "_was", "attribute_was", false],
    ["", "_will_change!", "attribute_will_change!", false], ["saved_change_to_", "?", "saved_change_to_attribute?", true],
  ].freeze

  def index
    @index ||= ArMinimizer::Index.new([
      ArMinimizer::Index::Model.new(name: "Venue", primary_key: ["id"], patterns: PATTERNS, hand_written: [], modules: ["Featurable"],
        attributes: { "id" => :numeric, "featured" => :truthy, "name" => :string, "rank" => :numeric, "status" => nil }),
    ], keep: ["attribute", "attribute="])
  end

  def rewrite(source, defined: {}, views: false)
    rw = RubocopMinify::Rewrite.new(index, defined: defined, views: views)
    3.times { source = RubocopMinify::Rewrite.apply(source, rw.edits(source)) }
    source
  end

  def messages(source, **opts) = RubocopMinify::Rewrite.new(index, **opts).edits(source).map(&:message)
end

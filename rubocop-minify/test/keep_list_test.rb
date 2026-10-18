# frozen_string_literal: true

require_relative "test_helper"
require "tmpdir"

# Names activerecord-minimizer's keep list still generates aren't removed, so
# their calls are left alone.
class KeepListTest < Minitest::Test
  include RewriteHelpers

  def index
    @index ||= ArMinimizer::Index.new([
      ArMinimizer::Index::Model.new(name: "Venue", primary_key: ["id"], patterns: PATTERNS, hand_written: [],
        attributes: { "featured" => :truthy, "name" => :string, "published" => :truthy }),
      ArMinimizer::Index::Model.new(name: "Guide", primary_key: ["id"], patterns: PATTERNS, hand_written: [],
        attributes: { "published" => :truthy }),
    ], keep: ["attribute", "attribute="])
  end

  def rewrite_kept(source, kept)
    rw = RubocopMinify::Rewrite.new(index, kept: Set.new(kept))
    RubocopMinify::Rewrite.apply(source, rw.edits(source))
  end

  def test_kept_names_are_left_alone
    src = "v.featured? && v.name_changed?\nclass Venue\n  before_save :x, if: :featured?\nend\nv.try(:featured?)"
    out = rewrite_kept(src, ["featured?"])
    assert_includes out, "v.featured? && v.attribute_changed?(:name)"
    assert_includes out, "if: :featured?"
    assert_empty RubocopMinify::Rewrite.new(index, kept: Set.new(["featured?"])).edits("v.try(:featured?)")
  end

  def kept_names(text)
    Dir.mktmpdir do |dir|
      File.write("#{dir}/keep.txt", text)
      RubocopMinify.kept_names(index, "#{dir}/keep.txt")
    end
  end

  def test_keep_file_entries
    assert_equal Set["featured?"], kept_names("featured? # in a comment too\n\n# a comment line\n")
    # Model#name counts once every model with the attribute is listed.
    assert_equal Set[], kept_names("Venue#published?\n")
    assert_equal Set["published?"], kept_names("Venue#published?\nGuide#published?\n")
    assert_equal Set["name_changed?"], kept_names("Venue#name_changed?\n")
    assert_equal Set[], RubocopMinify.kept_names(index, "/nonexistent/keep.txt")
  end

  def test_the_cop_and_minify_erb_read_the_keep_file
    Dir.mktmpdir do |dir|
      Dir.mkdir("#{dir}/config")
      File.write("#{dir}/config/ar_minimizer.json", ArMinimizer::Manifest.dump(index))
      File.write("#{dir}/config/ar_minimizer_keep.txt", "featured?\n")
      rw = RubocopMinify.rewrite_for(dir, manifest: "config/ar_minimizer.json", definition_paths: [], views: true)
      assert_equal 1, RubocopMinify::ERB.edits("<%= v.featured? %><%= v.name? %>", rw).size
    end
  end
end

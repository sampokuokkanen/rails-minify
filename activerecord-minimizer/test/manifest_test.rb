# frozen_string_literal: true

require "test_helper"

class ManifestTest < Minitest::Test
  def test_round_trip
    json = ArMinimizer::Manifest.dump(index)
    loaded = ArMinimizer::Manifest.parse(json)
    assert_equal index, loaded
    assert_equal :string, loaded["name?"].query
    assert_equal json, ArMinimizer::Manifest.dump(loaded)
    assert_equal ArMinimizer::Manifest.digest(index), ArMinimizer::Manifest.digest(loaded)
  end

  def test_digest_changes_with_the_models
    refute_equal ArMinimizer::Manifest.digest(index), ArMinimizer::Manifest.digest(ArMinimizer::Index.from_models([User]))
  end

  def test_rejects_other_formats
    assert_raises(ArgumentError) { ArMinimizer::Manifest.parse('{"format": 99, "entries": {}}') }
  end

  def test_rewriter_needs_no_loaded_constants
    # Admin::Thing doesn't exist; the manifest says it has the column, so self is known.
    entry = ArMinimizer::Index::Entry.new("attribute_changed?", "name", true, %w[Admin::Thing], nil)
    rewriter = ArMinimizer::Rewriter.new(index: { name_changed?: entry }, guards: true)
    assert_includes rewriter.rewrite("module Admin\n  class Thing\n    def x = name_changed?\n  end\nend").source,
      'def x = attribute_changed?(-"name")'
    # compact path in a namespace: can't tell statically, keep the guard
    assert_includes rewriter.rewrite("module Admin\n  class Foo::Thing\n    def x = name_changed?\n  end\nend").source,
      "::Admin::Thing.equal?(self.class)"
  end
end

class CensusTest < Minitest::Test
  def test_report
    Dir.mktmpdir do |root|
      FileUtils.mkdir_p("#{root}/app/models")
      File.write("#{root}/app/models/x.rb", "class X\n  def a(u) = [u.name_changed?, u.age_was]\nend\n")
      result = ArMinimizer::Census.report(root: root, models: [User, Post], guards: true)
      assert_equal 2, result.models
      assert_equal 2, result.sites
      assert_equal 1, result.files
      assert_operator result.stock_methods, :>, 100
      assert_match(/\Anone/, result.manifest)
      File.write("#{root}/config.json", "") # not the manifest path
      FileUtils.mkdir_p("#{root}/config")
      File.write("#{root}/config/ar_minimizer.json", ArMinimizer::Manifest.dump(ArMinimizer::Index.from_models([User, Post])))
      assert_equal "up to date", ArMinimizer::Census.report(root: root, models: [User, Post]).manifest
      assert_equal 5, result.lines.size
    end
  end
end

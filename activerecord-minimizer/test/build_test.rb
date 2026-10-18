# frozen_string_literal: true

require "test_helper"

class BuildTest < Minitest::Test
  def with_app
    Dir.mktmpdir do |root|
      FileUtils.mkdir_p(File.join(root, "app/models"))
      File.write(File.join(root, "app/models/thing.rb"), "class Thing\n  def x(u) = u.name_changed?\nend\n")
      File.write(File.join(root, "app/models/plain.rb"), "class Plain; end\n")
      yield root
    end
  end

  def build(root, **opts) = ArMinimizer::Build.new(root: root, index: index, guards: true, **opts)

  def test_refuses_outside_production
    with_app do |root|
      assert_raises(ArMinimizer::Build::NotProduction) { build(root, env: "development").run }
    end
  end

  def test_rewrites_in_place_once
    with_app do |root|
      out = StringIO.new
      report = build(root, env: "production", out: out).run
      assert_equal 1, report.files_changed
      assert_equal 1, report.sites
      assert_includes File.read(File.join(root, "app/models/thing.rb")), 'u.attribute_changed?(-"name")'
      assert_equal "class Plain; end\n", File.read(File.join(root, "app/models/plain.rb"))
      assert_includes out.string, "ar_minimizer: app/models/thing.rb (1 calls)"

      again = build(root, env: "production").run
      assert_equal 0, again.sites
    end
  end

  def test_dry_run_writes_nothing
    with_app do |root|
      before = File.read(File.join(root, "app/models/thing.rb"))
      assert_equal 1, build(root, env: "development", force: true, dry_run: true).run.sites
      assert_equal before, File.read(File.join(root, "app/models/thing.rb"))
    end
  end
end

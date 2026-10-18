# frozen_string_literal: true

require "test_helper"

class LoaderTest < Minitest::Test
  def test_compiles_files_as_they_load
    Dir.mktmpdir do |dir|
      dir = File.realpath(dir)
      # fnmatch without FNM_PATHNAME: * crosses directories
      ArMinimizer::Loader.install!(index: -> { index }, patterns: ["#{dir}/app/*.rb"], version: "test", guards: true) # indexed on first compile
      FileUtils.mkdir_p("#{dir}/app")
      File.write("#{dir}/app/loader_probe.rb", "module LoaderProbe\n  def self.check(u) = u.name_changed?\nend\n")
      File.write("#{dir}/outside.rb", "module LoaderOutside\n  def self.check(u) = u.name_changed?\nend\n")
      require "#{dir}/app/loader_probe"
      require "#{dir}/outside"

      assert_includes RubyVM::InstructionSequence.of(LoaderProbe.method(:check)).disasm, "attribute_changed?"
      refute_includes RubyVM::InstructionSequence.of(LoaderOutside.method(:check)).disasm, "attribute_changed?"
      with_slim(true) do
        u = User.create!(name: "a")
        u.name = "b"
        assert_equal true, LoaderProbe.check(u)
        assert_equal :poro, LoaderProbe.check(Poro.new)
      end
      # line numbers survive for backtraces
      assert_equal ["#{dir}/app/loader_probe.rb", 2], LoaderProbe.method(:check).source_location.first(2)
    end
  end
end

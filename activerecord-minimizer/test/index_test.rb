# frozen_string_literal: true

require "test_helper"

class IndexTest < Minitest::Test
  def test_maps_method_names_to_proxy_and_attribute
    assert_equal ArMinimizer::Index::Entry.new("attribute?", "name", false, %w[Post User], :string), index["name?"]
    assert_equal ArMinimizer::Index::Entry.new("saved_change_to_attribute?", "name", true, %w[Post User], nil), index["saved_change_to_name?"]
    assert_equal "query_attribute", index["name?"].public_proxy
    assert_nil index["name_will_change!"].public_proxy # private: called through __send__
  end

  def test_leaves_out_what_must_keep_its_own_method
    assert_nil index["age_changed?"], "hand-written in User"
    assert_nil index["name"], "readers stay generated"
    assert_nil index["name="], "writers stay generated"
    assert_nil index["id_was"], "primary key methods are real methods"
  end

  def test_classes_only_lists_names_that_resolve
    join = Class.new(ActiveRecord::Base) do
      self.table_name = "posts"
      def self.name = "HABTM_Posts" # what has_and_belongs_to_many's join models answer
    end
    assert_equal %w[Post User], ArMinimizer::Index.from_models([User, Post, join])["name_changed?"].classes
  end

  def test_shared_column_names_compile_once
    assert index["name_changed?"], "users.name and posts.name agree"
    # posts.title is a column; on a User (alias title -> name) the _has_attribute? guard falls back.
    assert_equal ArMinimizer::Index::Entry.new("attribute_changed?", "title", true, %w[Post], nil), index["title_changed?"]
  end
end

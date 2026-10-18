# frozen_string_literal: true

require_relative "test_helper"

class ErbTest < Minitest::Test
  include RewriteHelpers

  def fix(template)
    RubocopMinify::ERB.fix(template, RubocopMinify::Rewrite.new(index, views: true))
  end

  def test_rewrites_ruby_in_tags
    template = %(<p>日本</p>\n<% if venue.featured? %>\n  <%= venue.name_changed? ? "a" : venue.name? %>\n<% end %>\n<%# venue.featured? %>)
    fixed, manual = fix(template)
    assert_equal %(<p>日本</p>\n<% if venue.featured %>\n  <%= venue.attribute_changed?(:name) ? "a" : venue.name.present? %>\n<% end %>\n<%# venue.featured? %>), fixed
    assert_empty manual
  end

  def test_blocks_and_unrewritable_calls
    fixed, manual = fix(%(<% venues.each do |v| %><%= v.name_will_change! %><%= tag.p(v.rank?) %><% end %>))
    assert_equal %(<% venues.each do |v| %><%= v.name_will_change! %><%= tag.p(v.query_attribute(:rank)) %><% end %>), fixed
    assert_equal 1, manual.size
  end

  def test_view_helpers_without_receiver_are_not_records
    assert_equal ["<%= featured? %>", []], fix("<%= featured? %>")
  end
end

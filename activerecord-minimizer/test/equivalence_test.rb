# frozen_string_literal: true

require "test_helper"

# The same source, original and rewritten, must give the same answers (or raise
# the same errors) for every receiver, with Slim on and off.
class EquivalenceTest < Minitest::Test
  SOURCE = <<~'RUBY'
    class Member < ActiveRecord::Base
      self.table_name = "users"
      alias_attribute :title, :name

      def own = [name?, age?, active?, name_changed?, self.saved_change_to_name?, balance_before_type_cast, title_changed?]
      def in_block = [1].map { name_was }
    end

    # Not in the index: like a model the build never saw. Takes the original call.
    class SubMember < Member; end

    # The reader is overridden, so name? must still go through it.
    class Forced < ActiveRecord::Base
      self.table_name = "users"
      def name = "forced"
    end

    module Calls
      module_function

      def all(r)
        {
          query: -> { r.name? },
          query_int: -> { r.age? },
          query_bool: -> { r.active? },
          query_decimal: -> { r.balance? },
          query_time: -> { r.born_at? },
          query_enum: -> { r.status? },
          safe: -> { r&.name? },
          changed: -> { r.name_changed? },
          saved: -> { r.saved_change_to_name? },
          saved_kw: -> { r.saved_change_to_name?(from: nil) },
          was: -> { r.itself.name_was },
          change: -> { r.name_change },
          before_type_cast: -> { r.balance_before_type_cast },
          in_database: -> { r.name_in_database },
          alias_or_column: -> { r.title_changed? },
          will_change: -> { r.name_will_change!; r.name_changed? },
          restore: -> { r.restore_name!; r.name },
          own: -> { r.own },
          in_block: -> { r.in_block },
        }
      end
    end
  RUBY

  def receivers
    {
      new: Member.new(name: "", age: 0),
      saved: Member.create!(name: "a", age: 2, active: true, balance: "9.99"),
      dirty: Member.create!(name: "a").tap { it.name = "b" },
      partial: (Member.create!(name: "p"); Member.select(:id, :age).last),
      post: Post.create!(title: "t", name: "n"),
      poro: Poro.new,
      delegator: SimpleDelegator.new(Member.create!(name: "d")),
      subclass: SubMember.create!(name: "s").tap { it.name = "t" },
      forced: Forced.create!(name: ""),
      nil: nil,
    }
  end

  def results
    [false, true].to_h do |slim|
      with_slim(slim) do
        cases = receivers.flat_map do |rname, r|
          Calls.all(r).map { |cname, fn| ["#{rname}.#{cname}", outcome(&fn)] }
        end
        [slim, cases.to_h]
      end
    end
  end

  def test_original_and_rewritten_agree
    Object.class_eval(SOURCE, "member.rb", 1)
    original = results

    result = ArMinimizer::Rewriter.new(index: ArMinimizer::Index.from_models([User, Post, Member, Forced]), path: "member.rb", guards: true).rewrite(SOURCE)
    assert_operator result.sites, :>=, 20
    # self is known: no guard; Forced overrides the name reader, so name? keeps query_attribute
    assert_includes result.source, 'def own = [query_attribute(-"name"), ((self.age || 0) != 0), (!!self.active),'
    Object.class_eval(result.source, "member.rb", 1)
    compiled = results

    assert_equal original[false], original[true], "Slim changes nothing"
    original[false].each_key { assert_equal original[false][it], compiled[false][it], it }
    original[true].each_key { assert_equal original[true][it], compiled[true][it], it }
    # sanity: the matrix actually exercises different outcomes
    assert_equal [:poro], original[true]["poro.query"]
    assert_equal [:raised, ActiveModel::MissingAttributeError], original[true]["partial.query"]
    assert_equal [:raised, NoMethodError], original[true]["nil.query"]
    assert_equal [nil], original[true]["nil.safe"]
    assert_equal [true], original[true]["forced.query"]
    assert_equal ["s"], original[true]["subclass.was"]
  end
end

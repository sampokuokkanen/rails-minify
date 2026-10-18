# frozen_string_literal: true

require "herb"

module RubocopMinify
  # The same rewrite in ERB templates (RuboCop doesn't read them): Herb finds
  # the Ruby in each tag, Rewrite works on it as code that runs in a view.
  module ERB
    # Rewrite::Edits with offsets into the template.
    def self.edits(template, rewrite)
      found = []
      collect = lambda do |node|
        if node.class.name.start_with?("Herb::AST::ERB") && node.respond_to?(:content) && node.content &&
            !node.class.name.end_with?("CommentNode") && !node.tag_opening&.value.to_s.start_with?("<%#")
          base = node.content.range.from
          rewrite.edits(node.content.value).each do |e|
            found << Rewrite::Edit.new(e.from + base, e.to + base, e.replacement, e.message)
          end
        end
        node.compact_child_nodes.each(&collect)
      end
      collect.(Herb.parse(template).value)
      found
    end

    # The template with every rewritable call rewritten, and what's left to
    # do by hand.
    def self.fix(template, rewrite)
      5.times do
        edits = edits(template, rewrite)
        fixed = Rewrite.apply(template, edits)
        return [fixed, edits.reject(&:replacement)] if fixed == template

        template = fixed
      end
      [template, edits(template, rewrite).reject(&:replacement)]
    end
  end
end

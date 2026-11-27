# frozen_string_literal: true

require "spec_helper"
require "json"

# The nbsp sub-rules look entries up by first character instead of scanning every entry at every
# position. The index must never miss an entry the straightforward linear matcher finds, so this
# sweeps every locale's lists against that linear matcher.
RSpec.describe "nbsp first-character index" do
  nbsp = Polytypo::Engine::Rules::Nbsp
  space = 0x20
  no_break_space = 0xA0
  narrow_no_break_space = 0x202F

  registry = JSON.parse(File.read(File.expand_path("../lib/polytypo/data/locales/registry.json", __dir__)))

  # [prepared field, index keys, the sub-rule's own matcher]
  lists = [
    [:short_words, ->(w) { nbsp.first_char_or_uppercase(w) }, :match_first_char_lenient?],
    [:abbreviations, ->(w) { nbsp.first_char_or_no_break_space(w) }, :match_space_lenient?],
    [:symbols, ->(w) { [w[0]] }, :match_exact?],
    [:before_number, ->(w) { [w[0]] }, :match_exact?],
    [:before_word, ->(w) { [w[0]] }, :match_exact?],
    [:units, ->(e) { [e.w[0]] }, :match_exact?],
  ]

  def probes(word)
    base = [word, [Polytypo::Engine::UnicodeUtil.simple_uppercase(word[0]), *word[1..]]]
    base += [no_break_space_variant(word, 0xA0), no_break_space_variant(word, 0x202F)]
    base.flat_map { |w| [w, w + [0x78]] }
  end

  def no_break_space_variant(word, replacement)
    word.map { |c| c == 0x20 ? replacement : c }
  end

  registry["locales"].each do |locale|
    it "finds every entry the linear scan finds in #{locale}" do
      prep = nbsp.prepare(Polytypo::Engine::Locale.locale_data_raw(locale))
      lists.each do |field, keys, matcher|
        entries = prep.public_send(field)
        words = entries.map { |e| e.respond_to?(:w) ? e.w : e }
        expect(words).to all(satisfy { |w| !w.empty? }), "#{locale}.#{field} holds an empty entry"
        index = nbsp.index_by_first(entries, &keys)
        entries.each do |entry|
          word = entry.respond_to?(:w) ? entry.w : entry
          probes(word).each do |cp|
            linear = entries.select { |e| nbsp.send(matcher, cp, 0, e.respond_to?(:w) ? e.w : e) }
            indexed = (index[cp[0]] || []).select { |e| nbsp.send(matcher, cp, 0, e.respond_to?(:w) ? e.w : e) }
            expect(indexed).to eq(linear), "#{locale}.#{field}: #{word.inspect} at #{cp.inspect}"
          end
        end
      end
    end
  end
end

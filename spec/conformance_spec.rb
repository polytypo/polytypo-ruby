# frozen_string_literal: true

require "spec_helper"
require "json"

# The conformance runner (docs/ARCHITECTURE.md section 6). Every case in
# lib/polytypo/data/fixtures/ is driven through the public Polytypo.transform, and every
# non-throwing case is also an idempotency case. Nothing here knows about individual locales or
# rules: fixtures are discovered at spec-run time, mirroring the other three ports' own runners.
RSpec.describe "conformance fixtures" do
  fixtures_dir = File.expand_path("../lib/polytypo/data/fixtures", __dir__)
  fixture_files = Dir.glob(File.join(fixtures_dir, "*.json")).reject { |f| f.end_with?("locale-resolution.json") }
  raise "no fixture files found" if fixture_files.empty?

  fixture_files.sort.each do |path|
    data = JSON.parse(File.read(path))
    locale = data["locale"]

    data["cases"].each do |c|
      it "#{File.basename(path)}::#{c["id"]}" do
        if c["dialect"] == "mdx"
          skip "mdx dialect is not supported by this runtime (POLYTYPO_INVALID_DIALECT) -- " \
               "an accepted, narrower conformance claim; see spec/CONFORMANCE.md"
          next
        end

        opts = { locale: locale, mode: c["mode"] }
        opts[:dialect] = c["dialect"] if c["dialect"]
        opts[:rules] = c["rules"] if c["rules"]
        opts[:narrow_nbsp] = c["narrowNbsp"] if c["narrowNbsp"]
        opts[:keys] = c["keys"] if c["keys"]
        opts[:frontmatter_keys] = c["frontmatterKeys"] if c["frontmatterKeys"]

        if c["throws"]
          expect { Polytypo.transform(c["in"], **opts) }
            .to raise_error(Polytypo::Error) { |e| expect(e.code).to eq(c["throws"]) }
          next
        end

        expected = c["out"]
        got = Polytypo.transform(c["in"], **opts)
        expect(escape_non_ascii(got)).to eq(escape_non_ascii(expected)),
                                          "out = #{escape_non_ascii(got)}, want #{escape_non_ascii(expected)}"

        # Free coverage, and the most common port bug (ARCHITECTURE.md 6.1). The re-run carries
        # the case's OWN options: a case with narrowNbsp or keys is a fixed point under those and
        # not under the defaults, so spreading **opts here is contract, not convenience -- and for
        # keys the re-run would not even run without it, since the option has no default.
        twice = Polytypo.transform(expected, **opts)
        expect(escape_non_ascii(twice)).to eq(escape_non_ascii(expected)),
                                            "not idempotent: transform(out) = #{escape_non_ascii(twice)}"
      end
    end
  end
end

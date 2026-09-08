# frozen_string_literal: true

require_relative "lib/polytypo/version"

Gem::Specification.new do |spec|
  spec.name = "polytypo"
  spec.version = Polytypo::VERSION
  spec.authors = ["Iurii Rogulia"]
  spec.email = ["iurii@rogulia.fi"]

  spec.summary = "Normalize typography: quotes, dashes, ellipses, apostrophes, symbols and no-break spaces"
  spec.description = "polytypo normalizes typography across languages -- quotes, dashes, " \
                      "ellipses, apostrophes, symbols and no-break spaces -- driven by a spec " \
                      "shared across every polytypo runtime (github.com/polytypo/polytypo)."
  spec.homepage = "https://polytypo.dev/"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.2"

  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = "https://github.com/polytypo/polytypo-ruby"
  spec.metadata["changelog_uri"] = "https://github.com/polytypo/polytypo-ruby/releases"
  spec.metadata["rubygems_mfa_required"] = "true"

  # Everything under lib/, plus top-level docs. Never RSpec's own spec/ directory (test-only,
  # not part of the published gem) or CI/dev-only files.
  spec.files = Dir.chdir(__dir__) do
    `git ls-files -z`.split("\x0").select do |f|
      f.start_with?("lib/") || %w[README.md LICENSE polytypo.gemspec].include?(f)
    end
  end
  spec.require_paths = ["lib"]

  spec.add_dependency "commonmarker", "~> 2.0"
  # Development dependencies live in the Gemfile, not here (Gemspec/DevelopmentDependencies):
  # a gemspec's dependencies ship as metadata with every install, while dev-only tooling like
  # rspec/rubocop belongs only to this repository's own Bundler group.
end

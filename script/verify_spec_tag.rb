#!/usr/bin/env ruby
# frozen_string_literal: true

# Two-tag release contract, existence-only variant (docs/ROADMAP.md M5,
# docs/REPOSITORY_SPLIT_AND_SPEC_SYNC.md section 4.4, canonical repo).
#
# An operator creates and pushes canonical spec tag spec-v<VERSION> (VERSION from
# lib/polytypo/data/VERSION) to polytypo/polytypo before pushing this repo's own release tag
# v<X.Y.Z> (only the latter triggers .github/workflows/release.yml). This proves that tag exists
# in the canonical repository -- existence only, not commit-SHA equality: this repository was
# never part of polytypo/polytypo's git history (it is a from-spec port, not a filtered
# extraction), so its commits share no ancestry with the canonical repository's.
#
# Reads the GitHub REST API unauthenticated (polytypo/polytypo is public), never a local git
# operation against the canonical repo. Exits non-zero with a GitHub Actions ::error:: annotation
# on any failure.

require "net/http"
require "json"
require "uri"

CANONICAL_REPO = "polytypo/polytypo"
STRICT_SEMVER = /\A(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)\z/

def fail_with(message)
  puts "::error::#{message}"
  exit 1
end

def parse_strict_spec_version(raw)
  version = raw.strip
  fail_with("lib/polytypo/data/VERSION is empty (after trimming whitespace).") if version.empty?
  unless STRICT_SEMVER.match?(version)
    fail_with(
      "lib/polytypo/data/VERSION content #{version.inspect} is not a strict MAJOR.MINOR.PATCH " \
      "release version -- pre-release suffixes, build-metadata suffixes, leading zeros, and any " \
      "other form are rejected by this project's spec-tag policy."
    )
  end
  version
end

def canonical_tag_exists?(tag_name)
  uri = URI("https://api.github.com/repos/#{CANONICAL_REPO}/git/refs/tags/#{tag_name}")
  request = Net::HTTP::Get.new(uri)
  request["Accept"] = "application/vnd.github+json"

  response = Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: 30, read_timeout: 30) do |http|
    http.request(request)
  end

  return true if response.is_a?(Net::HTTPOK)
  return false if response.is_a?(Net::HTTPNotFound)

  fail_with("GitHub API returned #{response.code} resolving tag #{tag_name.inspect} in #{CANONICAL_REPO}.")
end

root = File.expand_path("..", __dir__)
spec_version_raw = File.read(File.join(root, "lib", "polytypo", "data", "VERSION"))
spec_version = parse_strict_spec_version(spec_version_raw)

tag_name = "spec-v#{spec_version}"
puts "lib/polytypo/data/VERSION:   #{spec_version}"
puts "expected canonical spec tag: #{tag_name}"

unless canonical_tag_exists?(tag_name)
  fail_with(
    "Tag #{tag_name.inspect} does not exist in #{CANONICAL_REPO}. It must be created and " \
    "pushed by an operator to #{CANONICAL_REPO} before this repository's release tag."
  )
end

puts "ok: canonical spec tag #{tag_name.inspect} exists in #{CANONICAL_REPO}."

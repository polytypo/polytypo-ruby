# frozen_string_literal: true

$LOAD_PATH.unshift(File.expand_path("../lib", __dir__))
require "polytypo"

RSpec.configure do |config|
  config.example_status_persistence_file_path = ".rspec_status"
  config.disable_monkey_patching!
  config.expect_with :rspec do |c|
    c.syntax = :expect
  end
end

# A diff full of invisible U+00A0 and U+202F is unreviewable (ARCHITECTURE.md 6.1) -- used only
# in test failure messages, never in the comparison itself.
def escape_non_ascii(str)
  str.codepoints.map { |cp| cp < 0x80 ? [cp].pack("U") : format("\\u%04x", cp) }.join
end

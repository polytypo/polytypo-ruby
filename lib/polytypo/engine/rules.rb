# frozen_string_literal: true

# Requiring this file is enough to register every rule id with Registry -- mirrors the other
# three ports' own "importing the rules package/module is enough, no separate caller-side step"
# pattern. Order here does not matter (registration order is never pipeline order -- that comes
# from order.json, ARCHITECTURE.md section 4.5), but dash_shared and quote_ambiguity are required
# first since dashes/ranges and quotes/apostrophe depend on them.
require_relative "rules/dash_shared"
require_relative "rules/quote_ambiguity"

require_relative "rules/spaces"
require_relative "rules/ellipsis"
require_relative "rules/ranges"
require_relative "rules/dashes"
require_relative "rules/hyphen"
require_relative "rules/quotes"
require_relative "rules/apostrophe"
require_relative "rules/symbols"
require_relative "rules/nbsp"

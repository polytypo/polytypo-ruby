# frozen_string_literal: true

require "rspec"
require "tmpdir"
require "fileutils"
require "English"

# Builds the actual .gem file and installs it into a scratch GEM_HOME, then requires it from
# there -- a $LOAD_PATH-based run against the working tree (every other spec in this suite)
# cannot catch a gemspec `files` list mistake, e.g. lib/polytypo/data/ silently excluded. Do not
# trust a bundler-exec run against the working tree as proof the *packaged* gem is correct.
RSpec.describe "packaged gem" do
  it "builds, installs, and exercises every mode from a clean GEM_HOME" do
    root = File.expand_path("..", __dir__)

    Dir.mktmpdir do |tmp|
      gem_home = File.join(tmp, "gem_home")
      FileUtils.mkdir_p(gem_home)

      build_out = `cd #{root} && gem build polytypo.gemspec --output #{tmp}/polytypo.gem 2>&1`
      raise "gem build failed:\n#{build_out}" unless $CHILD_STATUS.success?

      # No --local: the primary gem comes from the local file, but its runtime dependency
      # (commonmarker) still needs to resolve from a real gem source.
      install_out = `GEM_HOME=#{gem_home} GEM_PATH=#{gem_home} gem install #{tmp}/polytypo.gem --no-document 2>&1`
      raise "gem install failed:\n#{install_out}" unless $CHILD_STATUS.success?

      script = File.join(tmp, "probe.rb")
      File.write(script, <<~RUBY)
        require "polytypo"
        out_text = Polytypo.transform('She said, "hi".', locale: "en-US")
        raise "text mode failed: \#{out_text.inspect}" unless out_text == "She said, “hi”."

        out_html = Polytypo.transform('<p>"x"</p>', locale: "en-US", mode: "html")
        raise "html mode failed: \#{out_html.inspect}" unless out_html.include?("“x”")

        out_md = Polytypo.transform("Body \\"x\\".\\n", locale: "en-US", mode: "markdown", dialect: "commonmark")
        raise "markdown mode failed: \#{out_md.inspect}" unless out_md.include?("“x”")

        out_yaml = Polytypo.transform("a: x...y\\n", locale: "en-US", mode: "yaml", keys: ["a"])
        raise "yaml mode failed: \#{out_yaml.inspect}" unless out_yaml.include?("x…y")

        puts "ALL_OK"
      RUBY

      run_out = `GEM_HOME=#{gem_home} GEM_PATH=#{gem_home} ruby #{script} 2>&1`
      expect(run_out).to include("ALL_OK"), "packaged gem probe failed:\n#{run_out}"
    end
  end
end

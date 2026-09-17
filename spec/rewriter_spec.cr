require "./spec_helper"

# The ARGV rewriter turns the gh-style `rd <noun> <verb>` grammar into the
# colon form athena-console resolves natively, without touching flags or
# unknown/bare/colon input.
describe RightDesk::CLI do
  describe ".join_noun_verb" do
    {
      ["deals", "list"]              => ["deals:list"],
      ["deals", "get", "5"]          => ["deals:get", "5"],
      ["contacts", "search", "acme"] => ["contacts:search", "acme"],
      ["companies", "list"]          => ["companies:list"],
      ["companies", "get", "5"]      => ["companies:get", "5"],
      ["companies", "create", "--name", "Acme"] => ["companies:create", "--name", "Acme"],
      ["pipelines", "create", "--name", "Sales"] => ["pipelines:create", "--name", "Sales"],
      ["pipelines", "delete", "5", "--yes"] => ["pipelines:delete", "5", "--yes"],
      ["stages", "reorder", "--pipeline", "2"] => ["stages:reorder", "--pipeline", "2"],
      ["stages", "delete", "7", "--pipeline", "2", "--yes"] => ["stages:delete", "7", "--pipeline", "2", "--yes"],
      ["products", "get", "5"] => ["products:get", "5"],
      ["products", "activate", "5"] => ["products:activate", "5"],
      ["products", "deactivate", "5"] => ["products:deactivate", "5"],
      ["contacts", "merge", "5", "--duplicate", "6"] => ["contacts:merge", "5", "--duplicate", "6"],
      ["contacts", "create", "--email", "a@b.co"] => ["contacts:create", "--email", "a@b.co"],
      ["customers", "timeline", "5"] => ["customers:timeline", "5"],
      ["partners", "create", "--title", "Acme"] => ["partners:create", "--title", "Acme"],
      ["leads", "convert", "7", "--to", "deal", "--yes"] => ["leads:convert", "7", "--to", "deal", "--yes"],
      ["leads", "move", "7", "--stage", "3"] => ["leads:move", "7", "--stage", "3"],
      ["leads", "disqualify", "7"] => ["leads:disqualify", "7"],
      ["deals", "convert", "5", "--to", "customer", "--yes"] => ["deals:convert", "5", "--to", "customer", "--yes"],
      ["deals", "won", "5"] => ["deals:won", "5"],
      ["deals", "notes", "5"] => ["deals:notes", "5"],
      ["deals", "note-add", "5", "--body", "hi"] => ["deals:note-add", "5", "--body", "hi"],
      ["deals", "note-delete", "7", "--yes"] => ["deals:note-delete", "7", "--yes"],
      ["deals", "checklist-templates"] => ["deals:checklist-templates"],
      ["deals", "checklist-add", "5", "--template", "3"] => ["deals:checklist-add", "5", "--template", "3"],
      ["deals", "checklist-check", "9"] => ["deals:checklist-check", "9"],
      ["deals", "events", "5", "--type", "call_logged"] => ["deals:events", "5", "--type", "call_logged"],
      ["deals", "event-add", "5", "--type", "call_logged"] => ["deals:event-add", "5", "--type", "call_logged"],
      ["activities", "list", "--done", "true"] => ["activities:list", "--done", "true"],
      ["activities", "get", "5"] => ["activities:get", "5"],
      ["activities", "create", "--subject", "Call"] => ["activities:create", "--subject", "Call"],
      ["activities", "update", "5", "--subject", "New"] => ["activities:update", "5", "--subject", "New"],
      ["activities", "delete", "5", "--yes"] => ["activities:delete", "5", "--yes"],
      ["activities", "done", "5"] => ["activities:done", "5"],
      ["activities", "reopen", "5"] => ["activities:reopen", "5"],
      ["activities", "add-blocker", "5", "--note", "wait"] => ["activities:add-blocker", "5", "--note", "wait"],
      ["activities", "subtask-add", "5", "--text", "step"] => ["activities:subtask-add", "5", "--text", "step"],
      ["activities", "start-timer", "5"] => ["activities:start-timer", "5"],
      ["activities", "stop-timer", "5"] => ["activities:stop-timer", "5"],
      ["activities", "log-time", "5", "--minutes", "30"] => ["activities:log-time", "5", "--minutes", "30"],
      ["activities", "comment", "5", "--body", "hi"] => ["activities:comment", "5", "--body", "hi"],
      ["activities", "history", "5"] => ["activities:history", "5"],
      ["contacts", "import", "-f", "leads.csv"] => ["contacts:import", "-f", "leads.csv"],
      ["companies", "import", "-f", "co.csv", "--yes"] => ["companies:import", "-f", "co.csv", "--yes"],
      ["imports", "list"]            => ["imports:list"],
      ["imports", "get", "5", "--wait"] => ["imports:get", "5", "--wait"],
      ["imports", "start", "5"]      => ["imports:start", "5"],
      ["imports", "skipped", "5", "--reason", "duplicate"] => ["imports:skipped", "5", "--reason", "duplicate"],
      ["deals", "list", "--json"]    => ["deals:list", "--json"],
      ["deals", "list", "--status", "open"] => ["deals:list", "--status", "open"],
      ["deals"]                      => ["deals"],          # bare noun → namespace listing
      ["deals", "bogus"]             => ["deals", "bogus"], # unknown verb untouched
      ["deals:get", "5"]             => ["deals:get", "5"], # colon form passes through
      ["whoami"]                     => ["whoami"],
      ["--version"]                  => ["--version"],
      [] of String                   => [] of String,
    }.each do |input, expected|
      it "rewrites #{input.inspect}" do
        RightDesk::CLI.join_noun_verb(input).should eq(expected)
      end
    end
  end

  describe ".extract_global_flags" do
    it "pulls out --host value and leaves the rest" do
      remaining = RightDesk::CLI.extract_global_flags(["deals", "list", "--host", "http://localhost:3000"])
      remaining.should eq(["deals", "list"])
      RightDesk::Config.base_url.should eq("http://localhost:3000")
    ensure
      RightDesk::Config.host_override = nil
    end

    it "supports --host=value form" do
      remaining = RightDesk::CLI.extract_global_flags(["--host=example.test", "whoami"])
      remaining.should eq(["whoami"])
      RightDesk::Config.base_url.should eq("https://example.test")
    ensure
      RightDesk::Config.host_override = nil
    end
  end
end

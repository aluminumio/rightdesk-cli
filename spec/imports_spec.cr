require "./spec_helper"
require "http/formdata"
require "http/server"
require "file_utils"

# Binds real ARGV against the command that carries the upload option set, so the flag
# rules are exercised the way they are in use.
private def import_input(args : Array(String)) : ACON::Input::Interface
  input = ACON::Input::ARGV.new(args)
  input.bind RightDesk::ContactsImportCommand.new.definition
  input.validate
  input
end

private def imports_input(command : ACON::Command, args : Array(String)) : ACON::Input::Interface
  input = ACON::Input::ARGV.new(args)
  input.bind command.definition
  input.validate
  input
end

# Runs `block` against a throwaway server on loopback, with the config env pointed at it
# and HOME redirected so a real ~/.rightdesk token file can never be read or written.
# Yields the recorded requests. Mirrors spec/client_multipart_spec.cr.
private def with_stub_api(handler : Proc(HTTP::Server::Context, Nil), &)
  requests = [] of {String, String, String}

  server = HTTP::Server.new do |context|
    requests << {context.request.method, context.request.resource,
                 context.request.body.try(&.gets_to_end) || ""}
    handler.call(context)
  end
  address = server.bind_tcp("127.0.0.1", 0)
  spawn { server.listen }

  previous_home = ENV["HOME"]?
  previous_token = ENV["RIGHTDESK_TOKEN"]?
  previous_url = ENV["RIGHTDESK_URL"]?
  tmp_home = File.tempname("rightdesk-imports-spec")
  Dir.mkdir_p(tmp_home)

  begin
    ENV["HOME"] = tmp_home
    ENV["RIGHTDESK_TOKEN"] = "probe-token"
    ENV["RIGHTDESK_URL"] = "http://127.0.0.1:#{address.port}"
    yield requests
  ensure
    server.close
    previous_home ? (ENV["HOME"] = previous_home) : ENV.delete("HOME")
    previous_token ? (ENV["RIGHTDESK_TOKEN"] = previous_token) : ENV.delete("RIGHTDESK_TOKEN")
    previous_url ? (ENV["RIGHTDESK_URL"] = previous_url) : ENV.delete("RIGHTDESK_URL")
    FileUtils.rm_rf(tmp_home)
  end
end

private def captured(&) : String
  io = IO::Memory.new
  yield ACON::Output::IO.new(io)
  io.to_s
end

private def import_json(**fields) : JSON::Any
  JSON.parse({"import" => fields}.to_json)["import"]
end

describe "RightDesk.poll_decision" do
  # The whole table, since this is the only part of --wait that is testable without a
  # server: every branch that could leave a loop spinning or exiting for the wrong reason.
  it "keeps going while the import is pending" do
    RightDesk.poll_decision("uploaded", 0.0, 0).should eq(RightDesk::PollDecision::Continue)
    RightDesk.poll_decision("processing", 10.0, 0).should eq(RightDesk::PollDecision::Continue)
  end

  it "ends on the two terminal states" do
    RightDesk.poll_decision("finished", 1.0, 0).should eq(RightDesk::PollDecision::Done)
    RightDesk.poll_decision("failed", 1.0, 0).should eq(RightDesk::PollDecision::Failed)
  end

  it "stops rather than spins on a state it cannot interpret" do
    # A newer server could add one. Terminal-by-default, and never reported as success.
    RightDesk.poll_decision("quarantined", 1.0, 0).should eq(RightDesk::PollDecision::GiveUp)
  end

  it "times out only while still pending" do
    RightDesk.poll_decision("processing", 901.0, 0).should eq(RightDesk::PollDecision::Timeout)
    # A finished import that took longer than the timeout is finished, not a timeout.
    RightDesk.poll_decision("finished", 901.0, 0).should eq(RightDesk::PollDecision::Done)
  end

  it "retries a stateless poll a bounded number of times" do
    RightDesk.poll_decision(nil, 1.0, 1).should eq(RightDesk::PollDecision::Continue)
    RightDesk.poll_decision(nil, 1.0, RightDesk::POLL_MAX_FAILURES).should eq(RightDesk::PollDecision::GiveUp)
  end

  it "prefers give-up over timeout when both apply" do
    RightDesk.poll_decision(nil, 901.0, RightDesk::POLL_MAX_FAILURES).should eq(RightDesk::PollDecision::GiveUp)
  end
end

describe "RightDesk.poll_interval" do
  it "backs off and then caps" do
    RightDesk.poll_interval(1.0).should eq(1.5)
    RightDesk.poll_interval(RightDesk::POLL_MAX_INTERVAL).should eq(RightDesk::POLL_MAX_INTERVAL)
    RightDesk.poll_interval(1000.0).should eq(RightDesk::POLL_MAX_INTERVAL)
  end
end

describe "RightDesk.poll_hard_failure?" do
  it "treats answers as final and hiccups as retryable" do
    [401, 403, 404].each { |s| RightDesk.poll_hard_failure?(s).should be_true }
    # 599 is the synthesized connection failure; 500 is a server blip. Both retry.
    [500, 502, RightDesk::Client::CONNECTION_FAILED_STATUS].each do |s|
      RightDesk.poll_hard_failure?(s).should be_false
    end
  end
end

describe "RightDesk.progress?" do
  it "is suppressed under --json and under RD_NO_PROGRESS" do
    RightDesk.progress?(true).should be_false

    previous = ENV["RD_NO_PROGRESS"]?
    begin
      ENV["RD_NO_PROGRESS"] = "1"
      RightDesk.progress?(false).should be_false
    ensure
      previous ? (ENV["RD_NO_PROGRESS"] = previous) : ENV.delete("RD_NO_PROGRESS")
    end
  end

  it "follows stderr, not stdout, so a redirected stderr gets no bar frames" do
    # Under `crystal spec` stderr is a tty locally and a pipe in CI, so assert the rule
    # rather than the value.
    RightDesk.progress?(false).should eq(STDERR.tty?)
  end
end

describe "RightDesk.first_line" do
  it "keeps a one-line reason and cuts a backtrace down to its message" do
    RightDesk.first_line("File is too large").should eq("File is too large")
    RightDesk.first_line("Illegal quoting in line 1.\n/gems/csv/parser.rb:1085\n/more")
      .should eq("Illegal quoting in line 1.")
    RightDesk.first_line(nil).should be_nil
    RightDesk.first_line("   ").should be_nil
  end

  it "caps a single very long line" do
    RightDesk.first_line("x" * 400).not_nil!.size.should eq(301)
  end
end

describe "RightDesk.display_width" do
  it "counts CJK as two cells so a Japanese mapping lines up" do
    RightDesk.display_width("Email").should eq(5)
    RightDesk.display_width("メールアドレス").should eq(14)
    RightDesk.pad_to("姓", 6).should eq("姓    ")
  end
end

describe "RightDesk.human_bytes" do
  it "scales the unit" do
    RightDesk.human_bytes(512_i64).should eq("512 B")
    RightDesk.human_bytes(18_842_i64).should eq("18.4 KB")
    RightDesk.human_bytes(26_214_400_i64).should eq("25.0 MB")
  end
end

describe "RightDesk.run_import_upload" do
  # Both guards run before any HTTP call, which is what makes them testable here.
  it "requires --file" do
    expect_raises(RightDesk::UsageError, /--file is required/) do
      RightDesk.run_import_upload(import_input([] of String),
        ACON::Output::IO.new(IO::Memory.new), "contacts:import", "contact")
    end
  end

  it "rejects a path that is not a file before uploading anything" do
    expect_raises(RightDesk::UsageError, /no such file/) do
      RightDesk.run_import_upload(import_input(["--file", "/nonexistent/nope.csv"]),
        ACON::Output::IO.new(IO::Memory.new), "contacts:import", "contact")
    end
  end
end

describe "RightDesk.id_argument!" do
  it "takes a numeric id" do
    RightDesk.id_argument!(imports_input(RightDesk::ImportsGetCommand.new, ["8821"])).should eq("8821")
  end

  it "trims it" do
    RightDesk.id_argument!(imports_input(RightDesk::ImportsGetCommand.new, ["8821 "])).should eq("8821")
  end

  # /api/v1/imports/:id is constrained to \d+, so a non-numeric id never reaches the
  # controller: it comes back without the JSON error body every other failure has.
  it "rejects an id the imports route could never match" do
    %w[abc 12a 88.2].each do |raw|
      expect_raises(RightDesk::UsageError, /id must be a number/) do
        RightDesk.id_argument!(imports_input(RightDesk::ImportsGetCommand.new, [raw]))
      end
    end
  end

  it "rejects a blank id" do
    expect_raises(RightDesk::UsageError, /id is required/) do
      RightDesk.id_argument!(imports_input(RightDesk::ImportsGetCommand.new, [" "]))
    end
  end
end

describe "RightDesk.skipped_reason" do
  it "passes through the outcomes the server filters on" do
    %w[duplicate invalid].each do |reason|
      input = imports_input(RightDesk::ImportsSkippedCommand.new, ["1", "--reason", reason])
      RightDesk.skipped_reason(input).should eq(reason)
    end
  end

  it "is absent when the flag is" do
    RightDesk.skipped_reason(imports_input(RightDesk::ImportsSkippedCommand.new, ["1"])).should be_nil
  end

  # The server ignores an unrecognized reason, which would hand back every skipped row
  # while reading as a filter. `blank` is the tempting one: it is a count, never a row.
  it "rejects a reason the server cannot filter on" do
    input = imports_input(RightDesk::ImportsSkippedCommand.new, ["1", "--reason", "blank"])
    expect_raises(RightDesk::UsageError, /--reason must be one of: duplicate, invalid/) do
      RightDesk.skipped_reason(input)
    end
  end
end

describe "RightDesk.run_import_upload with --yes" do
  # The regression this whole change exists for. Creating with import[start]=true cannot
  # report a refused start -- the API 201s either way and the payload says `uploaded`
  # whether the job was queued or refused -- so the CLI used to poll a run that never
  # began for 15 minutes and then blame the timeout.
  it "starts in its own request and reports the server's refusal instead of polling" do
    csv = File.tempname("rd-import-spec", ".csv")
    File.write(csv, "Industry,City\nSoftware,Tokyo\n")

    handler = ->(context : HTTP::Server::Context) do
      if context.request.resource.ends_with?("/start")
        context.response.status_code = 422
        context.response.print %({"error":"No column is mapped to a field that identifies a record",) +
                               %("code":"no_importable_columns","details":["first_name","last_name","email","phone"]})
      else
        context.response.status_code = 201
        context.response.print %({"import":{"id":8821,"state":"uploaded","item_type":"contact",) +
                               %("filename":"rd-import-spec.csv","column_mapping":{"Industry":"industry"},) +
                               %("unmapped_columns":[]}})
      end
      nil
    end

    RightDesk.exit_code = 0

    status = with_stub_api(handler) do |requests|
      result = RightDesk.run_import_upload(
        imports_input(RightDesk::ContactsImportCommand.new, ["--file", csv, "--yes", "--no-wait"]),
        ACON::Output::IO.new(IO::Memory.new), "contacts:import", "contact")

      # Two POSTs and no GET: the refusal ended it before any polling.
      requests.size.should eq(2)
      requests.map { |(method, _, _)| method }.should eq(%w[POST POST])
      requests[0][1].should eq("/api/v1/imports")
      requests[1][1].should eq("/api/v1/imports/8821/start")
      # The field that made the refusal invisible must not be sent at all.
      requests[0][2].should_not contain("import[start]")

      result
    end

    status.should eq(ACON::Command::Status::FAILURE)
    RightDesk.exit_code?.should eq(1)
  ensure
    File.delete?(csv) if csv
    RightDesk.exit_code = 0
  end
end

describe "RightDesk.print_import_mapping" do
  it "shows each column's target and marks the unmapped ones" do
    import = import_json(
      filename: "leads.csv",
      byte_size: 18_842,
      column_mapping: {"Email" => "email", "First Name" => "first_name", "Internal ID" => "do_not_import"},
      unmapped_columns: ["Internal ID"]
    )

    out = captured { |o| RightDesk.print_import_mapping(o, import, "leads.csv") }

    out.should contain("mapping detected for leads.csv (18.4 KB)")
    out.should match(/Email\s+->\s+email/)
    out.should match(/First Name\s+->\s+first_name/)
    # The point of the screen: a dropped column is visible, not silent.
    out.should match(/Internal ID\s+->\s+\(not imported\)/)
    out.should contain("1 column will not be imported")
  end

  it "calls out a mapping that would write nothing" do
    import = import_json(
      filename: "junk.csv",
      column_mapping: {"zzz" => "do_not_import", "yyy" => "do_not_import"},
      unmapped_columns: ["zzz", "yyy"]
    )

    out = captured { |o| RightDesk.print_import_mapping(o, import, "junk.csv") }

    out.should contain("none of these columns matched a field")
    # The generic count line would understate it.
    out.should_not contain("2 columns will not be imported")
  end

  it "says so when no columns were detected" do
    out = captured { |o| RightDesk.print_import_mapping(o, import_json(column_mapping: {} of String => String), "x.csv") }
    out.should contain("no columns detected")
  end
end

describe "RightDesk.print_import_summary" do
  it "prints the counts and points at the skipped rows" do
    body = {"import" => {
      "counts"                 => {"row" => 412, "imported" => 396, "duplicate" => 14, "invalid" => 2, "blank" => 0, "skipped" => 16},
      "skipped_rows_truncated" => false,
      "warnings"               => [] of String,
    }}.to_json

    out = captured { |o| RightDesk.print_import_summary(o, body, "8821") }

    out.should contain("412 rows · 396 imported · 14 duplicate · 2 invalid")
    # A zero bucket is noise, so it is left out.
    out.should_not contain("0 blank")
    out.should contain("16 rows skipped — see: rd imports skipped 8821")
  end

  it "pluralizes the counts" do
    one = {"import" => {"counts" => {"row" => 1, "imported" => 0, "skipped" => 1}}}.to_json
    out = captured { |o| RightDesk.print_import_summary(o, one, "3") }
    out.should contain("1 row · 0 imported")
    out.should contain("1 row skipped")
  end

  it "degrades to a bare line when the payload has no counts" do
    out = captured { |o| RightDesk.print_import_summary(o, %({"import":{}}), "12") }
    out.should contain("import 12 finished")
  end
end

describe "RightDesk.print_skipped_rows" do
  # `values` differs by item type -- email/phone for contacts, domain for companies --
  # so the printer must not assume one shape.
  it "renders a contact duplicate with what it collided with" do
    parsed = JSON.parse({"skipped_rows" => [{
      "row_number"    => 7,
      "outcome"       => "duplicate",
      "values"        => {"email" => "ada@x.test", "phone" => nil},
      "matched_by"    => "email",
      "matched_value" => "ada@x.test",
      "existing"      => {"type" => "Contact", "id" => 91, "roles" => ["customer"]},
    }]}.to_json)

    out = captured { |o| RightDesk.print_skipped_rows(o, parsed) }

    out.should contain("7\tduplicate\tada@x.test\temail ada@x.test\tContact 91")
  end

  it "renders a company row and an invalid row" do
    parsed = JSON.parse({"skipped_rows" => [
      {"row_number" => 3, "outcome" => "duplicate", "values" => {"domain" => "acme.test"},
       "matched_by" => "domain", "matched_value" => "acme.test",
       "existing" => {"type" => "Company", "id" => 4}},
      {"row_number" => 9, "outcome" => "invalid", "values" => {"email" => "nope"},
       "errors" => ["Email is invalid"]},
    ]}.to_json)

    out = captured { |o| RightDesk.print_skipped_rows(o, parsed) }

    out.should contain("3\tduplicate\tacme.test\tdomain acme.test\tCompany 4")
    out.should contain("9\tinvalid\tnope\tEmail is invalid")
  end
end

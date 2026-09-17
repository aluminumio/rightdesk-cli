require "./spec_helper"

# Binds real ARGV against the command that carries the upload option set, so the flag
# rules are exercised the way they are in use.
private def import_input(args : Array(String)) : ACON::Input::Interface
  input = ACON::Input::ARGV.new(args)
  input.bind RightDesk::ContactsImportCommand.new.definition
  input.validate
  input
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

require "./spec_helper"

# Builds a parsed input for the shared activities create/update option set, so the
# body-building and flag-validation rules can be exercised without a live API.
private def activity_input(args : Array(String)) : ACON::Input::Interface
  # activities:create carries the shared option set and takes no arguments, so its
  # definition is the one these flags are parsed against in real use.
  input = ACON::Input::ARGV.new(args)
  input.bind RightDesk::ActivitiesCreateCommand.new.definition
  input.validate
  input
end

describe "RightDesk.activity_body" do
  it "sends only the flags that were given" do
    body = RightDesk.activity_body(activity_input(["--subject", "Call ACME", "--type", "call"]))
    body.should eq({"subject" => "Call ACME", "activity_type" => "call"})
  end

  it "sends an explicit null for a flag given an empty value, to clear the field" do
    body = RightDesk.activity_body(activity_input(["--location", ""]))
    body.has_key?("location").should be_true
    body["location"].should be_nil
    body.to_json.should eq(%({"location":null}))
  end

  it "carries integers as integers and rejects non-numeric ones" do
    body = RightDesk.activity_body(activity_input(["--duration", "45", "--interval", "2"]))
    body["duration_minutes"].should eq(45)
    body["recurrence_interval"].should eq(2)

    expect_raises(RightDesk::UsageError, /--duration must be an integer/) do
      RightDesk.activity_body(activity_input(["--duration", "3o"]))
    end
  end

  it "leaves the booleans alone unless one of the pair is given" do
    RightDesk.activity_body(activity_input(["--subject", "x"])).has_key?("has_time").should be_false
    RightDesk.activity_body(activity_input(["--has-time"]))["has_time"].should be_true
    RightDesk.activity_body(activity_input(["--no-has-time"]))["has_time"].should be_false
    RightDesk.activity_body(activity_input(["--recurring"]))["is_recurring"].should be_true
    RightDesk.activity_body(activity_input(["--no-recurring"]))["is_recurring"].should be_false
  end

  it "rejects a flag and its negation together" do
    expect_raises(RightDesk::UsageError, /mutually exclusive/) do
      RightDesk.activity_body(activity_input(["--recurring", "--no-recurring"]))
    end
  end

  it "has no --company flag: contact/company are derived from the primary link" do
    expect_raises(ACON::Exception::Runtime, /'--company' option does not exist/) do
      activity_input(["--company", "7"])
    end
  end
end

describe "RightDesk integer flags" do
  it "requires a value" do
    expect_raises(RightDesk::UsageError, /--interval is required/) do
      RightDesk.int_option!(activity_input([] of String), "interval")
    end
  end

  it "rejects a negative index instead of letting it wrap onto the last row" do
    expect_raises(RightDesk::UsageError, /--interval must be zero or greater/) do
      RightDesk.index_option!(activity_input(["--interval=-2"]), "interval")
    end
  end

  it "accepts zero as an index" do
    RightDesk.index_option!(activity_input(["--interval", "0"]), "interval").should eq(0)
  end
end

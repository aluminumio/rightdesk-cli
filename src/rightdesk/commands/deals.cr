require "athena-console"
require "json"
require "uri"
require "colorize"
require "../client"

module RightDesk
  @[ACONA::AsCommand("deals:list", description: "List deals (newest first)")]
  class DealsListCommand < ACON::Command
    include JSONOption

    protected def configure : Nil
      DealsListCommand.add_json_option(self)
      self
        .option("status", nil, ACON::Input::Option::Value[:required], "Filter by status: open, won, lost")
        .option("page", nil, ACON::Input::Option::Value[:required], "Page number (default 1)")
        .option("limit", nil, ACON::Input::Option::Value[:required], "Results per page (max 100)")
    end

    protected def execute(input : ACON::Input::Interface, output : ACON::Output::Interface) : ACON::Command::Status
      params = URI::Params.build do |form|
        if s = input.option("status").to_s.presence
          form.add("status", s)
        end
        if p = input.option("page").to_s.presence
          form.add("page", p)
        end
        if l = input.option("limit").to_s.presence
          form.add("per_page", l)
        end
      end

      resp = RightDesk::Client.get("/api/v1/deals", params)
      return RightDesk.fail("deals:list", resp, json?(input)) unless resp.success?

      if json?(input)
        output.puts resp.body
        return ACON::Command::Status::SUCCESS
      end

      parsed = JSON.parse(resp.body)
      deals = parsed["deals"]?.try(&.as_a?) || [] of JSON::Any

      output.puts ""
      output.puts String.build { |s|
        s << "  "
        s << "ID".ljust(8).colorize(:white).mode(:bold)
        s << "Title".ljust(32).colorize(:white).mode(:bold)
        s << "Value".ljust(16).colorize(:white).mode(:bold)
        s << "Status".ljust(8).colorize(:white).mode(:bold)
        s << "Stage".colorize(:white).mode(:bold)
      }
      output.puts "  #{"─" * 78}"

      deals.each do |d|
        id = d["id"]?.try(&.to_s) || "?"
        title = d["title"]?.try(&.as_s?) || "—"
        value = d["value"]?.try(&.to_s) || "0"
        currency = d["currency"]?.try(&.as_s?) || ""
        status = d["status"]?.try(&.as_s?) || ""
        stage = d["stage_name"]?.try(&.as_s?) || ""

        output.puts String.build { |s|
          s << "  "
          s << id.ljust(8)
          s << (title.size > 30 ? "#{title[0..29]}…" : title).ljust(32)
          s << "#{value} #{currency}".ljust(16)
          s << status.ljust(8).colorize(status == "won" ? :green : status == "lost" ? :red : :yellow)
          s << stage
        }
      end

      if meta = parsed["meta"]?
        output.puts ""
        output.puts "  #{meta["total_count"]?} deals — page #{meta["current_page"]?}/#{meta["total_pages"]?}"
      end
      output.puts ""
      ACON::Command::Status::SUCCESS
    rescue ex
      STDERR.puts "deals:list failed: #{ex.message}"
      RightDesk.exit_code = 1
      ACON::Command::Status::FAILURE
    end
  end

  @[ACONA::AsCommand("deals:get", description: "Show a single deal by ID")]
  class DealsGetCommand < ACON::Command
    include JSONOption

    protected def configure : Nil
      DealsGetCommand.add_json_option(self)
      self.argument("id", :required, "deal ID")
    end

    protected def execute(input : ACON::Input::Interface, output : ACON::Output::Interface) : ACON::Command::Status
      id = input.argument("id").to_s
      resp = RightDesk::Client.get("/api/v1/deals/#{URI.encode_path(id)}")
      return RightDesk.fail("deals:get", resp, json?(input)) unless resp.success?

      if json?(input)
        output.puts resp.body
        return ACON::Command::Status::SUCCESS
      end

      d = JSON.parse(resp.body)["deal"]?
      unless d
        output.puts resp.body
        return ACON::Command::Status::SUCCESS
      end

      show = ->(label : String, value : JSON::Any?) {
        v = value.try(&.to_s)
        output.puts "#{label}: #{v}" if v && !v.empty? && v != "null"
      }
      show.call("id", d["id"]?)
      show.call("title", d["title"]?)
      show.call("value", d["value"]?)
      show.call("currency", d["currency"]?)
      show.call("status", d["status"]?)
      show.call("probability", d["probability"]?)
      show.call("stage", d["stage_name"]?)
      show.call("pipeline", d["pipeline_name"]?)
      show.call("owner", d["owner_name"]?)
      show.call("contact", d["contact_name"]?)
      show.call("contact_email", d["contact_email"]?)
      show.call("company", d["company_name"]?)
      show.call("lost_reason", d["lost_reason"]?)
      show.call("customer_id", d["customer_id"]?)
      show.call("partner_id", d["partner_id"]?)
      show.call("expected_close_date", d["expected_close_date"]?)
      ACON::Command::Status::SUCCESS
    rescue ex
      STDERR.puts "deals:get failed: #{ex.message}"
      RightDesk.exit_code = 1
      ACON::Command::Status::FAILURE
    end
  end

  # ----- deals writes -----

  # Build a deal attribute hash from the set --flags (only provided fields).
  # Shared by deals:create and deals:update.
  def self.deal_body(input : ACON::Input::Interface) : Hash(String, String | Int32)
    deal = Hash(String, String | Int32).new
    {
      "title"               => "title",
      "contact-id"          => "contact_id",
      "company-id"          => "company_id",
      "pipeline-id"         => "pipeline_id",
      "stage-id"            => "stage_id",
      "owner-id"            => "owner_id",
      "value"               => "value",
      "currency"            => "currency",
      "expected-close-date" => "expected_close_date",
      "source"              => "source",
      "visible-to"          => "visible_to",
      "referral-partner-id" => "referral_partner_id",
    }.each do |opt, field|
      if v = input.option(opt).to_s.presence
        deal[field] = v
      end
    end
    if (v = input.option("probability").to_s.presence) && (n = v.to_i?)
      deal["probability"] = n
    end
    deal
  end

  # Shared option set for deals:create / deals:update.
  def self.configure_deal_options(cmd : ACON::Command) : Nil
    cmd.option("title", nil, ACON::Input::Option::Value[:required], "Deal title")
    cmd.option("contact-id", nil, ACON::Input::Option::Value[:required], "Contact ID")
    cmd.option("company-id", nil, ACON::Input::Option::Value[:required], "Company ID")
    cmd.option("pipeline-id", nil, ACON::Input::Option::Value[:required], "Pipeline ID")
    cmd.option("stage-id", nil, ACON::Input::Option::Value[:required], "Stage ID")
    cmd.option("owner-id", nil, ACON::Input::Option::Value[:required], "Owner user ID")
    cmd.option("value", nil, ACON::Input::Option::Value[:required], "Deal value")
    cmd.option("currency", nil, ACON::Input::Option::Value[:required], "Currency")
    cmd.option("expected-close-date", nil, ACON::Input::Option::Value[:required], "Expected close date (YYYY-MM-DD)")
    cmd.option("source", nil, ACON::Input::Option::Value[:required], "Source")
    cmd.option("visible-to", nil, ACON::Input::Option::Value[:required], "owner, team, or everyone")
    cmd.option("referral-partner-id", nil, ACON::Input::Option::Value[:required], "Referral partner ID")
    cmd.option("probability", nil, ACON::Input::Option::Value[:required], "Win probability 0-100")
  end

  # Print a created/updated/transitioned deal (tab id\ttitle (status)) or raw JSON under --json.
  def self.print_deal_result(input : ACON::Input::Interface, output : ACON::Output::Interface, resp : Client::Response) : ACON::Command::Status
    if input.option("json", Bool)
      output.puts resp.body
    else
      d = JSON.parse(resp.body)["deal"]?
      if d
        output.puts "#{d["id"]?}\t#{d["title"]?.try(&.as_s?)} (#{d["status"]?.try(&.as_s?)})"
      else
        output.puts resp.body
      end
    end
    ACON::Command::Status::SUCCESS
  end

  @[ACONA::AsCommand("deals:create", description: "Create a deal")]
  class DealsCreateCommand < ACON::Command
    include JSONOption

    protected def configure : Nil
      DealsCreateCommand.add_json_option(self)
      RightDesk.configure_deal_options(self)
    end

    protected def execute(input : ACON::Input::Interface, output : ACON::Output::Interface) : ACON::Command::Status
      deal = RightDesk.deal_body(input)
      unless deal.has_key?("title")
        STDERR.puts "deals:create failed: --title is required"
        RightDesk.exit_code = 2
        return ACON::Command::Status::FAILURE
      end

      resp = RightDesk::Client.post("/api/v1/deals", {"deal" => deal}.to_json)
      return RightDesk.fail("deals:create", resp, json?(input)) unless resp.success?
      RightDesk.print_deal_result(input, output, resp)
    rescue ex
      STDERR.puts "deals:create failed: #{ex.message}"
      RightDesk.exit_code = 1
      ACON::Command::Status::FAILURE
    end
  end

  @[ACONA::AsCommand("deals:update", description: "Update a deal by ID")]
  class DealsUpdateCommand < ACON::Command
    include JSONOption

    protected def configure : Nil
      DealsUpdateCommand.add_json_option(self)
      self.argument("id", :required, "deal ID")
      RightDesk.configure_deal_options(self)
    end

    protected def execute(input : ACON::Input::Interface, output : ACON::Output::Interface) : ACON::Command::Status
      id = input.argument("id").to_s
      deal = RightDesk.deal_body(input)
      if deal.empty?
        STDERR.puts "deals:update failed: provide at least one field to update"
        RightDesk.exit_code = 2
        return ACON::Command::Status::FAILURE
      end

      resp = RightDesk::Client.patch("/api/v1/deals/#{URI.encode_path(id)}", {"deal" => deal}.to_json)
      return RightDesk.fail("deals:update", resp, json?(input)) unless resp.success?
      RightDesk.print_deal_result(input, output, resp)
    rescue ex
      STDERR.puts "deals:update failed: #{ex.message}"
      RightDesk.exit_code = 1
      ACON::Command::Status::FAILURE
    end
  end

  @[ACONA::AsCommand("deals:move", description: "Move a deal to a stage")]
  class DealsMoveCommand < ACON::Command
    include JSONOption

    protected def configure : Nil
      DealsMoveCommand.add_json_option(self)
      self.argument("id", :required, "deal ID")
      self.option("stage", nil, ACON::Input::Option::Value[:required], "Target stage ID (required)")
    end

    protected def execute(input : ACON::Input::Interface, output : ACON::Output::Interface) : ACON::Command::Status
      id = input.argument("id").to_s
      stage = input.option("stage").to_s.presence
      unless stage
        STDERR.puts "deals:move failed: --stage ID is required"
        RightDesk.exit_code = 2
        return ACON::Command::Status::FAILURE
      end

      resp = RightDesk::Client.patch("/api/v1/deals/#{URI.encode_path(id)}/move", {"stage_id" => stage}.to_json)
      return RightDesk.fail("deals:move", resp, json?(input)) unless resp.success?
      RightDesk.print_deal_result(input, output, resp)
    rescue ex
      STDERR.puts "deals:move failed: #{ex.message}"
      RightDesk.exit_code = 1
      ACON::Command::Status::FAILURE
    end
  end

  @[ACONA::AsCommand("deals:won", description: "Mark a deal won")]
  class DealsWonCommand < ACON::Command
    include JSONOption

    protected def configure : Nil
      DealsWonCommand.add_json_option(self)
      self.argument("id", :required, "deal ID")
    end

    protected def execute(input : ACON::Input::Interface, output : ACON::Output::Interface) : ACON::Command::Status
      id = input.argument("id").to_s
      resp = RightDesk::Client.patch("/api/v1/deals/#{URI.encode_path(id)}/won")
      return RightDesk.fail("deals:won", resp, json?(input)) unless resp.success?
      RightDesk.print_deal_result(input, output, resp)
    rescue ex
      STDERR.puts "deals:won failed: #{ex.message}"
      RightDesk.exit_code = 1
      ACON::Command::Status::FAILURE
    end
  end

  @[ACONA::AsCommand("deals:lost", description: "Mark a deal lost")]
  class DealsLostCommand < ACON::Command
    include JSONOption

    protected def configure : Nil
      DealsLostCommand.add_json_option(self)
      self.argument("id", :required, "deal ID")
      self.option("reason", nil, ACON::Input::Option::Value[:required], "Lost reason")
    end

    protected def execute(input : ACON::Input::Interface, output : ACON::Output::Interface) : ACON::Command::Status
      id = input.argument("id").to_s
      body = Hash(String, String).new
      if reason = input.option("reason").to_s.presence
        body["reason"] = reason
      end
      resp = RightDesk::Client.patch("/api/v1/deals/#{URI.encode_path(id)}/lost", body.to_json)
      return RightDesk.fail("deals:lost", resp, json?(input)) unless resp.success?
      RightDesk.print_deal_result(input, output, resp)
    rescue ex
      STDERR.puts "deals:lost failed: #{ex.message}"
      RightDesk.exit_code = 1
      ACON::Command::Status::FAILURE
    end
  end

  @[ACONA::AsCommand("deals:reopen", description: "Reopen a won/lost deal")]
  class DealsReopenCommand < ACON::Command
    include JSONOption

    protected def configure : Nil
      DealsReopenCommand.add_json_option(self)
      self.argument("id", :required, "deal ID")
    end

    protected def execute(input : ACON::Input::Interface, output : ACON::Output::Interface) : ACON::Command::Status
      id = input.argument("id").to_s
      resp = RightDesk::Client.patch("/api/v1/deals/#{URI.encode_path(id)}/reopen")
      return RightDesk.fail("deals:reopen", resp, json?(input)) unless resp.success?
      RightDesk.print_deal_result(input, output, resp)
    rescue ex
      STDERR.puts "deals:reopen failed: #{ex.message}"
      RightDesk.exit_code = 1
      ACON::Command::Status::FAILURE
    end
  end

  @[ACONA::AsCommand("deals:convert", description: "Convert a deal to a customer or partner (requires --yes)")]
  class DealsConvertCommand < ACON::Command
    include JSONOption

    protected def configure : Nil
      DealsConvertCommand.add_json_option(self)
      self.argument("id", :required, "deal ID")
      self.option("to", nil, ACON::Input::Option::Value[:required], "Target: customer or partner (required)")
      self.option("yes", "y", ACON::Input::Option::Value[:none], "Confirm conversion (required)")
    end

    protected def execute(input : ACON::Input::Interface, output : ACON::Output::Interface) : ACON::Command::Status
      id = input.argument("id").to_s
      target = input.option("to").to_s.presence
      unless target
        STDERR.puts "deals:convert failed: --to customer|partner is required"
        RightDesk.exit_code = 2
        return ACON::Command::Status::FAILURE
      end
      unless input.option("yes", Bool)
        STDERR.puts "deals:convert failed: refusing to convert without --yes"
        RightDesk.exit_code = 2
        return ACON::Command::Status::FAILURE
      end

      resp = RightDesk::Client.post("/api/v1/deals/#{URI.encode_path(id)}/convert", {"to" => target}.to_json)
      return RightDesk.fail("deals:convert", resp, json?(input)) unless resp.success?

      if json?(input)
        output.puts resp.body
      else
        parsed = JSON.parse(resp.body)
        record = parsed[target]?
        if record
          output.puts "#{target} #{record["id"]?}\t#{record["title"]?.try(&.as_s?)}"
        else
          output.puts resp.body
        end
      end
      ACON::Command::Status::SUCCESS
    rescue ex
      STDERR.puts "deals:convert failed: #{ex.message}"
      RightDesk.exit_code = 1
      ACON::Command::Status::FAILURE
    end
  end

  @[ACONA::AsCommand("deals:merge", description: "Merge a duplicate deal into a primary (requires --yes)")]
  class DealsMergeCommand < ACON::Command
    include JSONOption

    protected def configure : Nil
      DealsMergeCommand.add_json_option(self)
      self.argument("id", :required, "primary (surviving) deal ID")
      self.option("duplicate", nil, ACON::Input::Option::Value[:required], "duplicate deal ID to absorb (required)")
      self.option("yes", "y", ACON::Input::Option::Value[:none], "Confirm merge (required)")
    end

    protected def execute(input : ACON::Input::Interface, output : ACON::Output::Interface) : ACON::Command::Status
      id = input.argument("id").to_s
      duplicate = input.option("duplicate").to_s.presence
      unless duplicate
        STDERR.puts "deals:merge failed: --duplicate ID is required"
        RightDesk.exit_code = 2
        return ACON::Command::Status::FAILURE
      end
      unless input.option("yes", Bool)
        STDERR.puts "deals:merge failed: refusing to merge without --yes"
        RightDesk.exit_code = 2
        return ACON::Command::Status::FAILURE
      end

      resp = RightDesk::Client.post("/api/v1/deals/#{URI.encode_path(id)}/merge", {"duplicate_id" => duplicate}.to_json)
      return RightDesk.fail("deals:merge", resp, json?(input)) unless resp.success?
      RightDesk.print_deal_result(input, output, resp)
    rescue ex
      STDERR.puts "deals:merge failed: #{ex.message}"
      RightDesk.exit_code = 1
      ACON::Command::Status::FAILURE
    end
  end

  # ----- deal sub-resources: notes / checklists / events -----

  def self.note_line(n : JSON::Any) : String
    pin = n["pinned"]?.try(&.as_bool?) ? "📌" : "·"
    content = (n["content"]?.try(&.as_s?) || "").split("\n").first? || ""
    author = n["user_name"]?.try(&.as_s?) || ""
    line = "#{n["id"]?}\t#{pin} #{content}"
    line += "\t(#{author})" unless author.empty?
    line
  end

  def self.print_note_result(input : ACON::Input::Interface, output : ACON::Output::Interface, resp : Client::Response) : ACON::Command::Status
    if input.option("json", Bool)
      output.puts resp.body
    else
      n = JSON.parse(resp.body)["note"]?
      output.puts(n ? note_line(n) : resp.body)
    end
    ACON::Command::Status::SUCCESS
  end

  def self.print_checklist(output : ACON::Output::Interface, c : JSON::Any) : Nil
    name = c["template_name"]?.try(&.as_s?) || "checklist"
    output.puts "#{c["id"]?}\t#{name} — #{c["completed_count"]?}/#{c["total_count"]?} (#{c["progress_percent"]?}%)"
    (c["items"]?.try(&.as_a?) || [] of JSON::Any).each do |item|
      mark = item["completed"]?.try(&.as_bool?) ? "✓" : "○"
      output.puts "  #{mark} [#{item["id"]?}] #{item["label"]?.try(&.as_s?)}"
    end
  end

  def self.print_checklist_result(input : ACON::Input::Interface, output : ACON::Output::Interface, resp : Client::Response) : ACON::Command::Status
    if input.option("json", Bool)
      output.puts resp.body
    else
      c = JSON.parse(resp.body)["checklist"]?
      c ? print_checklist(output, c) : output.puts(resp.body)
    end
    ACON::Command::Status::SUCCESS
  end

  # Shared page/limit query builder for the sub-resource list commands.
  def self.page_params(input : ACON::Input::Interface) : String
    URI::Params.build do |form|
      if p = input.option("page").to_s.presence
        form.add("page", p)
      end
      if l = input.option("limit").to_s.presence
        form.add("per_page", l)
      end
    end
  end

  @[ACONA::AsCommand("deals:notes", description: "List a deal's notes (pinned first)")]
  class DealsNotesCommand < ACON::Command
    include JSONOption

    protected def configure : Nil
      DealsNotesCommand.add_json_option(self)
      self.argument("id", :required, "deal ID")
      self.option("page", nil, ACON::Input::Option::Value[:required], "Page number (default 1)")
      self.option("limit", nil, ACON::Input::Option::Value[:required], "Results per page (max 100)")
    end

    protected def execute(input : ACON::Input::Interface, output : ACON::Output::Interface) : ACON::Command::Status
      id = input.argument("id").to_s
      resp = RightDesk::Client.get("/api/v1/deals/#{URI.encode_path(id)}/notes", RightDesk.page_params(input))
      return RightDesk.fail("deals:notes", resp, json?(input)) unless resp.success?

      if json?(input)
        output.puts resp.body
        return ACON::Command::Status::SUCCESS
      end
      parsed = JSON.parse(resp.body)
      (parsed["notes"]?.try(&.as_a?) || [] of JSON::Any).each { |n| output.puts RightDesk.note_line(n) }
      ACON::Command::Status::SUCCESS
    rescue ex
      STDERR.puts "deals:notes failed: #{ex.message}"
      RightDesk.exit_code = 1
      ACON::Command::Status::FAILURE
    end
  end

  @[ACONA::AsCommand("deals:note-add", description: "Add a note to a deal")]
  class DealsNoteAddCommand < ACON::Command
    include JSONOption

    protected def configure : Nil
      DealsNoteAddCommand.add_json_option(self)
      self.argument("id", :required, "deal ID")
      self.option("body", nil, ACON::Input::Option::Value[:required], "Note body (required)")
      self.option("pin", nil, ACON::Input::Option::Value[:none], "Pin the note to the top")
      self.option("external-id", nil, ACON::Input::Option::Value[:required], "External record ID (idempotency key)")
    end

    protected def execute(input : ACON::Input::Interface, output : ACON::Output::Interface) : ACON::Command::Status
      id = input.argument("id").to_s
      content = input.option("body").to_s.presence
      return RightDesk.usage_fail("deals:note-add", "--body is required") unless content

      note = Hash(String, String | Bool).new
      note["content"] = content
      note["pinned"] = true if input.option("pin", Bool)
      if ext = input.option("external-id").to_s.presence
        note["external_record_id"] = ext
      end

      resp = RightDesk::Client.post("/api/v1/deals/#{URI.encode_path(id)}/notes", {"note" => note}.to_json)
      return RightDesk.fail("deals:note-add", resp, json?(input)) unless resp.success?
      RightDesk.print_note_result(input, output, resp)
    rescue ex
      STDERR.puts "deals:note-add failed: #{ex.message}"
      RightDesk.exit_code = 1
      ACON::Command::Status::FAILURE
    end
  end

  @[ACONA::AsCommand("deals:note-edit", description: "Edit a note's body and/or pin state")]
  class DealsNoteEditCommand < ACON::Command
    include JSONOption

    protected def configure : Nil
      DealsNoteEditCommand.add_json_option(self)
      self.argument("id", :required, "note ID")
      self.option("body", nil, ACON::Input::Option::Value[:required], "New note body")
      self.option("pin", nil, ACON::Input::Option::Value[:none], "Pin the note")
      self.option("unpin", nil, ACON::Input::Option::Value[:none], "Unpin the note")
    end

    protected def execute(input : ACON::Input::Interface, output : ACON::Output::Interface) : ACON::Command::Status
      id = input.argument("id").to_s
      note = Hash(String, String | Bool).new
      if body = input.option("body").to_s.presence
        note["content"] = body
      end
      unless (pin = RightDesk.flag_pair(input, "pin", "unpin")).nil?
        note["pinned"] = pin
      end
      return RightDesk.usage_fail("deals:note-edit", "provide --body and/or --pin/--unpin") if note.empty?

      resp = RightDesk::Client.patch("/api/v1/notes/#{URI.encode_path(id)}", {"note" => note}.to_json)
      return RightDesk.fail("deals:note-edit", resp, json?(input)) unless resp.success?
      RightDesk.print_note_result(input, output, resp)
    rescue ex : UsageError
      RightDesk.usage_fail("deals:note-edit", ex.message.to_s)
    rescue ex
      STDERR.puts "deals:note-edit failed: #{ex.message}"
      RightDesk.exit_code = 1
      ACON::Command::Status::FAILURE
    end
  end

  @[ACONA::AsCommand("deals:note-delete", description: "Delete a note by ID (requires --yes)")]
  class DealsNoteDeleteCommand < ACON::Command
    include JSONOption

    protected def configure : Nil
      DealsNoteDeleteCommand.add_json_option(self)
      self.argument("id", :required, "note ID")
      self.option("yes", "y", ACON::Input::Option::Value[:none], "Confirm deletion (required)")
    end

    protected def execute(input : ACON::Input::Interface, output : ACON::Output::Interface) : ACON::Command::Status
      id = input.argument("id").to_s
      return RightDesk.usage_fail("deals:note-delete", "refusing to delete without --yes") unless input.option("yes", Bool)

      resp = RightDesk::Client.delete("/api/v1/notes/#{URI.encode_path(id)}")
      return RightDesk.fail("deals:note-delete", resp, json?(input)) unless resp.success?
      if json?(input)
        output.puts({"id" => id, "deleted" => true}.to_json)
      else
        output.puts "deleted note #{id}"
      end
      ACON::Command::Status::SUCCESS
    rescue ex
      STDERR.puts "deals:note-delete failed: #{ex.message}"
      RightDesk.exit_code = 1
      ACON::Command::Status::FAILURE
    end
  end

  @[ACONA::AsCommand("deals:checklist-templates", description: "List available checklist templates")]
  class DealsChecklistTemplatesCommand < ACON::Command
    include JSONOption

    protected def configure : Nil
      DealsChecklistTemplatesCommand.add_json_option(self)
      self.option("page", nil, ACON::Input::Option::Value[:required], "Page number (default 1)")
      self.option("limit", nil, ACON::Input::Option::Value[:required], "Results per page (max 100)")
    end

    protected def execute(input : ACON::Input::Interface, output : ACON::Output::Interface) : ACON::Command::Status
      resp = RightDesk::Client.get("/api/v1/checklist_templates", RightDesk.page_params(input))
      return RightDesk.fail("deals:checklist-templates", resp, json?(input)) unless resp.success?

      if json?(input)
        output.puts resp.body
        return ACON::Command::Status::SUCCESS
      end
      (JSON.parse(resp.body)["checklist_templates"]?.try(&.as_a?) || [] of JSON::Any).each do |t|
        count = t["items"]?.try(&.as_a?.try(&.size)) || 0
        output.puts "#{t["id"]?}\t#{t["name"]?.try(&.as_s?)} (#{count} items)"
      end
      ACON::Command::Status::SUCCESS
    rescue ex
      STDERR.puts "deals:checklist-templates failed: #{ex.message}"
      RightDesk.exit_code = 1
      ACON::Command::Status::FAILURE
    end
  end

  @[ACONA::AsCommand("deals:checklists", description: "List a deal's checklists and items")]
  class DealsChecklistsCommand < ACON::Command
    include JSONOption

    protected def configure : Nil
      DealsChecklistsCommand.add_json_option(self)
      self.argument("id", :required, "deal ID")
    end

    protected def execute(input : ACON::Input::Interface, output : ACON::Output::Interface) : ACON::Command::Status
      id = input.argument("id").to_s
      resp = RightDesk::Client.get("/api/v1/deals/#{URI.encode_path(id)}/checklists")
      return RightDesk.fail("deals:checklists", resp, json?(input)) unless resp.success?

      if json?(input)
        output.puts resp.body
        return ACON::Command::Status::SUCCESS
      end
      (JSON.parse(resp.body)["checklists"]?.try(&.as_a?) || [] of JSON::Any).each { |c| RightDesk.print_checklist(output, c) }
      ACON::Command::Status::SUCCESS
    rescue ex
      STDERR.puts "deals:checklists failed: #{ex.message}"
      RightDesk.exit_code = 1
      ACON::Command::Status::FAILURE
    end
  end

  @[ACONA::AsCommand("deals:checklist-add", description: "Apply a checklist template to a deal")]
  class DealsChecklistAddCommand < ACON::Command
    include JSONOption

    protected def configure : Nil
      DealsChecklistAddCommand.add_json_option(self)
      self.argument("id", :required, "deal ID")
      self.option("template", nil, ACON::Input::Option::Value[:required], "Checklist template ID (required)")
    end

    protected def execute(input : ACON::Input::Interface, output : ACON::Output::Interface) : ACON::Command::Status
      id = input.argument("id").to_s
      template = input.option("template").to_s.presence
      return RightDesk.usage_fail("deals:checklist-add", "--template ID is required") unless template

      resp = RightDesk::Client.post("/api/v1/deals/#{URI.encode_path(id)}/checklists", {"checklist_template_id" => template}.to_json)
      return RightDesk.fail("deals:checklist-add", resp, json?(input)) unless resp.success?
      RightDesk.print_checklist_result(input, output, resp)
    rescue ex
      STDERR.puts "deals:checklist-add failed: #{ex.message}"
      RightDesk.exit_code = 1
      ACON::Command::Status::FAILURE
    end
  end

  @[ACONA::AsCommand("deals:checklist-remove", description: "Remove a checklist from a deal (requires --yes)")]
  class DealsChecklistRemoveCommand < ACON::Command
    include JSONOption

    protected def configure : Nil
      DealsChecklistRemoveCommand.add_json_option(self)
      self.argument("id", :required, "deal checklist ID")
      self.option("yes", "y", ACON::Input::Option::Value[:none], "Confirm removal (required)")
    end

    protected def execute(input : ACON::Input::Interface, output : ACON::Output::Interface) : ACON::Command::Status
      id = input.argument("id").to_s
      return RightDesk.usage_fail("deals:checklist-remove", "refusing to remove without --yes") unless input.option("yes", Bool)

      resp = RightDesk::Client.delete("/api/v1/deal_checklists/#{URI.encode_path(id)}")
      return RightDesk.fail("deals:checklist-remove", resp, json?(input)) unless resp.success?
      if json?(input)
        output.puts({"id" => id, "removed" => true}.to_json)
      else
        output.puts "removed checklist #{id}"
      end
      ACON::Command::Status::SUCCESS
    rescue ex
      STDERR.puts "deals:checklist-remove failed: #{ex.message}"
      RightDesk.exit_code = 1
      ACON::Command::Status::FAILURE
    end
  end

  @[ACONA::AsCommand("deals:checklist-check", description: "Mark a checklist item done")]
  class DealsChecklistCheckCommand < ACON::Command
    include JSONOption

    protected def configure : Nil
      DealsChecklistCheckCommand.add_json_option(self)
      self.argument("id", :required, "checklist item ID")
    end

    protected def execute(input : ACON::Input::Interface, output : ACON::Output::Interface) : ACON::Command::Status
      id = input.argument("id").to_s
      resp = RightDesk::Client.patch("/api/v1/deal_checklist_items/#{URI.encode_path(id)}", {"completed" => true}.to_json)
      return RightDesk.fail("deals:checklist-check", resp, json?(input)) unless resp.success?
      RightDesk.print_checklist_result(input, output, resp)
    rescue ex
      STDERR.puts "deals:checklist-check failed: #{ex.message}"
      RightDesk.exit_code = 1
      ACON::Command::Status::FAILURE
    end
  end

  @[ACONA::AsCommand("deals:checklist-uncheck", description: "Mark a checklist item not done")]
  class DealsChecklistUncheckCommand < ACON::Command
    include JSONOption

    protected def configure : Nil
      DealsChecklistUncheckCommand.add_json_option(self)
      self.argument("id", :required, "checklist item ID")
    end

    protected def execute(input : ACON::Input::Interface, output : ACON::Output::Interface) : ACON::Command::Status
      id = input.argument("id").to_s
      resp = RightDesk::Client.patch("/api/v1/deal_checklist_items/#{URI.encode_path(id)}", {"completed" => false}.to_json)
      return RightDesk.fail("deals:checklist-uncheck", resp, json?(input)) unless resp.success?
      RightDesk.print_checklist_result(input, output, resp)
    rescue ex
      STDERR.puts "deals:checklist-uncheck failed: #{ex.message}"
      RightDesk.exit_code = 1
      ACON::Command::Status::FAILURE
    end
  end

  @[ACONA::AsCommand("deals:events", description: "List a deal's events (history)")]
  class DealsEventsCommand < ACON::Command
    include JSONOption

    protected def configure : Nil
      DealsEventsCommand.add_json_option(self)
      self.argument("id", :required, "deal ID")
      self.option("type", nil, ACON::Input::Option::Value[:required], "Filter by event type")
      self.option("page", nil, ACON::Input::Option::Value[:required], "Page number (default 1)")
      self.option("limit", nil, ACON::Input::Option::Value[:required], "Results per page (max 100)")
    end

    protected def execute(input : ACON::Input::Interface, output : ACON::Output::Interface) : ACON::Command::Status
      id = input.argument("id").to_s
      params = URI::Params.build do |form|
        if t = input.option("type").to_s.presence
          form.add("event_type", t)
        end
        if p = input.option("page").to_s.presence
          form.add("page", p)
        end
        if l = input.option("limit").to_s.presence
          form.add("per_page", l)
        end
      end

      resp = RightDesk::Client.get("/api/v1/deals/#{URI.encode_path(id)}/events", params)
      return RightDesk.fail("deals:events", resp, json?(input)) unless resp.success?

      if json?(input)
        output.puts resp.body
        return ACON::Command::Status::SUCCESS
      end
      (JSON.parse(resp.body)["events"]?.try(&.as_a?) || [] of JSON::Any).each do |e|
        at = e["occurred_at"]?.try(&.as_s?) || ""
        type = e["event_type"]?.try(&.as_s?) || "?"
        desc = e["description"]?.try(&.as_s?) || ""
        line = "#{at}\t#{type}"
        line += "\t#{desc}" unless desc.empty?
        output.puts line
      end
      ACON::Command::Status::SUCCESS
    rescue ex
      STDERR.puts "deals:events failed: #{ex.message}"
      RightDesk.exit_code = 1
      ACON::Command::Status::FAILURE
    end
  end

  @[ACONA::AsCommand("deals:event-add", description: "Log an event on a deal")]
  class DealsEventAddCommand < ACON::Command
    include JSONOption

    protected def configure : Nil
      DealsEventAddCommand.add_json_option(self)
      self.argument("id", :required, "deal ID")
      self.option("type", nil, ACON::Input::Option::Value[:required], "Event type (required)")
      self.option("description", nil, ACON::Input::Option::Value[:required], "Event description")
    end

    protected def execute(input : ACON::Input::Interface, output : ACON::Output::Interface) : ACON::Command::Status
      id = input.argument("id").to_s
      type = input.option("type").to_s.presence
      return RightDesk.usage_fail("deals:event-add", "--type is required") unless type

      event = Hash(String, String).new
      event["event_type"] = type
      if desc = input.option("description").to_s.presence
        event["description"] = desc
      end

      resp = RightDesk::Client.post("/api/v1/deals/#{URI.encode_path(id)}/events", {"event" => event}.to_json)
      return RightDesk.fail("deals:event-add", resp, json?(input)) unless resp.success?
      if json?(input)
        output.puts resp.body
      else
        e = JSON.parse(resp.body)["event"]?
        output.puts(e ? "#{e["id"]?}\t#{e["event_type"]?.try(&.as_s?)}" : resp.body)
      end
      ACON::Command::Status::SUCCESS
    rescue ex
      STDERR.puts "deals:event-add failed: #{ex.message}"
      RightDesk.exit_code = 1
      ACON::Command::Status::FAILURE
    end
  end
end

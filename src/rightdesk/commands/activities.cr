require "athena-console"
require "json"
require "uri"
require "../client"

module RightDesk
  @[ACONA::AsCommand("activities:list", description: "List activities (by due date)")]
  class ActivitiesListCommand < ACON::Command
    include JSONOption

    protected def configure : Nil
      ActivitiesListCommand.add_json_option(self)
      self
        .option("done", nil, ACON::Input::Option::Value[:required], "Filter by done state: true or false")
        .option("type", nil, ACON::Input::Option::Value[:required], "Filter by activity type")
        .option("assigned-to", nil, ACON::Input::Option::Value[:required], "Filter by assignee user ID")
        .option("deal", nil, ACON::Input::Option::Value[:required], "Filter by deal ID")
        .option("lead", nil, ACON::Input::Option::Value[:required], "Filter by lead ID")
        .option("contact", nil, ACON::Input::Option::Value[:required], "Filter by contact ID")
        .option("company", nil, ACON::Input::Option::Value[:required], "Filter by company ID")
        .option("customer", nil, ACON::Input::Option::Value[:required], "Filter by customer ID")
        .option("partner", nil, ACON::Input::Option::Value[:required], "Filter by partner ID")
        .option("due-before", nil, ACON::Input::Option::Value[:required], "Due before date (YYYY-MM-DD)")
        .option("due-after", nil, ACON::Input::Option::Value[:required], "Due after date (YYYY-MM-DD)")
        .option("page", nil, ACON::Input::Option::Value[:required], "Page number (default 1)")
        .option("limit", nil, ACON::Input::Option::Value[:required], "Results per page (max 100)")
    end

    protected def execute(input : ACON::Input::Interface, output : ACON::Output::Interface) : ACON::Command::Status
      params = URI::Params.build do |form|
        {
          "done"        => "done",
          "type"        => "activity_type",
          "assigned-to" => "assigned_to_id",
          "deal"        => "deal_id",
          "lead"        => "lead_id",
          "contact"     => "contact_id",
          "company"     => "company_id",
          "customer"    => "customer_id",
          "partner"     => "partner_id",
          "due-before"  => "due_before",
          "due-after"   => "due_after",
        }.each do |opt, param|
          if v = input.option(opt).to_s.presence
            form.add(param, v)
          end
        end
        if p = input.option("page").to_s.presence
          form.add("page", p)
        end
        if l = input.option("limit").to_s.presence
          form.add("per_page", l)
        end
      end

      resp = RightDesk::Client.get("/api/v1/activities", params)
      return RightDesk.fail("activities:list", resp, json?(input)) unless resp.success?

      if json?(input)
        output.puts resp.body
        return ACON::Command::Status::SUCCESS
      end

      parsed = JSON.parse(resp.body)
      (parsed["activities"]?.try(&.as_a?) || [] of JSON::Any).each do |a|
        id = a["id"]?.try(&.to_s) || "?"
        subject = a["subject"]?.try(&.as_s?) || "—"
        type = a["activity_type"]?.try(&.as_s?) || ""
        mark = a["done"]?.try(&.as_bool?) ? "✓" : "○"
        link = a["primary_link_name"]?.try(&.as_s?) || ""
        line = "#{id}\t#{mark} #{subject} (#{type})"
        line += "\t→ #{link}" unless link.empty?
        output.puts line
      end

      if meta = parsed["meta"]?
        output.puts ""
        output.puts "#{meta["total_count"]?} activities — page #{meta["current_page"]?}/#{meta["total_pages"]?}"
      end
      ACON::Command::Status::SUCCESS
    rescue ex
      STDERR.puts "activities:list failed: #{ex.message}"
      RightDesk.exit_code = 1
      ACON::Command::Status::FAILURE
    end
  end

  @[ACONA::AsCommand("activities:get", description: "Show a single activity by ID")]
  class ActivitiesGetCommand < ACON::Command
    include JSONOption

    protected def configure : Nil
      ActivitiesGetCommand.add_json_option(self)
      self.argument("id", :required, "activity ID")
    end

    protected def execute(input : ACON::Input::Interface, output : ACON::Output::Interface) : ACON::Command::Status
      id = input.argument("id").to_s
      resp = RightDesk::Client.get("/api/v1/activities/#{URI.encode_path(id)}")
      return RightDesk.fail("activities:get", resp, json?(input)) unless resp.success?

      if json?(input)
        output.puts resp.body
        return ACON::Command::Status::SUCCESS
      end

      a = JSON.parse(resp.body)["activity"]?
      unless a
        output.puts resp.body
        return ACON::Command::Status::SUCCESS
      end
      show = ->(label : String, value : JSON::Any?) {
        v = value.try(&.to_s)
        output.puts "#{label}: #{v}" if v && !v.empty? && v != "null"
      }
      show.call("id", a["id"]?)
      show.call("subject", a["subject"]?)
      show.call("type", a["activity_type"]?)
      show.call("done", a["done"]?)
      show.call("due_date", a["due_date"]?)
      show.call("overdue", a["overdue"]?)
      show.call("duration_minutes", a["duration_minutes"]?)
      show.call("logged_minutes", a["total_logged_minutes"]?)
      show.call("assigned_to", a["assigned_to_name"]?)
      show.call("linked_to", a["primary_link_type"]?)
      show.call("linked_name", a["primary_link_name"]?)
      show.call("description", a["description"]?)
      ACON::Command::Status::SUCCESS
    rescue ex
      STDERR.puts "activities:get failed: #{ex.message}"
      RightDesk.exit_code = 1
      ACON::Command::Status::FAILURE
    end
  end

  # ----- activities writes -----

  # Build an activity attribute hash from the set --flags (only provided fields).
  # Shared by activities:create and activities:update. Checklist items and blockers
  # are managed via their own verbs, not here.
  def self.activity_body(input : ACON::Input::Interface) : Hash(String, String | Int32 | Bool)
    body = Hash(String, String | Int32 | Bool).new
    {
      "subject"           => "subject",
      "type"              => "activity_type",
      "description"       => "description",
      "location"          => "location",
      "due-date"          => "due_date",
      "chargeable-status" => "chargeable_status",
      "assigned-to"       => "assigned_to_id",
      "external-id"       => "external_record_id",
      "pattern"           => "recurrence_pattern",
      "recurrence-end"    => "recurrence_end_date",
      "deal"              => "deal_id",
      "lead"              => "lead_id",
      "contact"           => "contact_id",
      "company"           => "company_id",
      "customer"          => "customer_id",
      "partner"           => "partner_id",
    }.each do |opt, field|
      if v = input.option(opt).to_s.presence
        body[field] = v
      end
    end
    if (v = input.option("duration").to_s.presence) && (n = v.to_i?)
      body["duration_minutes"] = n
    end
    if (v = input.option("interval").to_s.presence) && (n = v.to_i?)
      body["recurrence_interval"] = n
    end
    body["has_time"] = true if input.option("has-time", Bool)
    body["is_recurring"] = true if input.option("recurring", Bool)
    body
  end

  # Shared option set for activities:create / activities:update.
  def self.configure_activity_options(cmd : ACON::Command) : Nil
    cmd.option("subject", nil, ACON::Input::Option::Value[:required], "Activity subject")
    cmd.option("type", nil, ACON::Input::Option::Value[:required], "Activity type (call/meeting/email/task/deadline or org-custom)")
    cmd.option("description", nil, ACON::Input::Option::Value[:required], "Description / notes")
    cmd.option("location", nil, ACON::Input::Option::Value[:required], "Location or link")
    cmd.option("due-date", nil, ACON::Input::Option::Value[:required], "Due date (YYYY-MM-DD or ISO8601)")
    cmd.option("has-time", nil, ACON::Input::Option::Value[:none], "Treat --due-date as carrying a time-of-day")
    cmd.option("duration", nil, ACON::Input::Option::Value[:required], "Planned duration in minutes")
    cmd.option("chargeable-status", nil, ACON::Input::Option::Value[:required], "standard, chargeable, or charged")
    cmd.option("assigned-to", nil, ACON::Input::Option::Value[:required], "Assignee user ID")
    cmd.option("external-id", nil, ACON::Input::Option::Value[:required], "External record ID (idempotency key)")
    cmd.option("recurring", nil, ACON::Input::Option::Value[:none], "Mark as recurring (needs --pattern and --due-date)")
    cmd.option("pattern", nil, ACON::Input::Option::Value[:required], "Recurrence pattern: daily/weekly/monthly/yearly")
    cmd.option("interval", nil, ACON::Input::Option::Value[:required], "Recurrence interval (>0)")
    cmd.option("recurrence-end", nil, ACON::Input::Option::Value[:required], "Recurrence end date (YYYY-MM-DD)")
    cmd.option("deal", nil, ACON::Input::Option::Value[:required], "Link to deal ID")
    cmd.option("lead", nil, ACON::Input::Option::Value[:required], "Link to lead ID")
    cmd.option("contact", nil, ACON::Input::Option::Value[:required], "Link to contact ID")
    cmd.option("company", nil, ACON::Input::Option::Value[:required], "Link to company ID")
    cmd.option("customer", nil, ACON::Input::Option::Value[:required], "Link to customer ID")
    cmd.option("partner", nil, ACON::Input::Option::Value[:required], "Link to partner ID")
  end

  # Print a created/updated/transitioned activity (tab id\t✓|○ subject (type)) or raw JSON under --json.
  def self.print_activity_result(input : ACON::Input::Interface, output : ACON::Output::Interface, resp : Client::Response) : ACON::Command::Status
    if input.option("json", Bool)
      output.puts resp.body
    else
      a = JSON.parse(resp.body)["activity"]?
      if a
        mark = a["done"]?.try(&.as_bool?) ? "✓" : "○"
        output.puts "#{a["id"]?}\t#{mark} #{a["subject"]?.try(&.as_s?)} (#{a["activity_type"]?.try(&.as_s?)})"
      else
        output.puts resp.body
      end
    end
    ACON::Command::Status::SUCCESS
  end

  # Compact one-line summary of an activity_event's event_data.
  def self.summarize_event_data(data : JSON::Any?) : String
    return "" unless data
    h = data.as_h?
    return "" unless h && !h.empty?
    h.map do |k, v|
      if (o = v.as_h?) && o.has_key?("from") && o.has_key?("to")
        "#{k}: #{o["from"]} → #{o["to"]}"
      else
        "#{k}=#{v}"
      end
    end.join(", ")
  end

  @[ACONA::AsCommand("activities:create", description: "Create an activity")]
  class ActivitiesCreateCommand < ACON::Command
    include JSONOption

    protected def configure : Nil
      ActivitiesCreateCommand.add_json_option(self)
      RightDesk.configure_activity_options(self)
    end

    protected def execute(input : ACON::Input::Interface, output : ACON::Output::Interface) : ACON::Command::Status
      body = RightDesk.activity_body(input)
      unless body.has_key?("subject") && body.has_key?("activity_type")
        STDERR.puts "activities:create failed: --subject and --type are required"
        RightDesk.exit_code = 2
        return ACON::Command::Status::FAILURE
      end

      resp = RightDesk::Client.post("/api/v1/activities", {"activity" => body}.to_json)
      return RightDesk.fail("activities:create", resp, json?(input)) unless resp.success?
      RightDesk.print_activity_result(input, output, resp)
    rescue ex
      STDERR.puts "activities:create failed: #{ex.message}"
      RightDesk.exit_code = 1
      ACON::Command::Status::FAILURE
    end
  end

  @[ACONA::AsCommand("activities:update", description: "Update an activity by ID")]
  class ActivitiesUpdateCommand < ACON::Command
    include JSONOption

    protected def configure : Nil
      ActivitiesUpdateCommand.add_json_option(self)
      self.argument("id", :required, "activity ID")
      RightDesk.configure_activity_options(self)
    end

    protected def execute(input : ACON::Input::Interface, output : ACON::Output::Interface) : ACON::Command::Status
      id = input.argument("id").to_s
      body = RightDesk.activity_body(input)
      if body.empty?
        STDERR.puts "activities:update failed: provide at least one field to update"
        RightDesk.exit_code = 2
        return ACON::Command::Status::FAILURE
      end

      resp = RightDesk::Client.patch("/api/v1/activities/#{URI.encode_path(id)}", {"activity" => body}.to_json)
      return RightDesk.fail("activities:update", resp, json?(input)) unless resp.success?
      RightDesk.print_activity_result(input, output, resp)
    rescue ex
      STDERR.puts "activities:update failed: #{ex.message}"
      RightDesk.exit_code = 1
      ACON::Command::Status::FAILURE
    end
  end

  @[ACONA::AsCommand("activities:delete", description: "Delete an activity by ID (requires --yes)")]
  class ActivitiesDeleteCommand < ACON::Command
    include JSONOption

    protected def configure : Nil
      ActivitiesDeleteCommand.add_json_option(self)
      self.argument("id", :required, "activity ID")
      self.option("yes", "y", ACON::Input::Option::Value[:none], "Confirm deletion (required)")
    end

    protected def execute(input : ACON::Input::Interface, output : ACON::Output::Interface) : ACON::Command::Status
      id = input.argument("id").to_s
      unless input.option("yes", Bool)
        STDERR.puts "activities:delete failed: refusing to delete without --yes"
        RightDesk.exit_code = 2
        return ACON::Command::Status::FAILURE
      end

      resp = RightDesk::Client.delete("/api/v1/activities/#{URI.encode_path(id)}")
      return RightDesk.fail("activities:delete", resp, json?(input)) unless resp.success?

      if json?(input)
        output.puts({"id" => id, "deleted" => true}.to_json)
      else
        output.puts "deleted #{id}"
      end
      ACON::Command::Status::SUCCESS
    rescue ex
      STDERR.puts "activities:delete failed: #{ex.message}"
      RightDesk.exit_code = 1
      ACON::Command::Status::FAILURE
    end
  end

  @[ACONA::AsCommand("activities:done", description: "Mark an activity done")]
  class ActivitiesDoneCommand < ACON::Command
    include JSONOption

    protected def configure : Nil
      ActivitiesDoneCommand.add_json_option(self)
      self.argument("id", :required, "activity ID")
    end

    protected def execute(input : ACON::Input::Interface, output : ACON::Output::Interface) : ACON::Command::Status
      id = input.argument("id").to_s
      resp = RightDesk::Client.patch("/api/v1/activities/#{URI.encode_path(id)}/mark_done", {"done" => true}.to_json)
      return RightDesk.fail("activities:done", resp, json?(input)) unless resp.success?
      RightDesk.print_activity_result(input, output, resp)
    rescue ex
      STDERR.puts "activities:done failed: #{ex.message}"
      RightDesk.exit_code = 1
      ACON::Command::Status::FAILURE
    end
  end

  @[ACONA::AsCommand("activities:reopen", description: "Reopen a completed activity")]
  class ActivitiesReopenCommand < ACON::Command
    include JSONOption

    protected def configure : Nil
      ActivitiesReopenCommand.add_json_option(self)
      self.argument("id", :required, "activity ID")
    end

    protected def execute(input : ACON::Input::Interface, output : ACON::Output::Interface) : ACON::Command::Status
      id = input.argument("id").to_s
      resp = RightDesk::Client.patch("/api/v1/activities/#{URI.encode_path(id)}/mark_done", {"done" => false}.to_json)
      return RightDesk.fail("activities:reopen", resp, json?(input)) unless resp.success?
      RightDesk.print_activity_result(input, output, resp)
    rescue ex
      STDERR.puts "activities:reopen failed: #{ex.message}"
      RightDesk.exit_code = 1
      ACON::Command::Status::FAILURE
    end
  end

  @[ACONA::AsCommand("activities:add-blocker", description: "Add a blocker to an activity")]
  class ActivitiesAddBlockerCommand < ACON::Command
    include JSONOption

    protected def configure : Nil
      ActivitiesAddBlockerCommand.add_json_option(self)
      self.argument("id", :required, "activity ID")
      self.option("note", nil, ACON::Input::Option::Value[:required], "Blocker note (required)")
    end

    protected def execute(input : ACON::Input::Interface, output : ACON::Output::Interface) : ACON::Command::Status
      id = input.argument("id").to_s
      note = input.option("note").to_s.presence
      unless note
        STDERR.puts "activities:add-blocker failed: --note is required"
        RightDesk.exit_code = 2
        return ACON::Command::Status::FAILURE
      end

      resp = RightDesk::Client.patch("/api/v1/activities/#{URI.encode_path(id)}/add_blocker", {"blocker_note" => note}.to_json)
      return RightDesk.fail("activities:add-blocker", resp, json?(input)) unless resp.success?
      RightDesk.print_activity_result(input, output, resp)
    rescue ex
      STDERR.puts "activities:add-blocker failed: #{ex.message}"
      RightDesk.exit_code = 1
      ACON::Command::Status::FAILURE
    end
  end

  @[ACONA::AsCommand("activities:remove-blocker", description: "Remove a blocker by index")]
  class ActivitiesRemoveBlockerCommand < ACON::Command
    include JSONOption

    protected def configure : Nil
      ActivitiesRemoveBlockerCommand.add_json_option(self)
      self.argument("id", :required, "activity ID")
      self.option("index", nil, ACON::Input::Option::Value[:required], "Blocker index to remove (required)")
    end

    protected def execute(input : ACON::Input::Interface, output : ACON::Output::Interface) : ACON::Command::Status
      id = input.argument("id").to_s
      idx = input.option("index").to_s.presence
      unless idx
        STDERR.puts "activities:remove-blocker failed: --index is required"
        RightDesk.exit_code = 2
        return ACON::Command::Status::FAILURE
      end

      resp = RightDesk::Client.patch("/api/v1/activities/#{URI.encode_path(id)}/remove_blocker", {"index" => idx.to_i}.to_json)
      return RightDesk.fail("activities:remove-blocker", resp, json?(input)) unless resp.success?
      RightDesk.print_activity_result(input, output, resp)
    rescue ex
      STDERR.puts "activities:remove-blocker failed: #{ex.message}"
      RightDesk.exit_code = 1
      ACON::Command::Status::FAILURE
    end
  end

  @[ACONA::AsCommand("activities:subtask-add", description: "Add a subtask (checklist item)")]
  class ActivitiesSubtaskAddCommand < ACON::Command
    include JSONOption

    protected def configure : Nil
      ActivitiesSubtaskAddCommand.add_json_option(self)
      self.argument("id", :required, "activity ID")
      self.option("text", nil, ACON::Input::Option::Value[:required], "Subtask text (required)")
    end

    protected def execute(input : ACON::Input::Interface, output : ACON::Output::Interface) : ACON::Command::Status
      id = input.argument("id").to_s
      text = input.option("text").to_s.presence
      unless text
        STDERR.puts "activities:subtask-add failed: --text is required"
        RightDesk.exit_code = 2
        return ACON::Command::Status::FAILURE
      end

      resp = RightDesk::Client.patch("/api/v1/activities/#{URI.encode_path(id)}/add_checklist_item", {"text" => text}.to_json)
      return RightDesk.fail("activities:subtask-add", resp, json?(input)) unless resp.success?
      RightDesk.print_activity_result(input, output, resp)
    rescue ex
      STDERR.puts "activities:subtask-add failed: #{ex.message}"
      RightDesk.exit_code = 1
      ACON::Command::Status::FAILURE
    end
  end

  @[ACONA::AsCommand("activities:subtask-toggle", description: "Toggle a subtask's done state by index")]
  class ActivitiesSubtaskToggleCommand < ACON::Command
    include JSONOption

    protected def configure : Nil
      ActivitiesSubtaskToggleCommand.add_json_option(self)
      self.argument("id", :required, "activity ID")
      self.option("index", nil, ACON::Input::Option::Value[:required], "Subtask index to toggle (required)")
    end

    protected def execute(input : ACON::Input::Interface, output : ACON::Output::Interface) : ACON::Command::Status
      id = input.argument("id").to_s
      idx = input.option("index").to_s.presence
      unless idx
        STDERR.puts "activities:subtask-toggle failed: --index is required"
        RightDesk.exit_code = 2
        return ACON::Command::Status::FAILURE
      end

      resp = RightDesk::Client.patch("/api/v1/activities/#{URI.encode_path(id)}/toggle_checklist_item", {"index" => idx.to_i}.to_json)
      return RightDesk.fail("activities:subtask-toggle", resp, json?(input)) unless resp.success?
      RightDesk.print_activity_result(input, output, resp)
    rescue ex
      STDERR.puts "activities:subtask-toggle failed: #{ex.message}"
      RightDesk.exit_code = 1
      ACON::Command::Status::FAILURE
    end
  end

  @[ACONA::AsCommand("activities:subtask-remove", description: "Remove a subtask by index")]
  class ActivitiesSubtaskRemoveCommand < ACON::Command
    include JSONOption

    protected def configure : Nil
      ActivitiesSubtaskRemoveCommand.add_json_option(self)
      self.argument("id", :required, "activity ID")
      self.option("index", nil, ACON::Input::Option::Value[:required], "Subtask index to remove (required)")
    end

    protected def execute(input : ACON::Input::Interface, output : ACON::Output::Interface) : ACON::Command::Status
      id = input.argument("id").to_s
      idx = input.option("index").to_s.presence
      unless idx
        STDERR.puts "activities:subtask-remove failed: --index is required"
        RightDesk.exit_code = 2
        return ACON::Command::Status::FAILURE
      end

      resp = RightDesk::Client.patch("/api/v1/activities/#{URI.encode_path(id)}/remove_checklist_item", {"index" => idx.to_i}.to_json)
      return RightDesk.fail("activities:subtask-remove", resp, json?(input)) unless resp.success?
      RightDesk.print_activity_result(input, output, resp)
    rescue ex
      STDERR.puts "activities:subtask-remove failed: #{ex.message}"
      RightDesk.exit_code = 1
      ACON::Command::Status::FAILURE
    end
  end

  @[ACONA::AsCommand("activities:start-timer", description: "Start a time-tracking timer (server-side)")]
  class ActivitiesStartTimerCommand < ACON::Command
    include JSONOption

    protected def configure : Nil
      ActivitiesStartTimerCommand.add_json_option(self)
      self.argument("id", :required, "activity ID")
      self.option("note", nil, ACON::Input::Option::Value[:required], "Optional note for this timer")
    end

    protected def execute(input : ACON::Input::Interface, output : ACON::Output::Interface) : ACON::Command::Status
      id = input.argument("id").to_s
      body = Hash(String, String).new
      if note = input.option("note").to_s.presence
        body["note"] = note
      end

      resp = RightDesk::Client.patch("/api/v1/activities/#{URI.encode_path(id)}/start_timer", body.empty? ? nil : body.to_json)
      return RightDesk.fail("activities:start-timer", resp, json?(input)) unless resp.success?

      if json?(input)
        output.puts resp.body
      else
        output.puts "timer started for activity #{id}"
      end
      ACON::Command::Status::SUCCESS
    rescue ex
      STDERR.puts "activities:start-timer failed: #{ex.message}"
      RightDesk.exit_code = 1
      ACON::Command::Status::FAILURE
    end
  end

  @[ACONA::AsCommand("activities:stop-timer", description: "Stop the running timer and log the minutes")]
  class ActivitiesStopTimerCommand < ACON::Command
    include JSONOption

    protected def configure : Nil
      ActivitiesStopTimerCommand.add_json_option(self)
      self.argument("id", :required, "activity ID")
    end

    protected def execute(input : ACON::Input::Interface, output : ACON::Output::Interface) : ACON::Command::Status
      id = input.argument("id").to_s
      resp = RightDesk::Client.patch("/api/v1/activities/#{URI.encode_path(id)}/stop_timer")
      return RightDesk.fail("activities:stop-timer", resp, json?(input)) unless resp.success?

      if json?(input)
        output.puts resp.body
      else
        total = JSON.parse(resp.body)["activity"]?.try(&.["total_logged_minutes"]?)
        output.puts "timer stopped — #{total} minutes logged total"
      end
      ACON::Command::Status::SUCCESS
    rescue ex
      STDERR.puts "activities:stop-timer failed: #{ex.message}"
      RightDesk.exit_code = 1
      ACON::Command::Status::FAILURE
    end
  end

  @[ACONA::AsCommand("activities:log-time", description: "Log time manually against an activity")]
  class ActivitiesLogTimeCommand < ACON::Command
    include JSONOption

    protected def configure : Nil
      ActivitiesLogTimeCommand.add_json_option(self)
      self.argument("id", :required, "activity ID")
      self.option("minutes", nil, ACON::Input::Option::Value[:required], "Minutes to log (required, >0)")
      self.option("note", nil, ACON::Input::Option::Value[:required], "Note")
      self.option("credited-user", nil, ACON::Input::Option::Value[:required], "Teammate user ID to credit")
      self.option("worked-on", nil, ACON::Input::Option::Value[:required], "Date worked (YYYY-MM-DD)")
    end

    protected def execute(input : ACON::Input::Interface, output : ACON::Output::Interface) : ACON::Command::Status
      id = input.argument("id").to_s
      minutes = input.option("minutes").to_s.presence
      unless minutes
        STDERR.puts "activities:log-time failed: --minutes is required"
        RightDesk.exit_code = 2
        return ACON::Command::Status::FAILURE
      end

      body = Hash(String, String).new
      body["minutes"] = minutes
      body["note"] = input.option("note").to_s.presence.to_s if input.option("note").to_s.presence
      body["credited_user_id"] = input.option("credited-user").to_s.presence.to_s if input.option("credited-user").to_s.presence
      body["worked_on"] = input.option("worked-on").to_s.presence.to_s if input.option("worked-on").to_s.presence

      resp = RightDesk::Client.patch("/api/v1/activities/#{URI.encode_path(id)}/add_time", body.to_json)
      return RightDesk.fail("activities:log-time", resp, json?(input)) unless resp.success?

      if json?(input)
        output.puts resp.body
      else
        total = JSON.parse(resp.body)["activity"]?.try(&.["total_logged_minutes"]?)
        output.puts "logged #{minutes} min — #{total} minutes total"
      end
      ACON::Command::Status::SUCCESS
    rescue ex
      STDERR.puts "activities:log-time failed: #{ex.message}"
      RightDesk.exit_code = 1
      ACON::Command::Status::FAILURE
    end
  end

  @[ACONA::AsCommand("activities:edit-time", description: "Edit an existing time entry")]
  class ActivitiesEditTimeCommand < ACON::Command
    include JSONOption

    protected def configure : Nil
      ActivitiesEditTimeCommand.add_json_option(self)
      self.argument("id", :required, "activity ID")
      self.option("entry", nil, ACON::Input::Option::Value[:required], "Time entry ID (required)")
      self.option("minutes", nil, ACON::Input::Option::Value[:required], "New minutes (>0)")
      self.option("note", nil, ACON::Input::Option::Value[:required], "New note")
      self.option("credited-user", nil, ACON::Input::Option::Value[:required], "Teammate user ID to credit")
      self.option("worked-on", nil, ACON::Input::Option::Value[:required], "Date worked (YYYY-MM-DD)")
    end

    protected def execute(input : ACON::Input::Interface, output : ACON::Output::Interface) : ACON::Command::Status
      id = input.argument("id").to_s
      entry = input.option("entry").to_s.presence
      unless entry
        STDERR.puts "activities:edit-time failed: --entry is required"
        RightDesk.exit_code = 2
        return ACON::Command::Status::FAILURE
      end

      body = Hash(String, String).new
      body["entry_id"] = entry
      body["minutes"] = input.option("minutes").to_s.presence.to_s if input.option("minutes").to_s.presence
      body["note"] = input.option("note").to_s.presence.to_s if input.option("note").to_s.presence
      body["credited_user_id"] = input.option("credited-user").to_s.presence.to_s if input.option("credited-user").to_s.presence
      body["worked_on"] = input.option("worked-on").to_s.presence.to_s if input.option("worked-on").to_s.presence

      resp = RightDesk::Client.patch("/api/v1/activities/#{URI.encode_path(id)}/update_time_entry", body.to_json)
      return RightDesk.fail("activities:edit-time", resp, json?(input)) unless resp.success?
      RightDesk.print_activity_result(input, output, resp)
    rescue ex
      STDERR.puts "activities:edit-time failed: #{ex.message}"
      RightDesk.exit_code = 1
      ACON::Command::Status::FAILURE
    end
  end

  @[ACONA::AsCommand("activities:remove-time", description: "Remove a time entry")]
  class ActivitiesRemoveTimeCommand < ACON::Command
    include JSONOption

    protected def configure : Nil
      ActivitiesRemoveTimeCommand.add_json_option(self)
      self.argument("id", :required, "activity ID")
      self.option("entry", nil, ACON::Input::Option::Value[:required], "Time entry ID (required)")
    end

    protected def execute(input : ACON::Input::Interface, output : ACON::Output::Interface) : ACON::Command::Status
      id = input.argument("id").to_s
      entry = input.option("entry").to_s.presence
      unless entry
        STDERR.puts "activities:remove-time failed: --entry is required"
        RightDesk.exit_code = 2
        return ACON::Command::Status::FAILURE
      end

      query = URI::Params.build { |form| form.add("entry_id", entry) }
      resp = RightDesk::Client.delete("/api/v1/activities/#{URI.encode_path(id)}/remove_time_entry?#{query}")
      return RightDesk.fail("activities:remove-time", resp, json?(input)) unless resp.success?
      RightDesk.print_activity_result(input, output, resp)
    rescue ex
      STDERR.puts "activities:remove-time failed: #{ex.message}"
      RightDesk.exit_code = 1
      ACON::Command::Status::FAILURE
    end
  end

  @[ACONA::AsCommand("activities:comment", description: "Add a comment to an activity")]
  class ActivitiesCommentCommand < ACON::Command
    include JSONOption

    protected def configure : Nil
      ActivitiesCommentCommand.add_json_option(self)
      self.argument("id", :required, "activity ID")
      self.option("body", nil, ACON::Input::Option::Value[:required], "Comment body (required)")
    end

    protected def execute(input : ACON::Input::Interface, output : ACON::Output::Interface) : ACON::Command::Status
      id = input.argument("id").to_s
      text = input.option("body").to_s.presence
      unless text
        STDERR.puts "activities:comment failed: --body is required"
        RightDesk.exit_code = 2
        return ACON::Command::Status::FAILURE
      end

      resp = RightDesk::Client.post("/api/v1/activities/#{URI.encode_path(id)}/comments", {"comment" => {"body" => text}}.to_json)
      return RightDesk.fail("activities:comment", resp, json?(input)) unless resp.success?

      if json?(input)
        output.puts resp.body
      else
        c = JSON.parse(resp.body)["comment"]?
        if c
          output.puts "#{c["id"]?}\t#{c["body"]?.try(&.as_s?)}"
        else
          output.puts resp.body
        end
      end
      ACON::Command::Status::SUCCESS
    rescue ex
      STDERR.puts "activities:comment failed: #{ex.message}"
      RightDesk.exit_code = 1
      ACON::Command::Status::FAILURE
    end
  end

  @[ACONA::AsCommand("activities:comments", description: "List an activity's comments")]
  class ActivitiesCommentsCommand < ACON::Command
    include JSONOption

    protected def configure : Nil
      ActivitiesCommentsCommand.add_json_option(self)
      self.argument("id", :required, "activity ID")
      self.option("page", nil, ACON::Input::Option::Value[:required], "Page number (default 1)")
      self.option("limit", nil, ACON::Input::Option::Value[:required], "Results per page (max 100)")
    end

    protected def execute(input : ACON::Input::Interface, output : ACON::Output::Interface) : ACON::Command::Status
      id = input.argument("id").to_s
      params = URI::Params.build do |form|
        if p = input.option("page").to_s.presence
          form.add("page", p)
        end
        if l = input.option("limit").to_s.presence
          form.add("per_page", l)
        end
      end

      resp = RightDesk::Client.get("/api/v1/activities/#{URI.encode_path(id)}/comments", params)
      return RightDesk.fail("activities:comments", resp, json?(input)) unless resp.success?

      if json?(input)
        output.puts resp.body
        return ACON::Command::Status::SUCCESS
      end

      parsed = JSON.parse(resp.body)
      (parsed["comments"]?.try(&.as_a?) || [] of JSON::Any).each do |c|
        at = c["created_at"]?.try(&.as_s?) || ""
        who = c["user_name"]?.try(&.as_s?) || "?"
        body = c["body"]?.try(&.as_s?) || ""
        output.puts "#{at}\t#{who}: #{body}"
      end
      ACON::Command::Status::SUCCESS
    rescue ex
      STDERR.puts "activities:comments failed: #{ex.message}"
      RightDesk.exit_code = 1
      ACON::Command::Status::FAILURE
    end
  end

  @[ACONA::AsCommand("activities:history", description: "Show an activity's history (events)")]
  class ActivitiesHistoryCommand < ACON::Command
    include JSONOption

    protected def configure : Nil
      ActivitiesHistoryCommand.add_json_option(self)
      self.argument("id", :required, "activity ID")
      self.option("page", nil, ACON::Input::Option::Value[:required], "Page number (default 1)")
      self.option("limit", nil, ACON::Input::Option::Value[:required], "Results per page (max 100)")
    end

    protected def execute(input : ACON::Input::Interface, output : ACON::Output::Interface) : ACON::Command::Status
      id = input.argument("id").to_s
      params = URI::Params.build do |form|
        if p = input.option("page").to_s.presence
          form.add("page", p)
        end
        if l = input.option("limit").to_s.presence
          form.add("per_page", l)
        end
      end

      resp = RightDesk::Client.get("/api/v1/activities/#{URI.encode_path(id)}/events", params)
      return RightDesk.fail("activities:history", resp, json?(input)) unless resp.success?

      if json?(input)
        output.puts resp.body
        return ACON::Command::Status::SUCCESS
      end

      parsed = JSON.parse(resp.body)
      (parsed["events"]?.try(&.as_a?) || [] of JSON::Any).each do |e|
        at = e["created_at"]?.try(&.as_s?) || ""
        type = e["event_type"]?.try(&.as_s?) || "?"
        who = e["user_name"]?.try(&.as_s?) || ""
        summary = RightDesk.summarize_event_data(e["event_data"]?)
        line = "#{at}\t#{type}\t#{who}"
        line += "\t#{summary}" unless summary.empty?
        output.puts line
      end
      ACON::Command::Status::SUCCESS
    rescue ex
      STDERR.puts "activities:history failed: #{ex.message}"
      RightDesk.exit_code = 1
      ACON::Command::Status::FAILURE
    end
  end
end

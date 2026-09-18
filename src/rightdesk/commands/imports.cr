require "athena-console"
require "json"
require "uri"
require "../client"
require "../support"

module RightDesk
  # CSV imports of contacts and companies.
  #
  # The server owns the work: an upload becomes a BulkItemImport and a background job
  # streams the rows, matching each person against every existing contact, lead,
  # customer and partner before writing. These commands upload, show what the server
  # detected, and watch the result -- they never parse the CSV themselves, so the CLI
  # and the web UI can never disagree about what a file means.
  #
  # `--yes` is the gate: auto-mapping is a heuristic, so a run without it uploads the
  # file, prints the mapping, and imports nothing. With it, the upload and the start are
  # still two requests -- only the start can report why the server refused to run it.

  # What `rd imports skipped --reason` can filter on. Blank rows are only a counter --
  # the server never records them as skipped rows, so it cannot filter on them either.
  # It ignores an unrecognized reason rather than rejecting it, which would hand back
  # every row while looking like a filter, so the check belongs here.
  SKIPPED_REASONS = %w[duplicate invalid]

  def self.skipped_reason(input : ACON::Input::Interface) : String?
    raw = input.option("reason").to_s.strip
    return nil if raw.empty?
    unless SKIPPED_REASONS.includes?(raw)
      raise UsageError.new("--reason must be one of: #{SKIPPED_REASONS.join(", ")} (got #{raw.inspect})")
    end

    raw
  end

  # The one-shot: upload, show the mapping, optionally start and watch.
  def self.configure_import_upload(cmd : ACON::Command) : Nil
    cmd
      .option("file", "f", ACON::Input::Option::Value[:required], "CSV file to import")
      .option("yes", nil, ACON::Input::Option::Value[:none], "Accept the detected mapping and import")
      .option("no-wait", nil, ACON::Input::Option::Value[:none], "Return as soon as the import starts")
  end

  def self.run_import_upload(input : ACON::Input::Interface, output : ACON::Output::Interface,
                             label : String, item_type : String) : ACON::Command::Status
    path = input.option("file").to_s
    raise UsageError.new("--file is required") if path.blank?
    raise UsageError.new("no such file: #{path}") unless File.file?(path)

    json = input.option("json", Bool)
    start = input.option("yes", Bool)

    # `import[start]=true` exists server-side but is unusable here: the create call swallows
    # a refused start and 201s either way, and the payload has no field that separates
    # "enqueued" from "refused" (state is `uploaded` for both, until a worker picks it up).
    # So the start is always its own request, where a refusal comes back as 409/422.
    fields = {"import[item_type]" => item_type}

    # Streamed from disk rather than read into a String: a 25 MB export would otherwise
    # sit in memory twice over (see Client.post_multipart).
    resp = File.open(path) do |file|
      Client.post_multipart("/api/v1/imports", fields, "import[file]",
        File.basename(path), "text/csv", file)
    end
    return RightDesk.fail(label, resp, json) unless resp.success?

    import = JSON.parse(resp.body)["import"]
    id = import["id"].to_s

    unless start
      # Nothing ran. Say so unambiguously -- an exit 0 here must not read as "imported".
      if json
        output.puts resp.body
      else
        print_import_mapping(output, import, path)
        output.puts "import #{id} created — nothing imported yet; " \
                    "re-run with --yes, or: rd imports start #{id}"
      end
      return ACON::Command::Status::SUCCESS
    end

    print_import_mapping(output, import, path) unless json

    start_resp = Client.post("/api/v1/imports/#{URI.encode_path(id)}/start")
    return RightDesk.fail(label, start_resp, json) unless start_resp.success?

    if input.option("no-wait", Bool)
      # The 202, not the 201: under -j the document a script reads must describe the
      # operation that actually ran.
      output.puts start_resp.body if json
      output.puts "import #{id} started — watch with: rd imports get #{id} --wait" unless json
      return ACON::Command::Status::SUCCESS
    end

    watch_import(output, label, id, json)
  end

  # Renders the detected mapping so the operator can see what each column became before
  # committing to it. Unmapped columns print too: a column silently dropped is usually a
  # mis-detected header, which is exactly what this screen exists to catch.
  #
  # Sorted by column name, not file order -- column_mapping is jsonb, which does not
  # preserve key order, so file order is already gone by the time it is read back.
  def self.print_import_mapping(output : ACON::Output::Interface, import : JSON::Any, path : String,
                                title : String = "mapping detected for") : Nil
    mapping = import["column_mapping"]?.try(&.as_h?)
    name = import["filename"]?.try(&.as_s?) || File.basename(path)
    size = import["byte_size"]?.try { |b| b.as_i64? || b.as_i?.try(&.to_i64) }

    header = "#{title} #{name}"
    header += " (#{human_bytes(size)})" if size
    output.puts header

    if mapping.nil? || mapping.empty?
      output.puts "  (no columns detected — is the file a CSV with a header row?)"
      return
    end

    skipped = (import["unmapped_columns"]?.try(&.as_a?) || [] of JSON::Any)
      .compact_map(&.as_s?).to_set
    width = mapping.keys.max_of { |k| display_width(k) }.clamp(1, 40)

    mapping.keys.sort.each do |column|
      field = mapping[column].as_s? || ""
      target = skipped.includes?(column) || field.blank? ? "(not imported)" : field
      output.puts "  #{pad_to(column, width)}  ->  #{target}"
    end

    if !skipped.empty? && skipped.size == mapping.size
      output.puts "  none of these columns matched a field — this import would write nothing"
    elsif !skipped.empty?
      output.puts "  #{plural(skipped.size, "column")} will not be imported"
    end
  end

  # Watches an import and maps how the watch ended onto output + an exit code.
  def self.watch_import(output : ACON::Output::Interface, label : String,
                        id : String, json : Bool) : ACON::Command::Status
    outcome = poll_import(id, json)

    case outcome.decision
    when .http_error?
      if resp = outcome.resp
        return RightDesk.fail(label, resp, json)
      end
      RightDesk.exit_code = 1
      ACON::Command::Status::FAILURE
    when .done?
      output.puts outcome.body if json && outcome.body
      print_import_summary(output, outcome.body, id) unless json
      ACON::Command::Status::SUCCESS
    when .failed?
      output.puts outcome.body if json && outcome.body
      raw = import_field(outcome.body, "failed_reason")
      reason = first_line(raw) || "no reason given"
      message = "#{label} failed: import #{id} failed server-side — #{reason}"
      # A backtrace is not terminal output. The whole thing stays one -j away.
      message += " (full reason: rd imports get #{id} -j)" if raw && raw.lines.size > 1
      STDERR.puts message
      RightDesk.exit_code = 1
      ACON::Command::Status::FAILURE
    when .interrupted?
      # The import is untouched: we only stopped looking. Hence 130, not 1.
      state = import_field(outcome.body, "state") || "pending"
      STDERR.puts "stopped watching import #{id} — still #{state} server-side · " \
                  "resume with: rd imports get #{id} --wait"
      RightDesk.exit_code = EXIT_INTERRUPTED
      ACON::Command::Status::FAILURE
    when .timeout?
      STDERR.puts "#{label} failed: gave up watching import #{id} after #{POLL_TIMEOUT.to_i}s " \
                  "(it may still be running) — check with: rd imports get #{id}"
      RightDesk.exit_code = 1
      ACON::Command::Status::FAILURE
    else
      state = import_field(outcome.body, "state") || "unknown"
      STDERR.puts "#{label} failed: stopped watching import #{id} (state #{state}) — " \
                  "check with: rd imports get #{id}"
      RightDesk.exit_code = 1
      ACON::Command::Status::FAILURE
    end
  end

  # The counts line, plus pointers to anything the import refused to write.
  def self.print_import_summary(output : ACON::Output::Interface, body : String?, id : String) : Nil
    import = body.try { |b| JSON.parse(b)["import"]? rescue nil }
    unless import && (counts = import["counts"]?)
      output.puts "import #{id} finished"
      return
    end

    parts = [plural(count_of(counts, "row"), "row"), "#{count_of(counts, "imported")} imported"]
    {"duplicate", "invalid", "blank"}.each do |key|
      n = count_of(counts, key)
      parts << "#{n} #{key}" if n > 0
    end
    output.puts parts.join(" · ")

    skipped = count_of(counts, "skipped")
    if skipped > 0
      line = "#{plural(skipped, "row")} skipped — see: rd imports skipped #{id}"
      line += " (list truncated)" if import["skipped_rows_truncated"]?.try(&.as_bool?)
      output.puts line
    end

    (import["warnings"]?.try(&.as_a?) || [] of JSON::Any).each do |warning|
      STDERR.puts "warning: #{warning.as_s? || warning}"
    end
  end

  def self.import_field(body : String?, key : String) : String?
    return nil unless body
    (JSON.parse(body)["import"]?.try(&.[key]?).try(&.as_s?) rescue nil)
  end

  def self.human_bytes(bytes : Int64) : String
    return "#{bytes} B" if bytes < 1024
    kb = bytes / 1024.0
    return "#{kb.round(1)} KB" if kb < 1024
    "#{(kb / 1024.0).round(1)} MB"
  end

  # One row per skipped row: why it was skipped, and what it collided with.
  def self.print_skipped_rows(output : ACON::Output::Interface, parsed : JSON::Any) : Nil
    (parsed["skipped_rows"]?.try(&.as_a?) || [] of JSON::Any).each do |row|
      outcome = row["outcome"]?.try(&.as_s?) || "?"
      cells = ["#{row["row_number"]?}", outcome]

      values = row["values"]?.try(&.as_h?)
      # `values` carries email/phone for contacts and domain for companies, so take
      # whichever identifies this row rather than assuming one shape.
      if values
        identity = %w[email phone domain name].compact_map { |k| values[k]?.try(&.as_s?).presence }.first?
        cells << identity if identity
      end

      if matched = row["matched_by"]?.try(&.as_s?)
        detail = matched
        if value = row["matched_value"]?.try(&.as_s?).presence
          detail += " #{value}"
        end
        cells << detail
      end

      if existing = row["existing"]?.try(&.as_h?)
        cell = "#{existing["type"]?.try(&.as_s?)} #{existing["id"]?}"
        # The role that person already holds -- lead, customer, partner -- is the
        # reason the row was refused, so it goes on the line rather than only in -j.
        if role = existing["primary_role"]?.try(&.as_s?).presence
          cell += " (#{role})"
        end
        cells << cell
      end

      errors = (row["errors"]?.try(&.as_a?) || [] of JSON::Any).compact_map(&.as_s?)
      cells << errors.join("; ") unless errors.empty?

      output.puts cells.join("\t")
    end
  end

  @[ACONA::AsCommand("contacts:import", description: "Import contacts from a CSV")]
  class ContactsImportCommand < ACON::Command
    include JSONOption

    protected def configure : Nil
      ContactsImportCommand.add_json_option(self)
      RightDesk.configure_import_upload(self)
    end

    protected def execute(input : ACON::Input::Interface, output : ACON::Output::Interface) : ACON::Command::Status
      RightDesk.run_import_upload(input, output, "contacts:import", "contact")
    rescue ex : RightDesk::UsageError
      RightDesk.usage_fail("contacts:import", ex.message || "invalid input")
    rescue ex
      STDERR.puts "contacts:import failed: #{ex.message}"
      RightDesk.exit_code = 1
      ACON::Command::Status::FAILURE
    end
  end

  @[ACONA::AsCommand("companies:import", description: "Import companies from a CSV")]
  class CompaniesImportCommand < ACON::Command
    include JSONOption

    protected def configure : Nil
      CompaniesImportCommand.add_json_option(self)
      RightDesk.configure_import_upload(self)
    end

    protected def execute(input : ACON::Input::Interface, output : ACON::Output::Interface) : ACON::Command::Status
      RightDesk.run_import_upload(input, output, "companies:import", "company")
    rescue ex : RightDesk::UsageError
      RightDesk.usage_fail("companies:import", ex.message || "invalid input")
    rescue ex
      STDERR.puts "companies:import failed: #{ex.message}"
      RightDesk.exit_code = 1
      ACON::Command::Status::FAILURE
    end
  end

  @[ACONA::AsCommand("imports:list", description: "List CSV imports (newest first)")]
  class ImportsListCommand < ACON::Command
    include JSONOption

    protected def configure : Nil
      ImportsListCommand.add_json_option(self)
      self
        .option("state", nil, ACON::Input::Option::Value[:required], "Filter by state (uploaded|processing|finished|failed)")
        .option("page", nil, ACON::Input::Option::Value[:required], "Page number (default 1)")
        .option("limit", nil, ACON::Input::Option::Value[:required], "Results per page (max 100)")
    end

    protected def execute(input : ACON::Input::Interface, output : ACON::Output::Interface) : ACON::Command::Status
      params = URI::Params.build do |form|
        if s = input.option("state").to_s.presence
          form.add("state", s)
        end
        if p = input.option("page").to_s.presence
          form.add("page", p)
        end
        if l = input.option("limit").to_s.presence
          form.add("per_page", l)
        end
      end

      resp = RightDesk::Client.get("/api/v1/imports", params)
      return RightDesk.fail("imports:list", resp, json?(input)) unless resp.success?

      if json?(input)
        output.puts resp.body
        return ACON::Command::Status::SUCCESS
      end

      parsed = JSON.parse(resp.body)
      (parsed["imports"]?.try(&.as_a?) || [] of JSON::Any).each do |i|
        cells = ["#{i["id"]?}", i["state"]?.try(&.as_s?) || "?", i["item_type"]?.try(&.as_s?) || "?"]
        cells << (i["filename"]?.try(&.as_s?) || "—")
        if counts = i["counts"]?
          cells << "#{RightDesk.count_of(counts, "row")} rows · #{RightDesk.count_of(counts, "imported")} imported"
        end
        output.puts cells.join("\t")
      end

      if meta = parsed["meta"]?
        output.puts ""
        output.puts "#{meta["total_count"]?} imports — page #{meta["current_page"]?}/#{meta["total_pages"]?}"
      end
      ACON::Command::Status::SUCCESS
    rescue ex
      STDERR.puts "imports:list failed: #{ex.message}"
      RightDesk.exit_code = 1
      ACON::Command::Status::FAILURE
    end
  end

  @[ACONA::AsCommand("imports:get", description: "Show one import, optionally waiting for it to finish")]
  class ImportsGetCommand < ACON::Command
    include JSONOption

    protected def configure : Nil
      ImportsGetCommand.add_json_option(self)
      self.argument("id", :required, "import ID")
      self.option("wait", nil, ACON::Input::Option::Value[:none], "Watch until the import finishes")
    end

    protected def execute(input : ACON::Input::Interface, output : ACON::Output::Interface) : ACON::Command::Status
      id = RightDesk.id_argument!(input)
      return RightDesk.watch_import(output, "imports:get", id, json?(input)) if input.option("wait", Bool)

      resp = RightDesk::Client.get("/api/v1/imports/#{URI.encode_path(id)}")
      return RightDesk.fail("imports:get", resp, json?(input)) unless resp.success?

      if json?(input)
        output.puts resp.body
        return ACON::Command::Status::SUCCESS
      end

      import = JSON.parse(resp.body)["import"]
      output.puts "id: #{import["id"]?}"
      output.puts "state: #{import["state"]?.try(&.as_s?)}"
      output.puts "item_type: #{import["item_type"]?.try(&.as_s?)}"
      output.puts "file: #{import["filename"]?.try(&.as_s?)}"
      output.puts "progress: #{import["percentage_complete"]?}%"
      RightDesk.print_import_mapping(output, import, "", title: "columns in")
      RightDesk.print_import_summary(output, resp.body, id)
      if raw = import["failed_reason"]?.try(&.as_s?).presence
        output.puts "failed_reason: #{RightDesk.first_line(raw)}"
        output.puts "  (truncated — full reason under -j)" if raw.lines.size > 1
      end
      ACON::Command::Status::SUCCESS
    rescue ex : RightDesk::UsageError
      RightDesk.usage_fail("imports:get", ex.message || "invalid input")
    rescue ex
      STDERR.puts "imports:get failed: #{ex.message}"
      RightDesk.exit_code = 1
      ACON::Command::Status::FAILURE
    end
  end

  @[ACONA::AsCommand("imports:start", description: "Start an uploaded import")]
  class ImportsStartCommand < ACON::Command
    include JSONOption

    protected def configure : Nil
      ImportsStartCommand.add_json_option(self)
      self.argument("id", :required, "import ID")
      self.option("wait", nil, ACON::Input::Option::Value[:none], "Watch until the import finishes")
    end

    protected def execute(input : ACON::Input::Interface, output : ACON::Output::Interface) : ACON::Command::Status
      id = RightDesk.id_argument!(input)
      resp = RightDesk::Client.post("/api/v1/imports/#{URI.encode_path(id)}/start")
      return RightDesk.fail("imports:start", resp, json?(input)) unless resp.success?

      return RightDesk.watch_import(output, "imports:start", id, json?(input)) if input.option("wait", Bool)

      if json?(input)
        output.puts resp.body
      else
        output.puts "import #{id} started — watch with: rd imports get #{id} --wait"
      end
      ACON::Command::Status::SUCCESS
    rescue ex : RightDesk::UsageError
      RightDesk.usage_fail("imports:start", ex.message || "invalid input")
    rescue ex
      STDERR.puts "imports:start failed: #{ex.message}"
      RightDesk.exit_code = 1
      ACON::Command::Status::FAILURE
    end
  end

  @[ACONA::AsCommand("imports:skipped", description: "List the rows an import did not write")]
  class ImportsSkippedCommand < ACON::Command
    include JSONOption

    protected def configure : Nil
      ImportsSkippedCommand.add_json_option(self)
      self.argument("id", :required, "import ID")
      self
        .option("reason", nil, ACON::Input::Option::Value[:required], "Filter by outcome (duplicate|invalid)")
        .option("page", nil, ACON::Input::Option::Value[:required], "Page number (default 1)")
        .option("limit", nil, ACON::Input::Option::Value[:required], "Results per page (max 100)")
    end

    protected def execute(input : ACON::Input::Interface, output : ACON::Output::Interface) : ACON::Command::Status
      id = RightDesk.id_argument!(input)
      params = URI::Params.build do |form|
        if r = RightDesk.skipped_reason(input)
          form.add("reason", r)
        end
        if p = input.option("page").to_s.presence
          form.add("page", p)
        end
        if l = input.option("limit").to_s.presence
          form.add("per_page", l)
        end
      end

      resp = RightDesk::Client.get("/api/v1/imports/#{URI.encode_path(id)}/skipped", params)
      return RightDesk.fail("imports:skipped", resp, json?(input)) unless resp.success?

      if json?(input)
        output.puts resp.body
        return ACON::Command::Status::SUCCESS
      end

      parsed = JSON.parse(resp.body)
      RightDesk.print_skipped_rows(output, parsed)

      if meta = parsed["meta"]?
        output.puts ""
        output.puts "#{meta["total_count"]?} skipped rows — page #{meta["current_page"]?}/#{meta["total_pages"]?}"
      end
      if parsed["truncated"]?.try(&.as_bool?)
        STDERR.puts "note: the server stopped recording skipped rows before the end of the file"
      end
      ACON::Command::Status::SUCCESS
    rescue ex : RightDesk::UsageError
      RightDesk.usage_fail("imports:skipped", ex.message || "invalid input")
    rescue ex
      STDERR.puts "imports:skipped failed: #{ex.message}"
      RightDesk.exit_code = 1
      ACON::Command::Status::FAILURE
    end
  end
end

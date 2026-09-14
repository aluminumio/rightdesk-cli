require "json"
require "athena-console"
require "./client"

module RightDesk
  # Process exit code, set by command failures and read by `CLI.run`.
  # 0 ok · 1 general · 2 usage · 3 auth(401) · 4 not-found(404) · 5 insufficient-scope(403).
  @@exit_code : Int32? = nil

  def self.exit_code=(code : Int32)
    @@exit_code = code
  end

  def self.exit_code? : Int32?
    @@exit_code
  end

  def self.status_for(http : Int32) : Int32
    case http
    when 401 then 3
    when 403 then 5
    when 404 then 4
    else          1
    end
  end

  # Bad flag input (missing, blank, or unparseable). Commands rescue this and
  # exit 2 (usage) rather than 1 (general failure), matching the convention the
  # hand-written `--x is required` checks already follow.
  class UsageError < Exception
  end

  # Uniform usage-error output → STDERR, exit code 2.
  def self.usage_fail(label : String, message : String) : ACON::Command::Status
    STDERR.puts "#{label} failed: #{message}"
    RightDesk.exit_code = 2
    ACON::Command::Status::FAILURE
  end

  # Integer flag that must be present. Blank or non-numeric raises `UsageError`
  # instead of `String#to_i`'s raw `Invalid Int32` — and instead of silently
  # coercing to 0, which on an --index flag would address the wrong row.
  def self.int_option!(input : ACON::Input::Interface, name : String) : Int32
    raw = input.option(name)
    raise UsageError.new("--#{name} is required") if raw.nil? || raw.strip.empty?

    raw.strip.to_i? || raise UsageError.new("--#{name} must be an integer (got #{raw.inspect})")
  end

  # A zero-based position in a list. Negative values are rejected here rather than
  # sent on: Ruby would wrap -1 onto the last element server-side.
  def self.index_option!(input : ACON::Input::Interface, name : String) : Int32
    idx = int_option!(input, name)
    raise UsageError.new("--#{name} must be zero or greater (got #{idx})") if idx.negative?

    idx
  end

  # Integer flag that may be omitted. Returns nil when the flag is absent or given
  # an empty value (which callers send as an explicit null to clear the field), and
  # raises `UsageError` when it is present but not an integer — a typo'd
  # `--duration 3o` must not be dropped on the floor.
  def self.int_option(input : ACON::Input::Interface, name : String) : Int32?
    raw = input.option(name)
    return nil if raw.nil? || raw.strip.empty?

    raw.strip.to_i? || raise UsageError.new("--#{name} must be an integer (got #{raw.inspect})")
  end

  # Mixin for data-returning commands. Adds `--json/-j` and exposes `json?(input)`.
  module JSONOption
    macro included
      def self.add_json_option(cmd)
        cmd.option("json", "j", ACON::Input::Option::Value[:none], "Emit JSON instead of human-readable text")
      end
    end

    protected def json?(input : ACON::Input::Interface) : Bool
      input.option("json", Bool)
    end
  end

  # Uniform failure output → STDERR (diagnostics never touch stdout). Records the
  # mapped exit code. Under --json, emits a structured `{error,code,hint?}` object.
  def self.fail(label : String, resp : Client::Response, json : Bool = false) : ACON::Command::Status
    RightDesk.exit_code = status_for(resp.status)
    if json
      obj = Hash(String, String).new
      obj["error"] = error_message(resp)
      obj["code"] = error_code(resp)
      obj["hint"] = "Run `rd login`." if resp.status == 401
      STDERR.puts obj.to_json
    elsif resp.status == 401
      STDERR.puts "#{label} failed: not authenticated (HTTP 401). Run `rd login`."
    else
      # Prefer the JSON `error` field; otherwise show the raw body, truncated so a
      # non-JSON response (e.g. a server-rendered HTML 500 page) can't flood stderr.
      detail = (JSON.parse(resp.body)["error"]?.try(&.as_s?) rescue nil) || resp.body
      detail = "#{detail[0, 500]}… (truncated)" if detail.size > 500
      STDERR.puts "#{label} failed: HTTP #{resp.status} — #{detail}"
    end
    ACON::Command::Status::FAILURE
  end

  def self.error_code(resp : Client::Response) : String
    if (parsed = JSON.parse(resp.body) rescue nil) && (c = parsed["code"]?.try(&.as_s?))
      return c
    end
    case resp.status
    when 401 then "unauthorized"
    when 403 then "forbidden"
    when 404 then "not_found"
    when 422 then "validation_error"
    else          "error"
    end
  end

  def self.error_message(resp : Client::Response) : String
    if (parsed = JSON.parse(resp.body) rescue nil) && (m = parsed["error"]?.try(&.as_s?))
      return m
    end
    "HTTP #{resp.status}"
  end

  # Print a lean timeline feed (`at  type  summary`) or raw JSON under --json.
  # Shared by customers:timeline and partners:timeline.
  def self.print_timeline(output : ACON::Output::Interface, resp : Client::Response, json : Bool) : ACON::Command::Status
    if json
      output.puts resp.body
      return ACON::Command::Status::SUCCESS
    end
    (JSON.parse(resp.body)["events"]?.try(&.as_a?) || [] of JSON::Any).each do |e|
      type = e["type"]?.try(&.as_s?) || "?"
      at = e["at"]?.try(&.as_s?) || ""
      summary = ""
      if data = e["data"]?
        summary = data["subject"]?.try(&.as_s?) || data["content"]?.try(&.as_s?) || ""
      end
      line = "#{at}\t#{type}"
      line += "\t#{summary}" unless summary.empty?
      output.puts line
    end
    ACON::Command::Status::SUCCESS
  end
end

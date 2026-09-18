require "json"
require "athena-console"
require "uri"
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

  # A record id taken from a positional argument. Ids are numeric everywhere in the API,
  # and some routes constrain them (`/api/v1/imports/:id` is `\d+`) -- a non-numeric id
  # there never reaches the controller, so it comes back without the JSON `{error, code}`
  # body every other failure has, and the raw response gets printed instead. Rejecting it
  # here turns that into a plain usage error. Separate from `int_option!` because those
  # messages name a flag, and `--id is required` would be a lie for an argument.
  def self.id_argument!(input : ACON::Input::Interface, name : String = "id") : String
    raw = input.argument(name).to_s.strip
    raise UsageError.new("#{name} is required") if raw.empty?
    raise UsageError.new("#{name} must be a number (got #{raw.inspect})") unless raw.each_char.all?(&.ascii_number?)

    raw
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
    elsif resp.status == Client::CONNECTION_FAILED_STATUS
      # Synthesized, not a real status -- printing "HTTP 599" would send the reader
      # looking up a code that does not exist.
      STDERR.puts "#{label} failed: #{error_message(resp)}"
    else
      # Prefer the JSON `error` field; otherwise show the raw body, truncated so a
      # non-JSON response (e.g. a server-rendered HTML 500 page) can't flood stderr.
      parsed = (JSON.parse(resp.body) rescue nil)
      detail = parsed.try(&.["error"]?).try(&.as_s?) || resp.body
      detail = "#{detail[0, 500]}… (truncated)" if detail.size > 500
      STDERR.puts "#{label} failed: HTTP #{resp.status} — #{detail}"
      # `details` is where a 422 says *what* was wrong. Without it the most common
      # import failure -- an oversize or unparseable file -- reads as a bare
      # "Validation failed" with the actionable part dropped.
      (parsed.try(&.["details"]?).try(&.as_a?) || [] of JSON::Any).each do |item|
        STDERR.puts "  #{item.as_s? || item}"
      end
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

  # --- import polling -------------------------------------------------------
  #
  # `--wait` watches a server-side import to completion. The server owns the work; the
  # CLI only samples `GET /api/v1/imports/:id` and renders it. Ctrl-C therefore stops
  # the *watching*, never the import -- hence its own exit code.

  # 128 + SIGINT, the shell convention. Distinct from 1 on purpose: the import is still
  # running server-side, so a script must be able to tell "I stopped looking" from
  # "the import failed".
  EXIT_INTERRUPTED = 130

  # Responsive at the start (a small file finishes in a second), backing off so a
  # 100k-row import does not hammer the endpoint, and bounded so nothing watches forever.
  POLL_FIRST_INTERVAL = 1.0
  POLL_BACKOFF        = 1.5
  POLL_MAX_INTERVAL   = 10.0
  POLL_TIMEOUT        = 900.0
  POLL_MAX_FAILURES   = 5
  # Ctrl-C is noticed within this many seconds rather than after a full 10s tick.
  POLL_SLICE = 0.1

  # The states an import can sit in while still working. Everything else is terminal --
  # so a state added to a newer server ends the loop instead of spinning against it.
  POLL_PENDING_STATES = %w[uploaded processing]

  enum PollDecision
    Continue    # still working
    Done        # finished
    Failed      # the import failed server-side
    Timeout     # still pending when POLL_TIMEOUT ran out
    GiveUp      # too many consecutive poll failures, or a state we cannot interpret
    Interrupted # Ctrl-C
    HttpError   # 401/403/404 -- no point retrying
  end

  record PollOutcome,
    decision : PollDecision,
    body : String?,     # the last import payload seen, for the summary
    resp : Client::Response? # set when the watch ended on an HTTP failure

  # The whole decision table, kept pure so it can be tested without a server (the repo
  # has no HTTP mocking). `state` is nil when a poll did not yield one.
  def self.poll_decision(state : String?, elapsed : Float64, failures : Int32,
                         timeout : Float64 = POLL_TIMEOUT,
                         max_failures : Int32 = POLL_MAX_FAILURES) : PollDecision
    # No state: assume transient (one dropped connection must not fail the command)
    # and retry a bounded number of times.
    if state.nil?
      return PollDecision::GiveUp if failures >= max_failures
      return elapsed >= timeout ? PollDecision::Timeout : PollDecision::Continue
    end

    case state
    when "finished" then PollDecision::Done
    when "failed"   then PollDecision::Failed
    when .in?(POLL_PENDING_STATES)
      elapsed >= timeout ? PollDecision::Timeout : PollDecision::Continue
    else
      # Terminal but unrecognized. Stop, and do not report success for a state this
      # build cannot interpret.
      PollDecision::GiveUp
    end
  end

  def self.poll_interval(previous : Float64) : Float64
    Math.min(previous * POLL_BACKOFF, POLL_MAX_INTERVAL)
  end

  # 401/403/404 are answers, not hiccups: retrying cannot change them.
  def self.poll_hard_failure?(status : Int32) : Bool
    status == 401 || status == 403 || status == 404
  end

  # Progress is decoration, so it goes to STDERR (stdout stays parseable) and is
  # suppressed whenever nobody is watching a terminal: under -j, when stderr is
  # redirected (otherwise `2> build.log` fills with \r frames), and under RD_NO_PROGRESS.
  def self.progress?(json : Bool) : Bool
    return false if json
    return false if ENV["RD_NO_PROGRESS"]?.presence
    STDERR.tty?
  end

  PROGRESS_WIDTH = 16

  @@progress_shown = false
  @@progress_percent = 0.0

  def self.progress_reset : Nil
    @@progress_shown = false
    @@progress_percent = 0.0
  end

  def self.progress_tick(percent : Float64, detail : String) : Nil
    # Clamped monotonic: the server recomputes percentage_complete per batch, and a bar
    # that walks backwards reads as a bug in the import.
    @@progress_percent = Math.max(@@progress_percent, percent.clamp(0.0, 100.0))
    filled = (@@progress_percent / 100.0 * PROGRESS_WIDTH).round.to_i
    bar = "█" * filled + "░" * (PROGRESS_WIDTH - filled)
    STDERR.print "\r\e[K #{bar} #{@@progress_percent.round.to_i}%  #{detail}"
    STDERR.flush
    @@progress_shown = true
  end

  # Erase the bar before anything else writes to stderr, so a half-drawn frame never
  # ends up spliced into an error message.
  def self.progress_clear : Nil
    return unless @@progress_shown
    STDERR.print "\r\e[K"
    STDERR.flush
    @@progress_shown = false
  end

  # A monotonic reading, spelled for whichever compiler is building this.
  #
  # Crystal 1.21 deprecated Time.monotonic in favour of Time.instant, but CI and the
  # Linux release build pin 1.13, where Time.instant does not exist -- so neither name
  # compiles everywhere and `--error-on-warnings` fails on one or the other. Choosing at
  # compile time keeps both green. No return type: 1.21 hands back a Time::Instant and
  # 1.13 a Time::Span, and only the difference between two readings has to be a Span.
  private def self.monotonic_now
    {% if compare_versions(Crystal::VERSION, "1.21.0") >= 0 %}
      Time.instant
    {% else %}
      Time.monotonic
    {% end %}
  end

  # Watches one import to a terminal state, rendering progress as it goes. Every exit
  # path comes back as a PollOutcome -- the caller maps it to output and an exit code.
  def self.poll_import(id : String, json : Bool) : PollOutcome
    interrupted = false
    Signal::INT.trap { interrupted = true }
    progress_reset

    started = monotonic_now
    interval = POLL_FIRST_INTERVAL
    failures = 0
    last_body = nil.as(String?)

    loop do
      return finish_poll(PollDecision::Interrupted, last_body, nil) if interrupted

      resp = Client.get("/api/v1/imports/#{URI.encode_path(id)}")
      state = nil.as(String?)

      if resp.success? && (import = poll_parse(resp.body))
        last_body = resp.body
        state = import["state"]?.try(&.as_s?)
        # A 200 with no state is as useless as no 200 at all -- count it, so a broken
        # payload gives up instead of polling until the 15-minute timeout.
        failures = state ? 0 : failures + 1
        progress_tick(poll_percent(import), poll_detail(import)) if state && progress?(json)
      elsif poll_hard_failure?(resp.status)
        return finish_poll(PollDecision::HttpError, last_body, resp)
      else
        failures += 1
      end

      elapsed = (monotonic_now - started).total_seconds
      decision = poll_decision(state, elapsed, failures)
      unless decision.continue?
        return finish_poll(decision, last_body, resp.success? ? nil : resp)
      end

      if poll_sleep(interval) { interrupted }
        return finish_poll(PollDecision::Interrupted, last_body, nil)
      end
      interval = poll_interval(interval)
    end
  end

  private def self.finish_poll(decision : PollDecision, body : String?, resp : Client::Response?) : PollOutcome
    progress_clear
    PollOutcome.new(decision, body, resp)
  end

  private def self.poll_parse(body : String) : JSON::Any?
    JSON.parse(body)["import"]?
  rescue JSON::ParseException
    nil
  end

  # percentage_complete is a Rails decimal; accept either JSON shape rather than
  # silently rendering 0% if it ever serializes as an integer.
  private def self.poll_percent(import : JSON::Any) : Float64
    raw = import["percentage_complete"]?
    return 0.0 unless raw
    raw.as_f? || raw.as_i?.try(&.to_f) || 0.0
  end

  private def self.poll_detail(import : JSON::Any) : String
    counts = import["counts"]?
    return import["state"]?.try(&.as_s?) || "" unless counts
    parts = [] of String
    parts << "#{count_of(counts, "imported")} imported"
    {"duplicate", "invalid"}.each do |key|
      n = count_of(counts, key)
      parts << "#{n} #{key}" if n > 0
    end
    parts.join(" · ")
  end

  def self.count_of(counts : JSON::Any, key : String) : Int64
    counts[key]?.try(&.as_i64?) || 0_i64
  end

  # Sleeps in slices so Ctrl-C lands within POLL_SLICE instead of after a full tick.
  # Returns true when the wait was cut short.
  private def self.poll_sleep(seconds : Float64, &interrupted : -> Bool) : Bool
    waited = 0.0
    while waited < seconds
      return true if interrupted.call
      slice = Math.min(POLL_SLICE, seconds - waited)
      sleep slice.seconds
      waited += slice
    end
    interrupted.call
  end

  # Column padding measured in terminal cells rather than codepoints. A CJK header like
  # メールアドレス occupies two cells per character, so String#ljust leaves the arrows in
  # an import mapping ragged for exactly the Japanese files this has to render.
  WIDE_CHAR_RANGES = [
    0x1100..0x115F,   # Hangul Jamo
    0x2E80..0xA4CF,   # CJK radicals, kana, ideographs, Yi
    0xAC00..0xD7A3,   # Hangul syllables
    0xF900..0xFAFF,   # CJK compatibility ideographs
    0xFE30..0xFE6F,   # CJK compatibility forms
    0xFF00..0xFF60,   # full-width forms
    0xFFE0..0xFFE6,
    0x1F300..0x1F64F, # emoji
    0x20000..0x3FFFD, # CJK extension B and beyond
  ]

  def self.display_width(text : String) : Int32
    text.each_char.sum { |char| wide_char?(char) ? 2 : 1 }
  end

  def self.wide_char?(char : Char) : Bool
    ord = char.ord
    WIDE_CHAR_RANGES.any?(&.includes?(ord))
  end

  # "1 row" / "2 rows". Counts in import output are frequently 1, and "1 rows" in a
  # summary line reads like a formatting bug in the import itself.
  def self.plural(count : Int, singular : String, plural : String = "") : String
    label = count == 1 ? singular : (plural.presence || "#{singular}s")
    "#{count} #{label}"
  end

  # failed_reason can carry a full Ruby backtrace. Humans get its first line, capped;
  # the complete text is still one `rd imports get ID -j` away.
  def self.first_line(text : String?) : String?
    return nil unless text
    line = text.lines.first?.try(&.strip)
    return nil if line.nil? || line.empty?
    line.size > 300 ? "#{line[0, 300]}…" : line
  end

  def self.pad_to(text : String, width : Int32) : String
    padding = width - display_width(text)
    padding > 0 ? text + " " * padding : text
  end
end

require "./spec_helper"
require "http/formdata"
require "http/server"
require "file_utils"

private def with_isolated_home(&)
  previous_home = ENV["HOME"]?
  previous_token = ENV["RIGHTDESK_TOKEN"]?
  previous_url = ENV["RIGHTDESK_URL"]?
  tmp_home = File.tempname("rightdesk-client-spec")
  Dir.mkdir_p(tmp_home)
  ENV["HOME"] = tmp_home

  begin
    yield
  ensure
    previous_home ? (ENV["HOME"] = previous_home) : ENV.delete("HOME")
    previous_token ? (ENV["RIGHTDESK_TOKEN"] = previous_token) : ENV.delete("RIGHTDESK_TOKEN")
    previous_url ? (ENV["RIGHTDESK_URL"] = previous_url) : ENV.delete("RIGHTDESK_URL")
    FileUtils.rm_rf(tmp_home)
  end
end

# Parses a multipart body back into its parts, the way a server would.
private def parse_multipart(body : String, content_type : String)
  boundary = content_type[/boundary="?([^";]+)"?/, 1]
  fields = {} of String => String
  files = {} of String => {String, String, Bytes}

  HTTP::FormData.parse(IO::Memory.new(body), boundary) do |part|
    if filename = part.filename
      bytes = part.body.getb_to_end
      files[part.name] = {filename, part.headers["Content-Type"]? || "", bytes}
    else
      fields[part.name] = part.body.gets_to_end
    end
  end

  {fields, files}
end

# A CP932 row: 山田 is 8e 52 93 63, which is not valid UTF-8. Written as Bytes rather
# than a string literal so the intent is unambiguous, and asserted byte-for-byte.
private def cp932_csv_bytes : Bytes
  io = IO::Memory.new
  io.print "first_name,email\n"
  io.write Bytes[0x8e, 0x52, 0x93, 0x63]
  io.print ",yamada@x.test\n"
  io.to_slice
end

describe RightDesk::Client do
  # Exercises Client.write_multipart_body itself -- the same code post_multipart runs --
  # so a wrong field name, a missing builder.finish or a mismatched boundary fails here.
  describe ".write_multipart_body" do
    it "carries the fields and the file, and parses back" do
      io = IO::Memory.new
      content_type = RightDesk::Client.write_multipart_body(
        io,
        {"import[item_type]" => "contact", "import[start]" => "true"},
        "import[file]", "contacts.csv", "text/csv",
        "first_name,email\nAda,ada@x.test\n"
      )

      content_type.should start_with("multipart/form-data")
      fields, files = parse_multipart(io.to_s, content_type)

      fields["import[item_type]"].should eq("contact")
      fields["import[start]"].should eq("true")
      filename, part_type, bytes = files["import[file]"]
      filename.should eq("contacts.csv")
      part_type.should eq("text/csv")
      String.new(bytes).should eq("first_name,email\nAda,ada@x.test\n")
    end

    # Guards the boundary/terminator: without builder.finish the body has no closing
    # delimiter and HTTP::FormData.parse yields nothing.
    it "terminates the body so every part is parseable" do
      io = IO::Memory.new
      content_type = RightDesk::Client.write_multipart_body(
        io, {"a" => "1"}, "f", "x.csv", "text/csv", "data"
      )

      fields, files = parse_multipart(io.to_s, content_type)
      fields.size.should eq(1)
      files.size.should eq(1)
    end

    it "passes non-UTF-8 file bytes through untouched" do
      original = cp932_csv_bytes
      original.should_not eq(Bytes.empty)

      io = IO::Memory.new
      content_type = RightDesk::Client.write_multipart_body(
        io, {} of String => String, "import[file]", "cp932.csv", "text/csv", original
      )

      _, files = parse_multipart(io.to_s, content_type)
      _, _, round_tripped = files["import[file]"]

      round_tripped.to_a.should eq(original.to_a)
      String.new(round_tripped).valid_encoding?.should be_false
    end

    it "accepts an IO as the file source" do
      io = IO::Memory.new
      content_type = RightDesk::Client.write_multipart_body(
        io, {} of String => String, "import[file]", "x.csv", "text/csv",
        IO::Memory.new("a,b\n1,2\n")
      )

      _, files = parse_multipart(io.to_s, content_type)
      String.new(files["import[file]"][2]).should eq("a,b\n1,2\n")
    end
  end

  # End to end over a real socket: proves post_multipart's own assembly, the streamed
  # temp-file body, the Content-Type header it sends and the Bearer injection.
  describe ".post_multipart" do
    it "uploads the file and its fields to a live server" do
      received_type = nil
      received_auth = nil
      received_body = nil

      server = HTTP::Server.new do |context|
        received_type = context.request.headers["Content-Type"]?
        received_auth = context.request.headers["Authorization"]?
        received_body = context.request.body.try(&.gets_to_end)
        context.response.status_code = 201
        context.response.print %({"ok":true})
      end
      address = server.bind_tcp("127.0.0.1", 0)
      spawn { server.listen }

      with_isolated_home do
        ENV["RIGHTDESK_TOKEN"] = "probe-token"
        ENV["RIGHTDESK_URL"] = "http://127.0.0.1:#{address.port}"

        response = RightDesk::Client.post_multipart(
          "/api/v1/imports",
          {"import[item_type]" => "contact"},
          "import[file]", "cp932.csv", "text/csv", cp932_csv_bytes
        )

        response.status.should eq(201)
        response.success?.should be_true
      end

      server.close

      received_auth.should eq("Bearer probe-token")
      received_type.to_s.should start_with("multipart/form-data")

      fields, files = parse_multipart(received_body.not_nil!, received_type.not_nil!)
      fields["import[item_type]"].should eq("contact")
      filename, _, bytes = files["import[file]"]
      filename.should eq("cp932.csv")
      bytes.to_a.should eq(cp932_csv_bytes.to_a)
    end
  end

  describe "timeouts" do
    it "bounds every request, and allows longer for an upload" do
      RightDesk::Client::CONNECT_TIMEOUT.should eq(10.seconds)
      RightDesk::Client::READ_TIMEOUT.should eq(60.seconds)
      RightDesk::Client::UPLOAD_READ_TIMEOUT.should be > RightDesk::Client::READ_TIMEOUT
    end
  end

  # Every expected failure comes back as a Response, so commands need one code path and a
  # polling loop can count consecutive failures without rescuing.
  describe "failures" do
    it "synthesizes a 401 when there is no token" do
      with_isolated_home do
        ENV.delete("RIGHTDESK_TOKEN")

        response = RightDesk::Client.get("/api/v1/imports")

        response.status.should eq(401)
        response.success?.should be_false
        response.body.should contain("missing_token")
      end
    end

    it "synthesizes a response when the connection is refused" do
      with_isolated_home do
        ENV["RIGHTDESK_TOKEN"] = "probe-token"
        # Port 1 on loopback: nothing listens, so connect fails immediately.
        ENV["RIGHTDESK_URL"] = "http://127.0.0.1:1"

        response = RightDesk::Client.get("/api/v1/imports")

        response.status.should eq(RightDesk::Client::CONNECTION_FAILED_STATUS)
        response.success?.should be_false
        response.body.should contain("connection_failed")
      end
    end

  end
end

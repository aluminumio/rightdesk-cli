require "./spec_helper"
require "http/formdata"
require "file_utils"

# Client.post_multipart is the only way a file reaches the API, and the repo has no HTTP
# mocking — so the body it builds is verified by building one directly with the same
# stdlib calls and parsing it back. The request itself stays untested.
describe RightDesk::Client do
  describe "multipart bodies" do
    it "carries the fields and the file, and parses back" do
      io = IO::Memory.new
      builder = HTTP::FormData::Builder.new(io)
      builder.field("import[item_type]", "contact")
      builder.file(
        "import[file]",
        IO::Memory.new("first_name,email\nAda,ada@x.test\n"),
        HTTP::FormData::FileMetadata.new(filename: "contacts.csv"),
        HTTP::Headers{"Content-Type" => "text/csv"}
      )
      builder.finish
      boundary = builder.content_type[/boundary="?([^";]+)"?/, 1]

      fields = {} of String => String
      files = {} of String => {String, String}
      HTTP::FormData.parse(IO::Memory.new(io.to_s), boundary) do |part|
        if filename = part.filename
          files[part.name] = {filename, part.body.gets_to_end}
        else
          fields[part.name] = part.body.gets_to_end
        end
      end

      fields["import[item_type]"].should eq("contact")
      files["import[file]"][0].should eq("contacts.csv")
      files["import[file]"][1].should eq("first_name,email\nAda,ada@x.test\n")
    end

    # A CP932 or Latin-1 export must arrive byte-for-byte; the server sniffs the encoding.
    it "does not transcode the file bytes" do
      original = "first_name,email\n\x8eR\x93c,a@x.test\n"

      io = IO::Memory.new
      builder = HTTP::FormData::Builder.new(io)
      builder.file(
        "import[file]",
        IO::Memory.new(original),
        HTTP::FormData::FileMetadata.new(filename: "cp932.csv"),
        HTTP::Headers{"Content-Type" => "text/csv"}
      )
      builder.finish
      boundary = builder.content_type[/boundary="?([^";]+)"?/, 1]

      round_tripped = nil
      HTTP::FormData.parse(IO::Memory.new(io.to_s), boundary) do |part|
        round_tripped = part.body.gets_to_end
      end

      round_tripped.should eq(original)
    end
  end

  describe "timeouts" do
    it "bounds every request, and allows longer for an upload" do
      RightDesk::Client::CONNECT_TIMEOUT.should eq(10.seconds)
      RightDesk::Client::READ_TIMEOUT.should eq(60.seconds)
      RightDesk::Client::UPLOAD_READ_TIMEOUT.should be > RightDesk::Client::READ_TIMEOUT
    end
  end

  # HOME is redirected so this never reads the real ~/.netrc -- and so the request short
  # circuits locally instead of reaching a live host, which is the whole point of the
  # early return being before the socket is opened.
  describe "without a token" do
    it "synthesizes a 401 rather than raising" do
      previous_home = ENV["HOME"]?
      tmp_home = File.tempname("rightdesk-client-spec")
      Dir.mkdir_p(tmp_home)
      ENV["HOME"] = tmp_home
      ENV.delete("RIGHTDESK_TOKEN")

      begin
        response = RightDesk::Client.get("/api/v1/imports")

        response.status.should eq(401)
        response.success?.should be_false
        response.body.should contain("missing_token")
      ensure
        previous_home ? (ENV["HOME"] = previous_home) : ENV.delete("HOME")
        FileUtils.rm_rf(tmp_home)
      end
    end
  end
end

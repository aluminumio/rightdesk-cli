require "http/client"
require "http/formdata"
require "json"
require "uri"
require "./config"
require "./auth"

module RightDesk
  # Thin HTTP wrapper: injects the Bearer token, targets BASE_URL, returns a
  # tiny Response the commands can branch on. Kept minimal on purpose — the
  # commands own their own JSON shaping/output.
  module Client
    # Without these a hung socket blocks forever: HTTP::Client.exec takes no timeout, so
    # a stalled connection used to wedge the command with no output and no way out but
    # Ctrl-C. Uploads and polling loops make that a real failure mode rather than a
    # theoretical one.
    CONNECT_TIMEOUT = 10.seconds
    READ_TIMEOUT    = 60.seconds
    # A multipart body can be tens of megabytes on a slow uplink.
    UPLOAD_READ_TIMEOUT = 300.seconds

    record Response, status : Int32, body : String do
      def success? : Bool
        status >= 200 && status < 300
      end
    end

    # `query` is an already-encoded query string (e.g. from `URI::Params.build`).
    def self.get(path : String, query : String? = nil) : Response
      request("GET", path, query: query)
    end

    def self.post(path : String, body : String? = nil) : Response
      request("POST", path, body: body)
    end

    def self.patch(path : String, body : String? = nil) : Response
      request("PATCH", path, body: body)
    end

    def self.delete(path : String) : Response
      request("DELETE", path)
    end

    # multipart/form-data upload. `fields` are plain form values; the file is sent as
    # `file_field` with the given filename and content type.
    def self.post_multipart(path : String, fields : Hash(String, String),
                            file_field : String, filename : String,
                            content_type : String, data : String) : Response
      io = IO::Memory.new
      builder = HTTP::FormData::Builder.new(io)
      fields.each { |name, value| builder.field(name, value) }
      builder.file(
        file_field,
        IO::Memory.new(data),
        HTTP::FormData::FileMetadata.new(filename: filename),
        HTTP::Headers{"Content-Type" => content_type}
      )
      builder.finish

      request("POST", path,
        body: io.to_s,
        content_type: builder.content_type,
        read_timeout: UPLOAD_READ_TIMEOUT)
    end

    private def self.request(method : String, path : String,
                             query : String? = nil, body : String? = nil,
                             content_type : String? = nil,
                             read_timeout : Time::Span = READ_TIMEOUT) : Response
      # No local token → synthesize a 401 so callers take the normal auth-failure
      # path (exit code 3, "run rd login") instead of raising.
      token = RightDesk::Auth.token
      unless token
        return Response.new(401, %({"error":"Not authenticated","code":"missing_token"}))
      end

      uri = URI.parse("#{RightDesk::Config.base_url}#{path}")
      uri.query = query if query && !query.empty?

      headers = HTTP::Headers{"Authorization" => "Bearer #{token}"}
      headers["Content-Type"] = content_type || "application/json" if body

      client = HTTP::Client.new(uri)
      client.connect_timeout = CONNECT_TIMEOUT
      client.read_timeout = read_timeout

      begin
        response = client.exec(method, uri.request_target, headers: headers, body: body)
        Response.new(response.status_code, response.body)
      ensure
        client.close
      end
    end
  end
end

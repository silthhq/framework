require "http/client"
require "http/formdata"

module Silth
  # Expressive HTTP client with retries, timeouts, tracing and test fakes.
  #
  # ```
  # response = Silth::HTTPClient.new
  #   .base_url("https://api.example.com")
  #   .bearer(token)
  #   .timeout(5.seconds)
  #   .retry(3)
  #   .get("/users", query: {"page" => "2"})
  # response.ok?       # => true
  # response.json["data"]
  #
  # Silth::HTTPClient.fake("api.example.com/*" => {200, %({"ok":true})})
  # ```
  #
  # Files go as `multipart/form-data`; binary responses are read with `bytes`:
  #
  # ```
  # pdf = Silth::HTTPClient.new.base_url("http://gotenberg:3000")
  #   .post("/forms/chromium/convert/html", multipart: [
  #     {"files", Silth::HTTPClient::File.new("index.html", html, "text/html")},
  #     {"paperWidth", "8.27"},
  #   ])
  #   .raise_for_status!
  #   .bytes
  # ```
  class HTTPClient
    # A file sent in a multipart request.
    record File, filename : String, content : Bytes | String, content_type : String = "application/octet-stream"

    alias Part = String | File
    class Error < Silth::Error
      getter response : Response

      def initialize(@response : Response)
        super("HTTP #{@response.status} from #{@response.url}")
      end
    end

    struct Response
      getter status : Int32
      getter body : String
      getter headers : HTTP::Headers
      getter url : String

      def initialize(@status, @body, @headers, @url)
      end

      def ok? : Bool
        200 <= @status < 300
      end

      def success? : Bool
        ok?
      end

      def client_error? : Bool
        400 <= @status < 500
      end

      def server_error? : Bool
        @status >= 500
      end

      def json : JSON::Any
        JSON.parse(@body)
      end

      # The raw body (PDFs, images, archives).
      def bytes : Bytes
        @body.to_slice
      end

      def parse(type : T.class) : T forall T
        T.from_json(@body)
      end

      def header(name : String) : String?
        @headers[name]?
      end

      def raise_for_status! : self
        raise Error.new(self) unless ok?
        self
      end
    end

    @@fakes = [] of {Regex, Proc(HTTP::Request, Response)}
    @@recorded = [] of HTTP::Request
    @@faking = false

    @base = ""
    @headers = HTTP::Headers.new
    @timeout = 30.seconds
    @retries = 0
    @retry_delay = 200.milliseconds

    def initialize
      @headers["User-Agent"] = "Silth/#{Silth::VERSION}"
    end

    def self.get(url : String, **opts) : Response
      new.get(url, **opts)
    end

    def self.post(url : String, **opts) : Response
      new.post(url, **opts)
    end

    def base_url(url : String) : self
      @base = url.rchop('/')
      self
    end

    def header(name : String, value : String) : self
      @headers[name] = value
      self
    end

    def bearer(token : String) : self
      header("Authorization", "Bearer #{token}")
    end

    def basic_auth(user : String, password : String) : self
      header("Authorization", "Basic #{Base64.strict_encode("#{user}:#{password}")}")
    end

    def accept_json : self
      header("Accept", "application/json")
    end

    def timeout(span : Time::Span) : self
      @timeout = span
      self
    end

    def retry(times : Int32, delay : Time::Span = 200.milliseconds) : self
      @retries = times
      @retry_delay = delay
      self
    end

    def get(path : String, query : Hash(String, String)? = nil) : Response
      request("GET", path, query: query)
    end

    def delete(path : String, query : Hash(String, String)? = nil) : Response
      request("DELETE", path, query: query)
    end

    {% for verb in %w(post put patch) %}
      # Sends *json* (any value), *form* (URL encoded), *multipart* (fields and
      # `File`s, a name may repeat) or a raw *body*.
      def {{verb.id}}(path : String, json = nil, form : Hash(String, String)? = nil, body : String | Bytes | Nil = nil,
                      multipart : Hash(String, Part) | Array({String, Part}) | Nil = nil) : Response
        request({{verb.upcase}}, path, json: json, form: form, body: body, multipart: multipart)
      end
    {% end %}

    def request(method : String, path : String, query : Hash(String, String)? = nil, json = nil, form : Hash(String, String)? = nil,
                body : String | Bytes | Nil = nil, multipart : Hash(String, Part) | Array({String, Part}) | Nil = nil) : Response
      url = path.starts_with?("http") ? path : "#{@base}/#{path.lchop('/')}"
      url += (url.includes?('?') ? "&" : "?") + URI::Params.encode(query) if query && !query.empty?
      headers = @headers.dup
      payload = body.is_a?(Bytes) ? String.new(body) : body
      if json
        headers["Content-Type"] = "application/json"
        payload = json.to_json
      elsif form
        headers["Content-Type"] = "application/x-www-form-urlencoded"
        payload = URI::Params.encode(form)
      elsif parts = multipart
        boundary = "silth-#{Random::Secure.hex(12)}"
        headers["Content-Type"] = "multipart/form-data; boundary=#{boundary}"
        payload = HTTPClient.multipart_body(parts.to_a, boundary)
      end
      Telemetry.inject(headers)
      attempt = 0
      loop do
        attempt += 1
        started = Time.instant
        response = perform(method, url, headers, payload)
        Instrument.publish(Instrument::HTTPCall.new(method, url, response.status, Time.instant - started))
        if response.server_error? && attempt <= @retries
          sleep @retry_delay * attempt
          next
        end
        return response
      rescue ex : IO::Error | ::Socket::Error
        raise ex if attempt > @retries
        sleep @retry_delay * attempt
      end
    end

    private def perform(method : String, url : String, headers : HTTP::Headers, body : String?) : Response
      if @@faking
        request = HTTP::Request.new(method, url, headers, body)
        @@recorded << request
        @@fakes.each do |(pattern, responder)|
          return responder.call(request) if pattern.matches?(url)
        end
        return Response.new(200, "", HTTP::Headers.new, url)
      end
      uri = URI.parse(url)
      client = HTTP::Client.new(uri)
      client.connect_timeout = @timeout
      client.read_timeout = @timeout
      begin
        res = client.exec(method, uri.request_target, headers, body)
        Response.new(res.status_code, res.body, res.headers, url)
      ensure
        client.close
      end
    end

    # Encodes *parts* as a `multipart/form-data` body.
    def self.multipart_body(parts : Array({String, Part}), boundary : String) : String
      io = IO::Memory.new
      HTTP::FormData.build(io, boundary) do |form|
        parts.each do |(name, part)|
          case part
          in String
            form.field(name, part)
          in File
            content = part.content
            data = content.is_a?(Bytes) ? IO::Memory.new(content) : IO::Memory.new(content)
            form.file(name, data, HTTP::FormData::FileMetadata.new(filename: part.filename),
              HTTP::Headers{"Content-Type" => part.content_type})
          end
        end
      end
      io.to_s
    end

    # --- testing ----------------------------------------------------------------

    # Fakes every request whose URL matches the glob (`*` wildcard).
    def self.fake(stubs : Hash(String, {Int32, String})) : Nil
      @@faking = true
      stubs.each do |glob, (status, body)|
        pattern = Regex.new(Regex.escape(glob).gsub("\\*", ".*"))
        @@fakes << {pattern, ->(r : HTTP::Request) { Response.new(status, body, HTTP::Headers{"Content-Type" => "application/json"}, r.resource) }}
      end
    end

    def self.fake(glob : String = "*", &block : HTTP::Request -> Response) : Nil
      @@faking = true
      @@fakes << {Regex.new(Regex.escape(glob).gsub("\\*", ".*")), block}
    end

    def self.recorded : Array(HTTP::Request)
      @@recorded
    end

    def self.reset_fakes : Nil
      @@faking = false
      @@fakes.clear
      @@recorded.clear
    end
  end
end

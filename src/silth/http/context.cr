require "http/server"
require "mime"
require "./content_disposition"

class Fiber
  # :nodoc: request bound to the fiber currently serving it.
  property silth_context : Silth::Context?
  # :nodoc: free-form per fiber storage used by subsystems (db transactions, tracing…).
  property silth_locals : Hash(String, Silth::FiberLocal)?
end

module Silth
  # Marker for objects stored in fiber locals.
  module FiberLocal
  end

  # Everything about the request being served: wraps `HTTP::Server::Context`
  # and adds params, session, flash, route data, auth and response helpers.
  class Context
    getter raw : HTTP::Server::Context
    property route : Route?
    property route_params = {} of String => String
    property session : Session?
    property locale : String = "en"
    property csp_nonce : String?
    property auth_user : Auth::Authenticatable?
    property auth_token : Auth::AccessToken?
    getter store = {} of String => String
    getter id : String
    getter started_at : Time::Instant = Time.instant
    getter? responded = false
    @params : Params?
    @before_send = [] of -> Nil
    @body_filters = [] of Proc(String, String, String)
    @hooks_ran = false
    @flash : Flash?

    def initialize(@raw : HTTP::Server::Context)
      @id = @raw.request.headers["X-Request-Id"]?.try { |v| v[0, 64] if v.matches?(/\A[\w\-.]+\z/) } || Crypto.uuid7
    end

    def self.current? : Context?
      Fiber.current.silth_context
    end

    def self.current : Context
      current? || raise Error.new("No HTTP request is being served by the current fiber")
    end

    def request : HTTP::Request
      @raw.request
    end

    def response : HTTP::Server::Response
      @raw.response
    end

    def params : Params
      @params ||= Params.parse(request, route_params)
    end

    def params=(@params : Params)
    end

    def session : Session
      @session || raise Error.new("Session is not available: the route is not in the `web` middleware group")
    end

    def session? : Session?
      @session
    end

    def flash : Flash
      @flash ||= (s = @session) ? Flash.from_session(s) : Flash.new
    end

    def flash? : Flash?
      @flash
    end

    # --- request helpers -------------------------------------------------

    def method : String
      request.method.upcase
    end

    def path : String
      request.path
    end

    def host : String
      request.headers["X-Forwarded-Host"]?.try(&.split(',').first.strip) || request.headers["Host"]? || "localhost"
    end

    def scheme : String
      request.headers["X-Forwarded-Proto"]?.try(&.split(',').first.strip) || (Silth.config.bool("app.https", false) ? "https" : "http")
    end

    def secure? : Bool
      scheme == "https"
    end

    def base_url : String
      "#{scheme}://#{host}"
    end

    def url : String
      "#{base_url}#{request.resource}"
    end

    def header(name : String) : String?
      request.headers[name]?
    end

    def user_agent : String?
      header("User-Agent")
    end

    def referer : String?
      header("Referer")
    end

    def remote_ip : String
      if forwarded = header("X-Forwarded-For")
        return forwarded.split(',').first.strip
      end
      header("X-Real-Ip") || (request.remote_address.as?(::Socket::IPAddress).try(&.address) || "127.0.0.1")
    end

    def xhr? : Bool
      header("X-Requested-With").try(&.downcase) == "xmlhttprequest"
    end

    def accepts?(mime : String) : Bool
      (header("Accept") || "").includes?(mime)
    end

    # True for API style requests: JSON accept header, JSON body, XHR or `.json` paths.
    def wants_json? : Bool
      accept = header("Accept") || ""
      return true if accept.includes?("application/json") || accept.includes?("+json")
      return true if path.ends_with?(".json")
      return true if (header("Content-Type") || "").includes?("json") && !accept.includes?("text/html")
      false
    end

    def get? : Bool
      method == "GET" || method == "HEAD"
    end

    def cookies : HTTP::Cookies
      request.cookies
    end

    def set_cookie(name : String, value : String, max_age : Time::Span? = nil, http_only = true, secure : Bool? = nil, same_site = HTTP::Cookie::SameSite::Lax, path = "/") : Nil
      response.cookies << HTTP::Cookie.new(name, value, path: path, http_only: http_only, secure: secure.nil? ? secure? : secure,
        samesite: same_site, expires: max_age.try { |m| Time.utc + m })
    end

    def delete_cookie(name : String, path = "/") : Nil
      response.cookies << HTTP::Cookie.new(name, "", path: path, expires: Time.unix(0))
    end

    # Signed cookie (tamper proof, readable by the client).
    def set_signed_cookie(name : String, value : String, max_age : Time::Span? = nil) : Nil
      set_cookie(name, Silth.verifier("cookies").generate(value, expires_in: max_age), max_age)
    end

    def signed_cookie(name : String) : String?
      cookies[name]?.try { |c| Silth.verifier("cookies").verify?(c.value) }
    end

    # Encrypted cookie (confidential and tamper proof).
    def set_encrypted_cookie(name : String, value : String, max_age : Time::Span? = nil) : Nil
      set_cookie(name, Silth.encryptor("cookies").encrypt(value), max_age)
    end

    def encrypted_cookie(name : String) : String?
      cookies[name]?.try { |c| Silth.encryptor("cookies").decrypt?(c.value) }
    end

    # --- response helpers ------------------------------------------------

    def status : Int32
      response.status_code
    end

    def status=(code : Int32 | HTTP::Status) : Nil
      response.status = code.is_a?(HTTP::Status) ? code : HTTP::Status.new(code)
    end

    def set_header(name : String, value : String) : Nil
      response.headers[name] = value
    end

    def mark_responded! : Nil
      @responded = true
    end

    # Registers a callback executed right before the response headers are sent
    # (sessions, flash, cookies and timing headers rely on it).
    def before_send(&block : -> Nil) : Nil
      @before_send << block
    end

    # Registers a filter applied to buffered bodies: `(body, content_type) -> body`.
    def filter_body(&block : String, String -> String) : Nil
      @body_filters << block
    end

    # :nodoc:
    def run_before_send : Nil
      return if @hooks_ran
      @hooks_ran = true
      @before_send.each &.call
    end

    def params? : Params?
      @params
    end

    def html(body : String, status : Int32 = 200) : Nil
      send_body(body, "text/html; charset=utf-8", status)
    end

    def text(body : String, status : Int32 = 200) : Nil
      send_body(body, "text/plain; charset=utf-8", status)
    end

    def xml(body : String, status : Int32 = 200) : Nil
      send_body(body, "application/xml; charset=utf-8", status)
    end

    def json(data, status : Int32 = 200) : Nil
      send_body(data.is_a?(String) ? data : data.to_json, "application/json", status)
    end

    # RFC 9457 problem details response.
    def problem(status : Int32, title : String, detail : String? = nil, errors = nil) : Nil
      body = JSON.build do |j|
        j.object do
          j.field "type", "about:blank"
          j.field "title", title
          j.field "status", status
          j.field "detail", detail if detail
          j.field "errors", errors if errors
          j.field "instance", path
        end
      end
      send_body(body, "application/problem+json", status)
    end

    def send_body(body : String, content_type : String, status : Int32 = 200) : Nil
      self.status = status
      response.content_type = content_type
      run_before_send
      @body_filters.each { |f| body = f.call(body, content_type) }
      response.content_length = body.bytesize
      response.print(body) unless method == "HEAD"
      @responded = true
    end

    def redirect(to : String, status : Int32 = 302) : Nil
      self.status = status
      response.headers["Location"] = to
      run_before_send
      response.content_length = 0
      @responded = true
    end

    def redirect_back(fallback : String = "/") : Nil
      target = referer
      target = fallback unless target && same_origin?(target)
      redirect(target)
    end

    private def same_origin?(url : String) : Bool
      uri = URI.parse(url)
      uri.host.nil? || uri.host == host.split(':').first
    rescue
      false
    end

    def head(status : Int32) : Nil
      self.status = status
      run_before_send
      response.content_length = 0
      @responded = true
    end

    def no_content : Nil
      head(204)
    end

    def send_file(file_path : String, filename : String? = nil, disposition : String = "inline", content_type : String? = nil,
                  headers : Hash(String, String)? = nil) : Nil
      raise NotFound.new unless File.file?(file_path)
      self.status = 200
      response.content_type = content_type || MIME.from_filename(file_path, "application/octet-stream")
      response.headers["Content-Disposition"] = ContentDisposition.format(disposition, filename || File.basename(file_path))
      headers.try &.each { |name, value| response.headers[name] = value }
      response.content_length = File.size(file_path)
      run_before_send
      File.open(file_path) { |f| IO.copy(f, response) } unless method == "HEAD"
      @responded = true
    end

    # Sends bytes as a download (`disposition: "inline"` to display them).
    # *headers* are added last, and may replace the defaults:
    # `ctx.send_data(pdf, "facture-été.pdf", "application/pdf", headers: {"Cache-Control" => "no-store"})`.
    def send_data(data : Bytes | String, filename : String, content_type : String = "application/octet-stream", disposition = "attachment",
                  headers : Hash(String, String)? = nil) : Nil
      self.status = 200
      response.content_type = content_type
      response.headers["Content-Disposition"] = ContentDisposition.format(disposition, filename)
      headers.try &.each { |name, value| response.headers[name] = value }
      response.content_length = data.bytesize
      run_before_send
      response.write(data.to_slice)
      @responded = true
    end

    # Streams a chunked response. The block receives the response IO.
    def stream(content_type : String = "text/plain; charset=utf-8", & : IO ->) : Nil
      self.status = 200 if response.status_code == 200
      response.content_type = content_type
      response.headers["X-Accel-Buffering"] = "no"
      run_before_send
      @responded = true
      yield response
    end

    # Server-Sent Events.
    #
    # ```
    # ctx.sse do |events|
    #   5.times { |i| events.send({count: i}.to_json, event: "tick"); sleep 1.second }
    # end
    # ```
    def sse(& : SSE ->) : Nil
      response.headers["Cache-Control"] = "no-cache"
      stream("text/event-stream") do |io|
        yield SSE.new(io)
      end
    end

    struct SSE
      def initialize(@io : IO)
      end

      def send(data : String, event : String? = nil, id : String? = nil, retry : Int32? = nil) : Nil
        @io << "id: " << id << '\n' if id
        @io << "event: " << event << '\n' if event
        @io << "retry: " << retry << '\n' if retry
        data.each_line { |line| @io << "data: " << line << '\n' }
        @io << '\n'
        @io.flush
      end

      def comment(text : String) : Nil
        @io << ": " << text << "\n\n"
        @io.flush
      end
    end

    def abort!(status : Int32, message : String? = nil) : NoReturn
      raise HTTPError.new(HTTP::Status.new(status), message)
    end

    def url_for(name : String | Symbol, **params) : String
      Silth.router.url_for(name.to_s, **params)
    end

    def duration_ms : Float64
      (Time.instant - @started_at).total_milliseconds
    end
  end
end

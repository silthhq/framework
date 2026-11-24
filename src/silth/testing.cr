require "spec"
require "../silth"

module Silth
  # Testing helpers: in-process HTTP client, transactional specs, fakes and
  # browser tests through WebDriver.
  #
  # ```
  # # spec/spec_helper.cr
  # require "spec"
  # require "silth/testing"
  # require "../src/app"
  # Silth::Testing.setup
  #
  # describe PostsController do
  #   it "lists posts" do
  #     PostFactory.create(title: "Hello")
  #     client.get("/posts").should contain("Hello")
  #   end
  # end
  # ```
  module Testing
    class Rollback < Exception; end

    @@client : TestClient?
    @@setup = false

    # Boots the app in the test environment, migrates the database and wraps
    # every example in a rolled back transaction.
    def self.setup(migrate : Bool = true, transactional : Bool = true, fresh : Bool = false) : Nil
      return if @@setup
      @@setup = true
      Silth.env = "test"
      Silth.boot
      if migrate && DB.configured?
        fresh ? Migrator.new.fresh : Migrator.new.migrate
      end
      Spec.before_each do
        @@client = nil
        Mailer.fake
        Silth.cache.clear
        HTTPClient.reset_fakes
        Events.unfake
        Queue.unfake
        Notifications.unfake
      end
      if transactional && DB.configured?
        Spec.around_each do |example|
          begin
            DB.connection.transaction do
              example.run
              raise Rollback.new
            end
          rescue Rollback
          end
        end
      end
    end

    def self.client : TestClient
      @@client ||= TestClient.new
    end

    struct TestResponse
      getter status : Int32
      getter headers : HTTP::Headers
      getter body : String

      def initialize(@status, @headers, @body)
      end

      def ok? : Bool
        200 <= @status < 300
      end

      def success? : Bool
        ok?
      end

      def redirect? : Bool
        300 <= @status < 400
      end

      def not_found? : Bool
        @status == 404
      end

      def forbidden? : Bool
        @status == 403
      end

      def unauthorized? : Bool
        @status == 401
      end

      def unprocessable? : Bool
        @status == 422
      end

      def location : String?
        @headers["Location"]?
      end

      def json : JSON::Any
        JSON.parse(@body)
      end

      def includes?(text : String) : Bool
        @body.includes?(text)
      end

      def header(name : String) : String?
        @headers[name]?
      end

      def to_s(io : IO) : Nil
        io << "HTTP " << @status << " (" << @body.size << " bytes)"
      end
    end

    # Runs requests through the application without opening a socket.
    # Cookies (session, flash) persist between calls like in a browser.
    class TestClient
      getter cookies = HTTP::Cookies.new
      getter default_headers = HTTP::Headers{"Host" => "localhost", "Accept" => "text/html"}

      def get(path : String, headers : HTTP::Headers? = nil) : TestResponse
        request("GET", path, nil, headers)
      end

      def delete(path : String, headers : HTTP::Headers? = nil) : TestResponse
        request("DELETE", path, nil, headers)
      end

      {% for verb in %w(post put patch) %}
        def {{verb.id}}(path : String, form : Hash(String, String)? = nil, json = nil, headers : HTTP::Headers? = nil) : TestResponse
          h = headers || HTTP::Headers.new
          body = nil
          if j = json
            h["Content-Type"] = "application/json"
            h["Accept"] = "application/json"
            body = j.is_a?(String) ? j : j.to_json
          elsif f = form
            h["Content-Type"] = "application/x-www-form-urlencoded"
            body = URI::Params.encode(f)
          end
          request({{verb.upcase}}, path, body, h)
        end
      {% end %}

      def get_json(path : String) : TestResponse
        get(path, HTTP::Headers{"Accept" => "application/json"})
      end

      # Follows the `Location` header of a redirect.
      def follow(response : TestResponse) : TestResponse
        location = response.location || raise "Response is not a redirect"
        get(location)
      end

      # Authenticates the following requests as `user` (session based).
      def acting_as(user : Auth::Authenticatable) : self
        session = Session.new
        session[Auth::SESSION_ID] = user.auth_id
        session[Auth::SESSION_TYPE] = user.class.name
        session[Auth::SESSION_HASH] = user.password_fingerprint
        value = Silth.encryptor("session").encrypt({"i" => session.id, "d" => session.data}.to_json)
        @cookies << HTTP::Cookie.new(Silth.config.string("session.cookie", "_silth_session"), value)
        self
      end

      def with_token(token : String) : self
        @default_headers["Authorization"] = "Bearer #{token}"
        self
      end

      def request(method : String, path : String, body : String? = nil, headers : HTTP::Headers? = nil) : TestResponse
        h = @default_headers.dup
        headers.try &.each { |k, v| h[k] = v }
        @cookies.add_request_headers(h)
        request = HTTP::Request.new(method, path, h, body)
        io = IO::Memory.new
        response = HTTP::Server::Response.new(io)
        Silth.app.call(HTTP::Server::Context.new(request, response))
        response.close
        parsed = HTTP::Client::Response.from_io(IO::Memory.new(io.to_s), ignore_body: method == "HEAD")
        parsed.cookies.each { |c| c.value.empty? ? @cookies.delete(c.name) : (@cookies << c) }
        TestResponse.new(parsed.status_code, parsed.headers, parsed.body? || "")
      end
    end

    struct RedirectExpectation
      def initialize(@path : String)
      end

      def match(actual : TestResponse) : Bool
        actual.redirect? && (actual.location == @path || actual.location.try(&.ends_with?(@path)) == true)
      end

      def failure_message(actual : TestResponse) : String
        "Expected a redirect to #{@path}, got #{actual.status} #{actual.location}"
      end

      def negative_failure_message(actual : TestResponse) : String
        "Expected no redirect to #{@path}"
      end
    end

    struct StatusExpectation
      def initialize(@status : Int32)
      end

      def match(actual : TestResponse) : Bool
        actual.status == @status
      end

      def failure_message(actual : TestResponse) : String
        "Expected status #{@status}, got #{actual.status}\n#{actual.body[0, 500]}"
      end

      def negative_failure_message(actual : TestResponse) : String
        "Expected status other than #{@status}"
      end
    end

    # `response.should be_ok`, `be_redirect`, `be_not_found`, `be_forbidden`, `be_unprocessable`…
    struct PredicateExpectation
      def initialize(@name : String, @check : TestResponse -> Bool)
      end

      def match(actual : TestResponse) : Bool
        @check.call(actual)
      end

      def failure_message(actual : TestResponse) : String
        "Expected response to be #{@name}, got #{actual.status}\n#{actual.body[0, 400]}"
      end

      def negative_failure_message(actual : TestResponse) : String
        "Expected response not to be #{@name}"
      end
    end

    module Matchers
      def be_ok : PredicateExpectation
        PredicateExpectation.new("ok (2xx)", ->(r : TestResponse) { r.ok? })
      end

      def be_redirect : PredicateExpectation
        PredicateExpectation.new("a redirect", ->(r : TestResponse) { r.redirect? })
      end

      def be_not_found : PredicateExpectation
        PredicateExpectation.new("not found", ->(r : TestResponse) { r.not_found? })
      end

      def be_forbidden : PredicateExpectation
        PredicateExpectation.new("forbidden", ->(r : TestResponse) { r.forbidden? })
      end

      def be_unauthorized : PredicateExpectation
        PredicateExpectation.new("unauthorized", ->(r : TestResponse) { r.unauthorized? })
      end

      def be_unprocessable : PredicateExpectation
        PredicateExpectation.new("unprocessable", ->(r : TestResponse) { r.unprocessable? })
      end

      def redirect_to(path : String) : RedirectExpectation
        RedirectExpectation.new(path)
      end

      def have_status(status : Int32) : StatusExpectation
        StatusExpectation.new(status)
      end

      def client : TestClient
        Testing.client
      end
    end

    # Drives a real browser through the W3C WebDriver protocol (chromedriver, geckodriver).
    #
    # ```
    # Silth::Testing::Browser.session do |b|
    #   b.visit("/login").fill("#email", "ada@example.com").fill("#password", "secret").click("button[type=submit]")
    #   b.should_see("Welcome back")
    # end
    # ```
    class Browser
      getter base_url : String
      @session : String
      @driver : String

      def self.serve(port : Int32 = 4010) : String
        server = HTTP::Server.new(Silth.app.handler)
        server.bind_tcp("127.0.0.1", port)
        spawn { server.listen }
        sleep 50.milliseconds
        "http://127.0.0.1:#{port}"
      end

      def self.session(driver : String = ENV["WEBDRIVER_URL"]? || "http://localhost:9515", headless : Bool = ENV["HEADED"]?.nil?, & : Browser ->) : Nil
        base = serve
        browser = new(driver, base, headless)
        begin
          yield browser
        ensure
          browser.quit
        end
      end

      def initialize(@driver : String, @base_url : String, headless : Bool = true)
        args = headless ? ["--headless=new", "--window-size=1280,900", "--no-sandbox"] : ["--window-size=1280,900"]
        caps = {capabilities: {alwaysMatch: {"browserName" => "chrome", "goog:chromeOptions" => {args: args}, "moz:firefoxOptions" => {args: headless ? ["-headless"] : [] of String}}}}
        res = call("POST", "/session", caps.to_json)
        @session = res["value"]["sessionId"].as_s
      end

      private def call(method : String, path : String, body : String? = nil) : JSON::Any
        uri = URI.parse(@driver.rstrip('/') + path)
        response = HTTP::Client.exec(method, uri, HTTP::Headers{"Content-Type" => "application/json"}, body || (method == "POST" ? "{}" : nil))
        json = JSON.parse(response.body)
        if response.status_code >= 400
          raise Silth::Error.new("WebDriver: #{json["value"]?.try(&.["message"]?) || response.body}")
        end
        json
      end

      private def s(path : String) : String
        "/session/#{@session}#{path}"
      end

      def visit(path : String) : self
        call("POST", s("/url"), {url: path.starts_with?("http") ? path : @base_url + path}.to_json)
        self
      end

      def find(css : String) : String
        value = call("POST", s("/element"), {using: "css selector", value: css}.to_json)["value"]
        value.as_h.values.first.as_s
      end

      def click(css : String) : self
        call("POST", s("/element/#{find(css)}/click"))
        self
      end

      def fill(css : String, text : String) : self
        id = find(css)
        call("POST", s("/element/#{id}/clear"))
        call("POST", s("/element/#{id}/value"), {text: text}.to_json)
        self
      end

      def text(css : String = "body") : String
        call("GET", s("/element/#{find(css)}/text"))["value"].as_s
      end

      def source : String
        call("GET", s("/source"))["value"].as_s
      end

      def current_url : String
        call("GET", s("/url"))["value"].as_s
      end

      def execute(script : String, *args) : JSON::Any
        call("POST", s("/execute/sync"), {script: script, args: args.to_a}.to_json)["value"]
      end

      def wait_for(css : String, timeout : Time::Span = 5.seconds) : self
        deadline = Time.instant + timeout
        loop do
          begin
            find(css)
            return self
          rescue ex
            raise ex if Time.instant > deadline
            sleep 100.milliseconds
          end
        end
      end

      def see?(text : String) : Bool
        text("body").includes?(text)
      end

      def should_see(text : String) : Nil
        raise Spec::AssertionFailed.new("Expected page to contain #{text.inspect}", __FILE__, __LINE__) unless see?(text)
      end

      def screenshot(path : String) : Nil
        File.write(path, Base64.decode(call("GET", s("/screenshot"))["value"].as_s))
      end

      def quit : Nil
        call("DELETE", s("")) rescue nil
      end
    end
  end
end

include Silth::Testing::Matchers

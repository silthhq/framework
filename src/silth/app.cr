require "http/server"
require "http/web_socket"

module Silth
  # The application kernel: configuration, middleware, routing and the HTTP server.
  #
  # ```
  # Silth.configure do |app|
  #   app.middleware.use MyGlobalMiddleware.new
  #   app.middleware_groups["web"] << TrackVisits.new
  #   app.alias_middleware("admin") { RequireAdmin.new }
  # end
  # Silth.serve
  # ```
  class App
    Log = ::Log.for("silth")

    getter middleware = MiddlewareStack.new
    getter middleware_groups = {} of String => Array(Middleware)
    getter router = Router.new
    property error_renderer : Proc(Context, Exception, Int32, Bool)? = nil
    getter? booted = false
    @aliases = {} of String => Proc(Middleware)
    @configure_hooks = [] of App -> Nil
    @boot_hooks = [] of -> Nil
    @shutdown_hooks = [] of -> Nil
    @server : HTTP::Server?

    def configure(&block : App -> Nil) : Nil
      @booted ? block.call(self) : (@configure_hooks << block)
    end

    def on_boot(&block : -> Nil) : Nil
      @booted ? block.call : (@boot_hooks << block)
    end

    def on_shutdown(&block : -> Nil) : Nil
      @shutdown_hooks << block
    end

    def alias_middleware(name : String, &factory : -> Middleware) : Nil
      @aliases[name] = factory
    end

    def middleware_alias(name : String) : Middleware
      if factory = @aliases[name]?
        factory.call
      else
        raise Error.new("Unknown middleware alias '#{name}'. Known: #{@aliases.keys.join(", ")}")
      end
    end

    def boot : self
      return self if @booted
      Silth.load_config
      Logging.setup(Silth.config, Silth.env)
      I18n.load
      install_default_middleware
      Silth.boot_subsystems
      @configure_hooks.each &.call(self)
      Routes.sets.each &.draw_into(@router)
      @booted = true
      @boot_hooks.each &.call
      self
    end

    # Default global stack and the `web` / `api` groups.
    private def install_default_middleware : Nil
      config = Silth.config
      debug = config.bool("app.debug", Silth.env == "development")
      @middleware.use RequestIdMiddleware.new
      @middleware.use Telemetry::Middleware.new if Telemetry.enabled?
      @middleware.use RequestLoggerMiddleware.new unless Silth.env == "test"
      @middleware.use ErrorHandlerMiddleware.new(debug)
      @middleware.use Profiler::Middleware.new if Profiler.enabled?
      @middleware.use HealthMiddleware.new
      @middleware.use MaintenanceMiddleware.new
      @middleware.use InternalAssetsMiddleware.new
      if Silth.env == "development"
        @middleware.use DevReloadMiddleware.new
        DevReloadMiddleware.watch_assets(Silth.assets.source_dir) if Dir.exists?(Silth.assets.source_dir)
      end
      @middleware.use Live::Endpoint.new
      @middleware.use OpenAPI::Middleware.new(config.string("api_docs.path", "/docs/api")) if config.bool("api_docs.enabled", Silth.development?)
      @middleware.use Billing::WebhookMiddleware.new(config.string("billing.webhook_path", "/stripe/webhook")) if config.has?("billing.stripe")
      @middleware.use StaticMiddleware.new(config.string("app.public_dir", "public"))
      @middleware.use StaticMiddleware.new(Silth.assets.source_dir, "/assets") if Silth.env != "production"
      @middleware.use MethodOverrideMiddleware.new
      @middleware.use SecureHeadersMiddleware.new(config.string?("security.csp"), config.bool("security.hsts", Silth.env == "production"))
      if config.has?("cors.origins")
        @middleware.use CORSMiddleware.new(config.array("cors.origins"), credentials: config.bool("cors.credentials", false),
          paths: config.has?("cors.paths") ? config.array("cors.paths") : ["/api"])
      end

      @middleware_groups["web"] = [
        SessionMiddleware.new,
        CSRFMiddleware.new(config.array("security.csrf_except"), config.array("security.trusted_origins")),
        I18n::LocaleMiddleware.new,
        Auth::SessionAuthMiddleware.new,
      ] of Middleware
      @middleware_groups["api"] = [
        I18n::LocaleMiddleware.new,
        Auth::TokenAuthMiddleware.new,
        RateLimit::Middleware.new("api", config.int("rate_limit.api.limit", 120), config.int("rate_limit.api.period", 60).seconds),
      ] of Middleware

      alias_middleware("auth") { Auth::Authenticate.new }
      alias_middleware("guest") { Auth::RedirectIfAuthenticated.new }
      alias_middleware("verified") { Auth::EnsureEmailVerified.new }
      alias_middleware("signed") { SignedURL::Middleware.new }
      alias_middleware("throttle") { RateLimit::Middleware.new("throttle", 60, 1.minute) }
    end

    def handler : HTTP::Handler
      Kernel.new(self)
    end

    # Entry point for every HTTP request.
    def call(raw : HTTP::Server::Context) : Nil
      ctx = Context.new(raw)
      Fiber.current.silth_context = ctx
      DB.begin_request(ctx)
      begin
        Chain.new(@middleware.to_a, ->(c : Context) { dispatch(c) }).next(ctx)
      ensure
        ctx.params?.try &.cleanup
        Fiber.current.silth_context = nil
      end
    end

    def dispatch(ctx : Context) : Nil
      match = @router.match(ctx.request.method, ctx.path)
      unless match
        allowed = @router.allowed_methods(ctx.path)
        if !allowed.empty? && ctx.request.method != "OPTIONS"
          raise MethodNotAllowed.new(allowed)
        end
        raise NotFound.new("No route matches #{ctx.request.method} #{ctx.path}")
      end
      ctx.route = match.route
      ctx.route_params = match.params
      Chain.new(match.route.pipeline, match.route.endpoint).next(ctx)
    end

    class Kernel
      include HTTP::Handler

      def initialize(@app : App)
      end

      def call(context : HTTP::Server::Context) : Nil
        @app.call(context)
      end
    end

    # Serves HTTP until INT or TERM.
    #
    # With `workers:` above 1 in `config/server.yml` (`auto` for one per CPU,
    # `WEB_CONCURRENCY` in the environment), this process becomes a supervisor
    # that starts that many copies of the application bound to the same port
    # (`SO_REUSEPORT`, which the Linux kernel balances), restarts a worker that
    # dies and forwards INT/TERM for a graceful stop.
    def serve(host : String? = nil, port : Int32? = nil, workers : Int32? = nil) : Nil
      config = Silth.config
      host ||= ENV["HOST"]? || config.string("server.host", "127.0.0.1")
      port ||= (ENV["PORT"]?.try(&.to_i?) || config.int("server.port", 3000))
      count = workers || App.worker_count(ENV["WEB_CONCURRENCY"]? || config.string("server.workers", "1"))
      if count > 1 && !ENV["SILTH_WORKER"]?
        return Workers.new(count, host, port).run { |address| banner(address, count) }
      end
      boot
      server = HTTP::Server.new(handler)
      @server = server
      reuse = config.bool("server.reuse_port", false) || ENV.has_key?("SILTH_WORKER")
      address = server.bind_tcp(host, port, reuse_port: reuse)
      Signal::INT.trap { shutdown }
      Signal::TERM.trap { shutdown }
      banner(address.to_s) unless ENV.has_key?("SILTH_WORKER")
      server.listen
    end

    # `"auto"` (one per CPU) or a number of worker processes.
    def self.worker_count(setting : String) : Int32
      value = setting.strip.downcase
      count = value == "auto" ? System.cpu_count.to_i : (value.to_i? || 1)
      count.clamp(1, 256)
    end

    # Runs and supervises worker processes of this executable (see `App#serve`).
    class Workers
      Log = ::Log.for("silth.workers")

      @processes = {} of Int32 => Process
      @stopping = false

      def initialize(@count : Int32, @host : String, @port : Int32)
      end

      def run(& : String ->) : Nil
        @count.times { |i| start(i) }
        Signal::INT.trap { stop(Signal::INT) }
        Signal::TERM.trap { stop(Signal::TERM) }
        yield "#{@host}:#{@port}"
        loop do
          break if @processes.empty?
          @processes.to_a.each do |index, process|
            next unless process.terminated?
            @processes.delete(index)
            status = process.wait
            next if @stopping
            Log.warn { "Worker #{index} exited (#{status.exit_reason}), restarting" }
            sleep 500.milliseconds
            start(index)
          end
          sleep 100.milliseconds
        end
      end

      private def start(index : Int32) : Nil
        executable = Process.executable_path || PROGRAM_NAME
        @processes[index] = Process.new(executable, ARGV, env: {"SILTH_WORKER" => index.to_s, "HOST" => @host, "PORT" => @port.to_s},
          input: :close, output: :inherit, error: :inherit)
      end

      private def stop(signal : Signal) : Nil
        return if @stopping
        @stopping = true
        Log.info { "Stopping #{@processes.size} worker(s)…" }
        @processes.each_value { |process| process.signal(signal) rescue nil }
      end
    end

    def shutdown : Nil
      Log.info { "Shutting down gracefully…" }
      @shutdown_hooks.each { |h| h.call rescue nil }
      @server.try &.close
    end

    private def banner(address : String, workers : Int32 = 1) : Nil
      return if Silth.env == "test"
      url = "http://#{address.sub("0.0.0.0", "localhost").sub("127.0.0.1", "localhost")}"
      puts
      puts "  #{"◆".colorize(:light_cyan)} #{"Silth".colorize.bold} #{Silth::VERSION.colorize(:dark_gray)}  #{Silth.env.colorize(:magenta)}"
      puts "  #{"➜".colorize(:cyan)} #{url.colorize(:light_cyan).underline}"
      puts "  #{"➜".colorize(:dark_gray)} #{"workers".colorize(:dark_gray)}   #{workers} processes" if workers > 1
      puts "  #{"➜".colorize(:dark_gray)} #{"profiler".colorize(:dark_gray)}  #{url}/_silth/profiler" if Profiler.enabled?
      puts "  #{"➜".colorize(:dark_gray)} #{"routes".colorize(:dark_gray)}    #{@router.routes.size} registered" if workers == 1
      puts
    end
  end
end

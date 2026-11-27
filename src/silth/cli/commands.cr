module Silth::Commands
  class About < Command
    command "about", "Display information about the application"

    def run : Nil
      Silth.boot
      c = Silth.config
      line "\n  #{"Silth".colorize.bold} #{Silth::VERSION}  ·  Crystal #{Crystal::VERSION}\n"
      rows = [
        ["Application", c.string("app.name", "-")],
        ["Environment", Silth.env],
        ["URL", c.string("app.url", "-")],
        ["Debug", c.bool("app.debug", Silth.development?).to_s],
        ["Routes", Silth.router.routes.size.to_s],
        ["Databases", DB.databases.map { |n, d| "#{n} (#{d.dialect.name})" }.join(", ").presence || "none"],
        ["Cache", c.string("cache.default", "memory")],
        ["Queue", c.string("queue.driver", "memory")],
        ["Mail", c.string("mail.driver", Silth.development? ? "file" : "smtp")],
        ["Storage", c.string("storage.default", "local")],
        ["Profiler", Profiler.enabled?.to_s],
        ["Telemetry", Telemetry.enabled?.to_s],
        ["Locales", I18n.available.join(", ")],
      ]
      table(["Key", "Value"], rows)
      line
    end
  end

  class Routes < Command
    command "routes", "List every registered route"
    option filter : String?, "Only routes whose path or name contains this text", short: "f"
    option json : Bool = false, "Output JSON (for tools and AI agents)"

    def run : Nil
      Silth.boot
      routes = Silth.router.routes
      if f = filter
        routes = routes.select { |r| r.path.includes?(f) || r.name.to_s.includes?(f) || r.handler_name.includes?(f) }
      end
      if json
        line routes.map { |r| {method: r.method, path: r.path, name: r.name, handler: r.handler_name, group: r.group, middleware: r.middleware.map(&.name)} }.to_pretty_json
        return
      end
      table(["Verb", "Path", "Name", "Handler", "Middleware"],
        routes.map { |r| [r.method, r.path, r.name || "", r.handler_name, ([r.group || ""] + r.middleware.map(&.name)).reject(&.empty?).join(",")] })
    end
  end

  class Serve < Command
    command "server", "Start the HTTP server (production style, no reload)"
    option host : String?, "Bind address", short: "b"
    option port : Int32?, "Port", short: "p"
    option workers : String?, "Worker processes (a number or auto; default: server.workers)", short: "w"

    def run : Nil
      Silth.serve(host, port, workers.try { |w| App.worker_count(w) })
    end
  end

  class KeyGenerate < Command
    command "key:generate", "Generate APP_KEY and write it to .env"
    option show : Bool = false, "Only print the key"

    def run : Nil
      key = Crypto.generate_app_key
      if show || !File.exists?(".env")
        line key
        return
      end
      content = File.read(".env")
      content = content.matches?(/^APP_KEY=.*$/m) ? content.sub(/^APP_KEY=.*$/m, "APP_KEY=#{key}") : content + "\nAPP_KEY=#{key}\n"
      File.write(".env", content)
      success "APP_KEY written to .env"
    end
  end

  class Down < Command
    command "down", "Put the application in maintenance mode"
    option secret : String?, "Bypass secret (?secret=…)"

    def run : Nil
      Dir.mkdir_p("tmp")
      File.write(MaintenanceMiddleware::FILE, secret || "")
      success "Application is now in maintenance mode#{secret ? " (bypass with ?secret=#{secret})" : ""}"
    end
  end

  class Up < Command
    command "up", "Bring the application out of maintenance mode"

    def run : Nil
      File.delete?(MaintenanceMiddleware::FILE)
      success "Application is live"
    end
  end

  # --- database -----------------------------------------------------------

  abstract class DatabaseCommand < Command
    def database : DB::Database
      Silth.load_config
      Logging.setup(Silth.config, Silth.env)
      DB.boot
      DB.connection(connection_name)
    end

    def connection_name : String?
      nil
    end
  end

  class DbCreate < DatabaseCommand
    command "db:create", "Create the database"

    def run : Nil
      Silth.load_config
      DB.boot
      url = DB.connection.url
      name = url.path.lchop('/')
      case DB.connection.dialect.name
      when "sqlite"
        DB.connection.query("SELECT 1")
        success "SQLite database ready (#{url.path})"
      when "postgres"
        admin = DB::Postgres::Connection.new(URI.parse(url.to_s.sub(/\/#{name}(\?|$)/, "/postgres\\1")))
        admin.exec_script(%(CREATE DATABASE "#{name}")) rescue (warn "Database #{name} may already exist"; return)
        admin.close
        success "Created database #{name}"
      when "mysql"
        admin = DB::MySQL::Connection.new(URI.parse(url.to_s.sub(/\/#{name}(\?|$)/, "/\\1")))
        admin.exec_script("CREATE DATABASE IF NOT EXISTS `#{name}` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci")
        admin.close
        success "Created database #{name}"
      end
    end
  end

  class DbDrop < DatabaseCommand
    command "db:drop", "Drop the database"
    option force : Bool = false, "Skip confirmation"

    def run : Nil
      Silth.load_config
      DB.boot
      db = DB.connection
      name = db.url.path.lchop('/')
      return unless force || confirm?("Drop database #{name}?")
      case db.dialect.name
      when "sqlite"
        db.close
        File.delete?(db.url.path)
        success "Deleted #{db.url.path}"
      when "postgres"
        db.close
        admin = DB::Postgres::Connection.new(URI.parse(db.url.to_s.sub(/\/#{name}(\?|$)/, "/postgres\\1")))
        admin.exec_script(%(DROP DATABASE IF EXISTS "#{name}"))
        success "Dropped #{name}"
      when "mysql"
        db.close
        admin = DB::MySQL::Connection.new(URI.parse(db.url.to_s.sub(/\/#{name}(\?|$)/, "/\\1")))
        admin.exec_script("DROP DATABASE IF EXISTS `#{name}`")
        success "Dropped #{name}"
      end
    end
  end

  class DbMigrate < DatabaseCommand
    command "db:migrate", "Run pending migrations"
    option step : Int32?, "Only run N migrations"
    option connection : String?, "Database connection name"

    def connection_name : String?
      connection
    end

    def run : Nil
      ran = Migrator.new(database).migrate(step)
      ran.empty? ? info("Nothing to migrate.") : ran.each { |m| success "Migrated #{m}" }
      SchemaFile.auto_dump(database) unless ran.empty?
    end
  end

  class DbRollback < DatabaseCommand
    command "db:rollback", "Roll back the last batch of migrations"
    option step : Int32?, "Roll back N migrations instead of the last batch"
    option connection : String?, "Database connection name"

    def connection_name : String?
      connection
    end

    def run : Nil
      rolled = Migrator.new(database).rollback(step)
      rolled.empty? ? info("Nothing to roll back.") : rolled.each { |m| success "Rolled back #{m}" }
      SchemaFile.auto_dump(database) unless rolled.empty?
    end
  end

  class DbStatus < DatabaseCommand
    command "db:status", "Show migration status"
    option connection : String?, "Database connection name"

    def connection_name : String?
      connection
    end

    def run : Nil
      rows = Migrator.new(database).status.map do |s|
        [s.applied ? "✔ up".colorize(:green).to_s : "• pending".colorize(:yellow).to_s, s.version.to_s, s.name, s.batch.try(&.to_s) || ""]
      end
      table(["Status", "Version", "Migration", "Batch"], rows)
    end
  end

  # Where the schema of a connection is dumped: `db/schema.cr` (default connection)
  # or `db/<name>_schema.cr`.
  module SchemaFile
    def self.path(db : DB::Database) : String
      db.name == DB.default ? "db/schema.cr" : "db/#{db.name}_schema.cr"
    end

    def self.dump(db : DB::Database) : String
      file = path(db)
      Dir.mkdir_p(File.dirname(file))
      File.write(file, DB::SchemaDumper.new(db).dump)
      file
    end

    # After migrations in development (`database.schema_dump` in config/database.yml).
    def self.auto_dump(db : DB::Database) : Nil
      return unless Silth.config.bool("database.schema_dump", Silth.env == "development") && Dir.exists?("db")
      dump(db)
    end
  end

  class DbSchemaDump < DatabaseCommand
    command "db:schema:dump", "Write the database schema to db/schema.cr"
    option connection : String?, "Database connection name"

    def connection_name : String?
      connection
    end

    def run : Nil
      success "Schema written to #{SchemaFile.dump(database)}"
    end
  end

  class DbSchemaLoad < DatabaseCommand
    command "db:schema:load", "Recreate the database from db/schema.cr (drops every table)"
    option connection : String?, "Database connection name"
    option force : Bool = false, "Allow in production"

    def connection_name : String?
      connection
    end

    def run : Nil
      raise Command::Error.new("Refusing to drop tables in production (use --force)") if Silth.production? && !force
      db = database
      definition = DB::SchemaDefinition.for(db.name) ||
                   raise Command::Error.new("No schema compiled in for '#{db.name}': run `silth db:schema:dump` and require #{SchemaFile.path(db)} from src/cli.cr")
      definition.load(db)
      success "Loaded #{SchemaFile.path(db)} (version #{definition.version})"
    end
  end

  class DbSeed < DatabaseCommand
    command "db:seed", "Run database seeders"
    option seeder : String?, "Run only this seeder class"

    def run : Nil
      database
      if name = seeder
        klass = Seeder.all.find { |k| k.name == name || k.name.ends_with?("::#{name}") } || raise Command::Error.new("Unknown seeder #{name}")
        klass.new.run
      else
        Seeder.run_default
      end
      success "Database seeded"
    end
  end

  class DbReset < DatabaseCommand
    command "db:reset", "Roll back every migration then migrate again"

    def run : Nil
      migrator = Migrator.new(database)
      migrator.reset.each { |m| info "Rolled back #{m}" }
      migrator.migrate.each { |m| success "Migrated #{m}" }
      SchemaFile.auto_dump(database)
    end
  end

  class DbFresh < DatabaseCommand
    command "db:fresh", "Drop all tables and migrate from scratch"
    option seed : Bool = false, "Seed after migrating"
    option force : Bool = false, "Allow in production"

    def run : Nil
      raise Command::Error.new("Refusing to drop tables in production (use --force)") if Silth.production? && !force
      Migrator.new(database).fresh.each { |m| success "Migrated #{m}" }
      SchemaFile.auto_dump(database)
      if seed
        Seeder.run_default
        success "Database seeded"
      end
    end
  end

  # `silth db:console`: the database's own client on the configured connection.
  # The password goes through the environment (`PGPASSWORD`, `MYSQL_PWD`), never
  # the command line where `ps` would show it.
  class DbConsole < DatabaseCommand
    command "db:console", "Open the database client (psql, mariadb/mysql, sqlite3)"
    option connection : String = "", "Connection name from config/database.yml", short: "c"
    option replica : Bool = false, "Open the first read replica instead of the primary"
    option print : Bool = false, "Print the command instead of running it (without the password)"

    record Client, program : String, args : Array(String), env : Hash(String, String)

    def connection_name : String?
      connection.presence
    end

    def run : Nil
      db = database
      url = if replica
              db.replicas.first?.try(&.url) || raise Error.new("Connection '#{db.name}' has no replica")
            else
              db.url
            end
      client = DbConsole.client(db.dialect.name, url)
      if print
        line client.args.empty? ? client.program : "#{client.program} #{Process.quote(client.args)}"
        client.env.each_key { |key| line "  #{key}=#{key.ends_with?("PWD") || key.ends_with?("PASSWORD") ? "…" : client.env[key]}" }
        return
      end
      program = Process.find_executable(client.program) ||
                raise Error.new("#{client.program} is not installed (#{DbConsole.install_hint(db.dialect.name)})")
      Process.exec(program, client.args, env: client.env)
    end

    # The client command for a connection URL.
    #
    # ```
    # DbConsole.client("postgres", URI.parse("postgres://app:secret@db:5432/blog?sslmode=require"))
    # # => Client(program: "psql", args: [], env: {"PGHOST" => "db", …, "PGPASSWORD" => "secret", "PGSSLMODE" => "require"})
    # ```
    def self.client(dialect : String, url : URI) : Client
      user = url.user.presence.try { |u| URI.decode_www_form(u) }
      password = url.password.try { |p| URI.decode_www_form(p) }
      database = url.path.lchop('/')
      params = url.query_params
      case dialect
      when "postgres"
        env = {"PGHOST" => url.host.presence || "localhost", "PGPORT" => (url.port || 5432).to_s, "PGDATABASE" => database}
        user.try { |u| env["PGUSER"] = u }
        password.try { |p| env["PGPASSWORD"] = p }
        params["sslmode"]?.try { |m| env["PGSSLMODE"] = m }
        env["PGAPPNAME"] = "silth db:console"
        Client.new("psql", [] of String, env)
      when "mysql"
        program = Process.find_executable("mariadb") ? "mariadb" : "mysql"
        args = ["--host=#{url.host.presence || "localhost"}", "--port=#{url.port || 3306}", "--user=#{user || "root"}"]
        if %w(true required require 1 verify).includes?(params["ssl"]? || params["sslmode"]? || "")
          args << (program == "mariadb" ? "--ssl" : "--ssl-mode=REQUIRED")
        end
        args << database unless database.empty?
        env = {} of String => String
        password.try { |p| env["MYSQL_PWD"] = p }
        Client.new(program, args, env)
      else
        Client.new("sqlite3", [url.path.presence || url.host || ":memory:"], {} of String => String)
      end
    end

    def self.install_hint(dialect : String) : String
      case dialect
      when "postgres" then "apt install postgresql-client, brew install libpq"
      when "mysql"    then "apt install mariadb-client, brew install mariadb or mysql-client"
      else                 "apt install sqlite3, brew install sqlite"
      end
    end
  end

  # --- queue & schedule ------------------------------------------------------

  class QueueWork < Command
    command "queue:work", "Process queued jobs"
    option queues : String = "default", "Comma separated queue names", short: "q"
    option concurrency : Int32 = 4, "Number of worker fibers", short: "c"
    option once : Bool = false, "Process available jobs then exit"

    def run : Nil
      Silth.boot
      worker = Queue::Worker.new(queues.split(',').map(&.strip), concurrency)
      if once
        success "Processed #{worker.drain} job(s)"
      else
        Signal::INT.trap { worker.stop }
        Signal::TERM.trap { worker.stop }
        worker.run
      end
    end
  end

  class QueueFailed < Command
    command "queue:failed", "List failed jobs (database driver)"

    def run : Nil
      Silth.boot
      rows = DB.connection.table("silth_failed_jobs").latest("failed_at").limit(50).rows
      table(["Job", "Queue", "Failed at", "Error"], rows.map { |r| [r["job"].to_s, r["queue"].to_s, r["failed_at"].to_s, r["exception"].to_s.lines.first? || ""] })
    rescue DB::QueryError
      info "No failed jobs table (database driver not used yet)."
    end
  end

  class ScheduleRun < Command
    command "schedule:run", "Run due scheduled tasks (call from cron every minute)"

    def run : Nil
      Silth.boot
      count = Silth.scheduler.run_due
      info "#{count} task(s) ran"
    end
  end

  class ScheduleWork < Command
    command "schedule:work", "Run the scheduler in the foreground"

    def run : Nil
      Silth.boot
      Silth.scheduler.work
    end
  end

  class ScheduleList < Command
    command "schedule:list", "List scheduled tasks"

    def run : Nil
      Silth.boot
      table(["Task", "Cron", "Next run"], Silth.scheduler.tasks.map { |t| [t.name, t.cron.expression, t.next_run.to_local.to_s("%Y-%m-%d %H:%M %Z")] })
    end
  end

  # --- assets, docs, workflows, export ----------------------------------------

  class AssetsBuild < Command
    command "assets:build", "Fingerprint assets into public/assets with a manifest"
    option no_minify : Bool = false, "Skip CSS minification"

    def run : Nil
      Silth.load_config
      manifest = Silth.assets.build(!no_minify)
      manifest.each { |k, v| comment "  #{k} → #{v}" }
      success "#{manifest.size} asset(s) built into #{Silth.assets.output_dir}"
    end
  end

  class AssetsClean < Command
    command "assets:clean", "Remove compiled assets"

    def run : Nil
      Silth.load_config
      FileUtils.rm_rf(Silth.assets.output_dir)
      success "Removed #{Silth.assets.output_dir}"
    end
  end

  class ApiDocs < Command
    command "api:docs", "Export the OpenAPI specification"
    option output : String = "public/openapi.json", "Destination file", short: "o"

    def run : Nil
      Silth.boot
      Dir.mkdir_p(File.dirname(output))
      File.write(output, OpenAPI.document)
      success "OpenAPI spec written to #{output}"
    end
  end

  class WorkflowDump < Command
    command "workflow:dump", "Dump a workflow as mermaid, dot or svg"
    argument name : String, "Workflow name"
    option format : String = "mermaid", "mermaid | dot | svg"

    def run : Nil
      Silth.load_config
      d = Workflow.definitions[name]? || raise Command::Error.new("Unknown workflow #{name}. Known: #{Workflow.definitions.keys.join(", ")}")
      line(case format
      when "dot" then d.to_dot
      when "svg" then d.to_svg
      else            d.to_mermaid
      end)
    end
  end

  # Renders GET routes (and extra paths) to static HTML files.
  class Export < Command
    # Extra paths computed by the application (e.g. one per documentation page).
    class_getter path_providers = [] of -> Array(String)

    command "export", "Export pages to static HTML (static hosting)"
    option output : String = "dist", "Output directory", short: "o"
    option paths : String = "", "Extra comma separated paths to render"

    # Where *path* is written: as is when it names a file (`/llms.txt`), as
    # `index.html` inside it otherwise (`/docs`, `/docs/0.1`: a version number is
    # not an extension).
    def self.output_file(path : String) : String
      return "/index.html" if path == "/"
      File.extname(path).matches?(/\A\.[a-z][a-z0-9]*\z/i) ? path : "#{path.rstrip('/')}/index.html"
    end

    def run : Nil
      Silth.env = "production" if Silth.development?
      # Static pages never read sessions back: an ephemeral key is fine when none is configured.
      Silth.app_key = Crypto.generate_app_key unless ENV["APP_KEY"]? || Silth.config.string?("app.key")
      app = Silth.boot
      manifest = Silth.assets.build
      info "#{manifest.size} asset(s) fingerprinted"
      targets = Silth.router.routes.select { |r| r.method == "GET" && r.param_names.empty? && !r.path.starts_with?("/api") }.map(&.path)
      targets.concat(paths.split(',').map(&.strip).reject(&.empty?))
      targets.concat(Silth.config.array("export.paths"))
      Export.path_providers.each { |provider| targets.concat(provider.call) }
      FileUtils.rm_rf(output)
      progress(targets.uniq, "pages") do |path|
        request = HTTP::Request.new("GET", path, HTTP::Headers{"Host" => URI.parse(Silth.config.string("app.url", "http://localhost")).host || "localhost", "Accept" => "text/html"})
        io = IO::Memory.new
        response = HTTP::Server::Response.new(io)
        app.call(HTTP::Server::Context.new(request, response))
        response.close
        body = HTTP::Client::Response.from_io(IO::Memory.new(io.to_s)).body
        file = Export.output_file(path)
        dest = File.join(output, file)
        Dir.mkdir_p(File.dirname(dest))
        File.write(dest, body)
      end
      if Dir.exists?("public")
        Dir.glob("public/**/*").each do |f|
          next unless File.file?(f)
          dest = File.join(output, f.lchop("public/"))
          Dir.mkdir_p(File.dirname(dest))
          FileUtils.cp(f, dest)
        end
      end
      Export.write_internal_assets(output)
      success "Exported #{targets.uniq.size} page(s) to #{output}/"
    end

    # Writes the framework's own assets (`/_silth/silth.js`…) that exported pages
    # load: they are served from the binary, never from `public/`.
    def self.write_internal_assets(output : String) : Nil
      InternalAssetsMiddleware::FILES.each do |path, (_type, body)|
        next if path.ends_with?("livereload.js") # development only
        dest = File.join(output, path)
        Dir.mkdir_p(File.dirname(dest))
        File.write(dest, body)
      end
    end
  end
end

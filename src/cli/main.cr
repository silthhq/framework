# The global `silth` executable.
#
# Framework commands run directly (new, serve, build, test, generate, version).
# Any other command is forwarded to the application CLI (`src/cli.cr`), which is
# compiled on demand into `bin/cli` and rebuilt when sources change.
require "../silth"

module Silth::Global
  GLOBAL = %w(new serve s build test version --version -v generate g help --help -h)

  def self.run(args : Array(String)) : Int32
    command = args.first? || "help"
    case command
    when "new"                       then NewApp.run(args[1..])
    when "serve", "s"                then DevServer.new(args[1..]).run
    when "build"                     then build(args[1..])
    when "test"                      then exec_crystal(["spec"] + args[1..], {"SILTH_ENV" => "test"})
    when "version", "--version", "-v"
      puts "Silth #{Silth::VERSION} (Crystal #{Crystal::VERSION})"
      0
    when "generate", "g"
      CLI.run(["generate"] + args[1..])
    when "help", "--help", "-h"
      help
      0
    else
      delegate(args)
    end
  end

  def self.help : Nil
    puts CLI::BANNER.colorize(:light_cyan)
    puts "\n  #{"Framework".colorize(:yellow)}"
    [{"new <name>", "Create a new application (--db=sqlite|postgres|mysql, --edge for the main branch)"},
     {"serve", "Development server with rebuild on change and live reload"},
     {"build", "Production build (release binaries + fingerprinted assets)"},
     {"test", "Run the test suite (crystal spec)"},
     {"generate, g", "Code generators (scaffold, api, model, live, job…)"},
     {"version", "Show versions"}].each { |(n, d)| puts "    #{n.ljust(26).colorize(:green)}#{d}" }
    if app?
      puts "\n  #{"Application commands".colorize(:yellow)} (#{"silth help".colorize(:dark_gray)} inside an app lists them all)"
      delegate(["help"]) rescue nil
    else
      puts "\n  Run #{"silth new my_app".colorize(:cyan)} to start.\n"
    end
  end

  def self.app? : Bool
    File.exists?("src/cli.cr") && File.exists?("shard.yml")
  end

  def self.newest_source : Time
    Dir.glob("src/**/*", "config/**/*", "db/**/*.cr", "shard.lock", "lib/*/src/**/*.cr", "lib/*/src/**/*.ecr", follow_symlinks: true).select { |f| File.file?(f) }.max_of? { |f| File.info(f).modification_time } || Time.unix(0)
  end

  # Builds `bin/cli` when stale, then replaces this process with it.
  def self.delegate(args : Array(String)) : Int32
    unless app?
      STDERR.puts "#{"✖".colorize(:red)} '#{args.first?}' must be run inside a Silth application (no src/cli.cr here)."
      return 1
    end
    binary = "bin/cli"
    if !File.exists?(binary) || File.info(binary).modification_time < newest_source
      STDERR.print "#{"◆".colorize(:cyan)} Compiling application CLI…"
      Dir.mkdir_p("bin")
      log = IO::Memory.new
      status = Process.run("crystal", ["build", "src/cli.cr", "-o", binary, "--no-color"], output: log, error: log)
      unless status.success?
        STDERR.puts "\n" + log.to_s.lines.reject(&.includes?("Warning")).join('\n')
        return 1
      end
      STDERR.puts " done".colorize(:green)
    end
    Process.exec(binary, args)
  end

  def self.exec_crystal(args : Array(String), env : Hash(String, String) = {} of String => String) : Int32
    Process.run("crystal", args, env: env, output: Process::Redirect::Inherit, error: Process::Redirect::Inherit, input: Process::Redirect::Inherit).exit_code
  end

  def self.build(args : Array(String)) : Int32
    code = Process.run("shards", ["build", "--release", "--no-debug"] + args, output: Process::Redirect::Inherit, error: Process::Redirect::Inherit).exit_code
    return code unless code == 0
    Process.run("bin/cli", ["assets:build"], env: {"SILTH_ENV" => "production"}, output: Process::Redirect::Inherit, error: Process::Redirect::Inherit).exit_code
  end

  module NewApp
    def self.run(args : Array(String)) : Int32
      name = args.find { |a| !a.starts_with?('-') }
      unless name
        puts "Usage: silth new <name> [--db=sqlite|postgres|mysql] [--path-to-silth=../framework] [--edge] [--install]"
        return 1
      end
      db = args.find(&.starts_with?("--db="))
      path = args.find(&.starts_with?("--path-to-silth="))
      generator = Generators::App.new(name, db.try(&.split('=', 2).last) || "sqlite", path.try(&.split('=', 2).last),
        edge: args.includes?("--edge"))
      puts "\n#{"◆".colorize(:light_cyan)} Creating #{generator.app_title.colorize.bold} in ./#{name}\n\n"
      generator.run(name)
      if args.includes?("--install")
        Process.run("shards", ["install"], chdir: name, output: Process::Redirect::Inherit, error: Process::Redirect::Inherit)
      end
      puts <<-TXT

        #{"✔".colorize(:green)} Done. Next steps:

            cd #{name}
            shards install
            silth db:migrate
            silth serve

        Then open http://localhost:3000 — the profiler lives at /_silth/profiler.
        AI agents: read AGENTS.md (a Claude skill ships in .claude/skills/silth).

        TXT
      0
    end
  end

  # Rebuilds and restarts the server when Crystal sources or templates change.
  class DevServer
    @process : Process?
    @port : String?

    def initialize(args : Array(String))
      @port = args.find(&.starts_with?("--port="))
        .try(&.split('=', 2).last) || args.each_cons_pair.find { |(a, _)| a == "-p" || a == "--port" }.try(&.[1])
    end

    def run : Int32
      unless Global.app?
        STDERR.puts "Run `silth serve` inside a Silth application."
        return 1
      end
      Signal::INT.trap { stop; exit 0 }
      Signal::TERM.trap { stop; exit 0 }
      snapshot = mtimes
      rebuild_and_start
      loop do
        sleep 400.milliseconds
        current = mtimes
        next if current == snapshot
        changed = (current.keys + snapshot.keys).uniq.select { |f| current[f]? != snapshot[f]? }
        snapshot = current
        needs_build = changed.any? { |f| f.ends_with?(".cr") || f.ends_with?(".ecr") }
        puts "#{"↻".colorize(:cyan)} #{changed.first(3).join(", ")}#{changed.size > 3 ? " (+#{changed.size - 3})" : ""}"
        needs_build ? rebuild_and_start : restart
      end
    end

    private def mtimes : Hash(String, Time)
      files = Dir.glob("src/**/*.cr", "src/**/*.ecr", "config/**/*.cr", "config/**/*.yml", "db/**/*.cr", "shard.lock")
      files.to_h { |f| {f, (File.info(f).modification_time rescue Time.unix(0))} }
    end

    private def rebuild_and_start : Nil
      started = Time.instant
      print "#{"◆".colorize(:cyan)} Building…"
      Dir.mkdir_p("bin")
      output = IO::Memory.new
      status = Process.run("crystal", ["build", "src/server.cr", "-o", "bin/.silth-dev-server"], output: output, error: output)
      if status.success?
        puts " #{"ok".colorize(:green)} (#{(Time.instant - started).total_seconds.round(1)}s)"
        restart
      else
        puts " #{"failed".colorize(:red)}\n"
        puts output.to_s.lines.reject(&.includes?("Warning")).first(60).join('\n')
        puts "\n#{"Waiting for changes…".colorize(:dark_gray)}"
      end
    end

    private def restart : Nil
      stop
      env = {"SILTH_ENV" => ENV["SILTH_ENV"]? || "development"}
      env["PORT"] = @port.not_nil! if @port
      @process = Process.new("bin/.silth-dev-server", env: env, output: Process::Redirect::Inherit, error: Process::Redirect::Inherit)
    end

    private def stop : Nil
      if p = @process
        p.signal(Signal::TERM) rescue nil
        p.wait rescue nil
        @process = nil
      end
    end
  end
end

exit Silth::Global.run(ARGV)

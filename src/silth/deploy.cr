require "base64"

module Silth
  # `silth deploy`: builds the Docker image, pushes it, then rolls it out on each
  # server over SSH with no downtime. Servers only need Docker and SSH access.
  #
  # ```yaml
  # # config/deploy.yml (`silth deploy:init` writes it)
  # image: ghcr.io/acme/shop
  # servers: [deploy@203.0.113.10]
  # domain: shop.example.com        # Caddy gets a TLS certificate for it
  # env_file: .env.production       # uploaded to each server (APP_KEY, DATABASE_URL…)
  # ```
  #
  # On each server: the new version starts next to the old one, Caddy switches
  # over once `GET /up` answers, then the old containers stop; queue workers and
  # the scheduler restart on the new image. Migrations run once, on the first
  # server, before anything switches.
  module Deploy
    class Error < Silth::Error; end

    # Settings read from `config/deploy.yml` (the `deploy.*` keys).
    record Settings,
      service : String,
      image : String,
      servers : Array(String),
      port : Int32 = 3000,
      healthcheck : String = "/up",
      health_timeout : Int32 = 60,
      domain : String? = nil,
      env_file : String? = nil,
      registry : String? = nil,
      registry_user : String? = nil,
      registry_password : String? = nil,
      workers : Int32 = 1,
      scheduler : Bool = true,
      volumes : Array(String) = [] of String,
      keep : Int32 = 3,
      ssh_options : Array(String) = [] of String do
      def self.load(config : Config, service : String) : Settings
        image = config.string?("deploy.image") || raise Error.new("config/deploy.yml: `image` is missing (run `silth deploy:init`)")
        servers = config.array("deploy.servers").map(&.to_s)
        raise Error.new("config/deploy.yml: `servers` is empty") if servers.empty?
        new(
          service: config.string("deploy.service", service),
          image: image,
          servers: servers,
          port: config.int("deploy.port", 3000),
          healthcheck: config.string("deploy.healthcheck", "/up"),
          health_timeout: config.int("deploy.health_timeout", 60),
          domain: config.string?("deploy.domain").presence,
          env_file: config.string?("deploy.env_file").presence,
          registry: config.string?("deploy.registry.server").presence,
          registry_user: config.string?("deploy.registry.username").presence,
          registry_password: config.string?("deploy.registry.password").presence,
          workers: config.int("deploy.workers", 1),
          scheduler: config.bool("deploy.scheduler", true),
          volumes: config.array("deploy.volumes").map(&.to_s),
          keep: config.int("deploy.keep", 3),
          ssh_options: config.array("deploy.ssh_options").map(&.to_s),
        )
      end

      def tagged(version : String) : String
        "#{image}:#{version}"
      end
    end

    # The bash scripts run on servers (generated here so they can be tested).
    module Script
      # Starts *version* next to the running one, switches the proxy once it is
      # healthy, stops the old containers and restarts workers and scheduler.
      def self.rollout(s : Settings, version : String, migrate : Bool, env : String?) : String
        image = s.tagged(version)
        web = "#{s.service}-web-#{version}"
        String.build do |io|
          io << header(s)
          io << "VERSION=" << shell(version) << "\nIMAGE=" << shell(image) << "\nWEB=" << shell(web) << '\n'
          io << %(echo "[silth] #{s.service} #{version} on $(hostname)"\n)
          io << "mkdir -p \"$DIR\"\n"
          io << "printf '%s' " << shell(Base64.strict_encode(env)) << " | base64 -d > \"$DIR/.env\" && chmod 600 \"$DIR/.env\"\n" if env
          io << "touch \"$DIR/.env\"\n"
          io << "docker network inspect silth > /dev/null 2>&1 || docker network create silth > /dev/null\n"
          io << "docker pull \"$IMAGE\"\n"
          io << %(docker run --rm --network silth --env-file "$DIR/.env"#{volumes(s)} "$IMAGE" /app/bin/cli db:migrate\n) if migrate
          io << "docker rm -f \"$WEB\" > /dev/null 2>&1 || true\n"
          io << %(docker run -d --name "$WEB" --network silth --restart unless-stopped --env-file "$DIR/.env"#{volumes(s)} )
          io << %(--label silth.app="$APP" --label silth.role=web --label silth.version="$VERSION" "$IMAGE"\n)
          io << health_wait(s)
          io << proxy(s)
          io << <<-SH
            for old in $(docker ps -a --filter "label=silth.app=$APP" --filter label=silth.role=web --format '{{.Names}}'); do
              if [ "$old" != "$WEB" ]; then
                docker stop -t 30 "$old" > /dev/null || true
                docker rm "$old" > /dev/null || true
              fi
            done

            SH
          io << background(s)
          io << "echo \"$VERSION\" > \"$DIR/current\"\n"
          io << "grep -qx \"$VERSION\" \"$DIR/versions\" 2> /dev/null || echo \"$VERSION\" >> \"$DIR/versions\"\n"
          io << "tail -n +" << s.keep + 1 << " <(tac \"$DIR/versions\") | while read -r v; do docker image rm \"$REPO:$v\" > /dev/null 2>&1 || true; done\n"
          io << "tail -n " << s.keep << " \"$DIR/versions\" > \"$DIR/versions.tmp\" && mv \"$DIR/versions.tmp\" \"$DIR/versions\"\n"
          io << %(echo "[silth] $(hostname) runs #{s.service} #{version}"\n)
        end
      end

      # Containers and versions of the service on a server.
      def self.status(s : Settings) : String
        header(s) + <<-SH
          echo "$(hostname): current $(cat "$DIR/current" 2> /dev/null || echo none), kept $(tr '\\n' ' ' < "$DIR/versions" 2> /dev/null)"
          docker ps -a --filter "label=silth.app=$APP" --format '  {{.Names}}  {{.Status}}'

          SH
      end

      private def self.header(s : Settings) : String
        repo = s.image
        <<-SH
          #!/usr/bin/env bash
          set -euo pipefail
          APP=#{shell(s.service)}
          REPO=#{shell(repo)}
          DIR="$HOME/.silth/$APP"

          SH
      end

      # Waits until GET <healthcheck> answers inside the new container.
      private def self.health_wait(s : Settings) : String
        <<-SH
          healthy=""
          for _ in $(seq 1 #{s.health_timeout}); do
            if docker exec "$WEB" wget -qO- "http://127.0.0.1:#{s.port}#{s.healthcheck}" > /dev/null 2>&1; then healthy=1; break; fi
            sleep 1
          done
          if [ -z "$healthy" ]; then
            echo "[silth] $WEB did not answer #{s.healthcheck}; keeping the current version" >&2
            docker logs --tail 50 "$WEB" >&2 || true
            docker rm -f "$WEB" > /dev/null
            exit 1
          fi

          SH
      end

      # One Caddy container per server serves every Silth app (TLS included).
      private def self.proxy(s : Settings) : String
        site = s.domain || ":80"
        caddyfile = "#{site} {\n  reverse_proxy $WEB:#{s.port}\n}\n"
        <<-SH
          cat > "$DIR/Caddyfile" <<CADDY
          #{caddyfile}CADDY
          echo 'import /etc/silth/*/Caddyfile' > "$HOME/.silth/Caddyfile"
          if docker ps --format '{{.Names}}' | grep -qx silth-proxy; then
            docker exec silth-proxy caddy reload --config /etc/silth/Caddyfile --adapter caddyfile
          else
            docker rm -f silth-proxy > /dev/null 2>&1 || true
            docker run -d --name silth-proxy --network silth --restart unless-stopped -p 80:80 -p 443:443 \\
              -v "$HOME/.silth:/etc/silth:ro" -v silth-caddy-data:/data -v silth-caddy-config:/config \\
              caddy:2-alpine caddy run --config /etc/silth/Caddyfile --adapter caddyfile
          fi

          SH
      end

      # Queue workers and scheduler, replaced by containers of the new image.
      private def self.background(s : Settings) : String
        String.build do |io|
          io << <<-SH
            for old in $(docker ps -a --filter "label=silth.app=$APP" --filter label=silth.role=worker --format '{{.Names}}') \
                       $(docker ps -a --filter "label=silth.app=$APP" --filter label=silth.role=scheduler --format '{{.Names}}'); do
              docker stop -t 30 "$old" > /dev/null || true
              docker rm "$old" > /dev/null || true
            done

            SH
          roles = (1..s.workers).map { |i| {"worker", "#{s.service}-worker-#{i}", "queue:work"} }
          roles << {"scheduler", "#{s.service}-scheduler", "schedule:work"} if s.scheduler
          roles.each do |(role, name, command)|
            io << %(docker rm -f "#{name}" > /dev/null 2>&1 || true\n)
            io << %(docker run -d --name "#{name}" --network silth --restart unless-stopped --env-file "$DIR/.env"#{volumes(s)} )
            io << %(--label silth.app="$APP" --label silth.role=#{role} --label silth.version="$VERSION" "$IMAGE" /app/bin/cli #{command}\n)
          end
        end
      end

      private def self.volumes(s : Settings) : String
        s.volumes.map { |v| " -v #{shell(v)}" }.join
      end

      # Single-quoted for bash.
      def self.shell(value : String) : String
        "'#{value.gsub("'", %('"'"'))}'"
      end
    end

    # Runs local commands and remote scripts (or prints them with `dry_run`).
    class Runner
      def initialize(@settings : Settings, @output : IO = STDOUT, @dry_run : Bool = false)
      end

      def local(command : String, args : Array(String), input : String? = nil) : Nil
        @output.puts "$ #{command} #{args.map { |a| a.includes?(' ') ? Script.shell(a) : a }.join(' ')}"
        return if @dry_run
        status = Process.run(command, args, input: input ? IO::Memory.new(input) : Process::Redirect::Close,
          output: @output, error: @output)
        raise Error.new("`#{command} #{args.first?}` failed (exit #{status.exit_code})") unless status.success?
      end

      def remote(server : String, script : String) : Nil
        @output.puts "$ ssh #{server} bash -s   # #{script.lines.size} lines"
        @output.puts script if @dry_run
        return if @dry_run
        status = Process.run("ssh", @settings.ssh_options + [server, "bash", "-s"], input: IO::Memory.new(script),
          output: @output, error: @output)
        raise Error.new("deployment on #{server} failed (exit #{status.exit_code})") unless status.success?
      end
    end

    # Version deployed by default: the git commit (refused when the tree has
    # uncommitted changes, so a version always matches a commit).
    def self.version(allow_dirty : Bool = false) : String
      sha = `git rev-parse --short=12 HEAD 2> /dev/null`.strip
      raise Error.new("Not a git repository: pass --version") if sha.empty?
      if !allow_dirty && !`git status --porcelain 2> /dev/null`.strip.empty?
        raise Error.new("Uncommitted changes: commit them first (or pass --allow-dirty)")
      end
      sha
    end

    def self.read_env(settings : Settings) : String?
      path = settings.env_file || return nil
      raise Error.new("#{path} not found (deploy.env_file)") unless File.exists?(path)
      File.read(path)
    end

    # Build, push and roll out on every server.
    def self.deploy(settings : Settings, version : String, runner : Runner, build : Bool = true) : Nil
      if build
        runner.local("docker", ["build", "-t", settings.tagged(version), "-t", settings.tagged("latest"), "."])
        if (server = settings.registry) && (user = settings.registry_user) && (password = settings.registry_password)
          runner.local("docker", ["login", server, "-u", user, "--password-stdin"], input: password)
        end
        runner.local("docker", ["push", settings.tagged(version)])
        runner.local("docker", ["push", settings.tagged("latest")])
      end
      env = read_env(settings)
      settings.servers.each_with_index do |server, i|
        runner.remote(server, Script.rollout(settings, version, migrate: build && i == 0, env: env))
      end
    end

    TEMPLATE = <<-YAML
      # silth deploy: builds the Docker image, pushes it, then rolls it out on each
      # server over SSH (Docker required there) with no downtime.
      image: ghcr.io/you/__SERVICE__      # registry/repository of the app image
      servers:
        - deploy@203.0.113.10
      # domain: example.com               # Caddy fronts the app and gets a TLS certificate
      env_file: .env.production           # uploaded to every server (APP_KEY, DATABASE_URL…); keep it out of git
      registry:
        server: ghcr.io
        username: ${REGISTRY_USERNAME:-}
        password: ${REGISTRY_PASSWORD:-}  # read from the environment
      port: 3000
      healthcheck: /up
      health_timeout: 60                  # seconds the new version gets to answer it
      workers: 1                          # `queue:work` containers
      scheduler: true                     # one `schedule:work` container
      # volumes: [storage:/app/storage]   # SQLite databases and local uploads
      keep: 3                             # versions kept for rollbacks
      # ssh_options: [-p, "2222"]
      YAML
  end

  class DeployInit < Command
    command "deploy:init", "Write config/deploy.yml for `silth deploy`"
    option force : Bool = false, "Overwrite an existing file"

    def run : Nil
      path = "config/deploy.yml"
      raise Command::Error.new("#{path} exists (use --force)") if File.exists?(path) && !force
      Dir.mkdir_p("config")
      File.write(path, Deploy::TEMPLATE.gsub("__SERVICE__", DeployCommand.service_name))
      success "Wrote #{path}: set image, servers and domain, then run `silth deploy`"
    end
  end

  class DeployCommand < Command
    command "deploy", "Build the image, push it and roll it out on every server"
    option version : String?, "Version to deploy (default: the git commit)"
    option allow_dirty : Bool = false, "Deploy with uncommitted changes"
    option dry_run : Bool = false, "Print the commands and scripts instead of running them"

    def self.service_name : String
      File.exists?("shard.yml") ? (YAML.parse(File.read("shard.yml"))["name"]?.try(&.as_s) || "app") : "app"
    end

    def self.settings : Deploy::Settings
      Silth.load_config
      Deploy::Settings.load(Silth.config, service_name)
    end

    def run : Nil
      settings = DeployCommand.settings
      tag = version || Deploy.version(allow_dirty || dry_run)
      info "Deploying #{settings.service} #{tag} to #{settings.servers.join(", ")}"
      Deploy.deploy(settings, tag, Deploy::Runner.new(settings, stdout, dry_run))
      dry_run ? info("Dry run: nothing was built or changed") : success("#{settings.service} #{tag} is live")
    rescue ex : Deploy::Error
      raise Command::Error.new(ex.message || "deployment failed")
    end
  end

  class DeployRollback < Command
    command "deploy:rollback", "Run a previous version again (no build, no migrations)"
    argument version : String, "Version to run (see deploy:status)"
    option dry_run : Bool = false, "Print the scripts instead of running them"

    def run : Nil
      settings = DeployCommand.settings
      Deploy.deploy(settings, version, Deploy::Runner.new(settings, stdout, dry_run), build: false)
      success "#{settings.service} rolled back to #{version}"
    rescue ex : Deploy::Error
      raise Command::Error.new(ex.message || "rollback failed")
    end
  end

  class DeployStatus < Command
    command "deploy:status", "Show the version and containers running on each server"

    def run : Nil
      settings = DeployCommand.settings
      runner = Deploy::Runner.new(settings, stdout)
      settings.servers.each { |server| runner.remote(server, Deploy::Script.status(settings)) }
    end
  end
end

require "./spec_helper"

module DeploySpec
  CONFIG = <<-YAML
    deploy:
      image: ghcr.io/acme/shop
      servers: [deploy@10.0.0.1, deploy@10.0.0.2]
      domain: shop.example.com
      volumes: [storage:/app/storage]
      workers: 2
      health_timeout: 1
      registry: { server: ghcr.io, username: bot, password: s3cret }
    YAML

  def self.settings : Silth::Deploy::Settings
    Silth::Deploy::Settings.load(Silth::Config.new(YAML.parse(CONFIG)), "shop")
  end

  # A fake `docker` that logs its arguments; `ps` lists the containers given in
  # the environment, `exec` (the health check) succeeds unless DOCKER_HEALTHY=0.
  FAKE_DOCKER = <<-SH
    #!/usr/bin/env bash
    echo "$*" >> "$DOCKER_LOG"
    case "$1" in
      ps)
        case "$*" in
          *silth.role=web*) printf '%s\\n' $DOCKER_WEB ;;
          *silth.role=worker*) printf '%s\\n' $DOCKER_WORKERS ;;
          *silth.role=scheduler*) ;;
          *) printf '%s\\n' $DOCKER_RUNNING ;;
        esac ;;
      exec) [ "${DOCKER_HEALTHY:-1}" = 1 ] ;;
      network) [ "$2" != inspect ] ;;
    esac
    SH

  # Runs a rollout script on a fake server; returns {exit status, docker calls, home}.
  def self.run(script : String, env = {} of String => String) : {Int32, Array(String), String}
    home = File.tempname("silth-deploy", nil)
    Dir.mkdir_p(File.join(home, "bin"))
    File.write(File.join(home, "bin/docker"), FAKE_DOCKER)
    File.chmod(File.join(home, "bin/docker"), 0o755)
    log = File.join(home, "docker.log")
    full_env = {"HOME" => home, "PATH" => "#{home}/bin:#{ENV["PATH"]}", "DOCKER_LOG" => log}.merge(env)
    status = Process.run("bash", input: IO::Memory.new(script), env: full_env, output: Process::Redirect::Close, error: Process::Redirect::Close)
    {status.exit_code, File.exists?(log) ? File.read_lines(log) : [] of String, home}
  end
end

describe Silth::Deploy do
  it "reads config/deploy.yml" do
    s = DeploySpec.settings
    {s.service, s.servers.size, s.domain, s.workers, s.volumes}.should eq({"shop", 2, "shop.example.com", 2, ["storage:/app/storage"]})
    expect_raises(Silth::Deploy::Error, /`image` is missing/) do
      Silth::Deploy::Settings.load(Silth::Config.new(YAML.parse("deploy:\n  servers: [a]")), "shop")
    end
  end

  it "switches to the new version once it is healthy, then stops the old one" do
    script = Silth::Deploy::Script.rollout(DeploySpec.settings, "v2", migrate: true, env: "APP_KEY=k\n")
    status, calls, home = DeploySpec.run(script, {"DOCKER_WEB" => "shop-web-v1 shop-web-v2", "DOCKER_WORKERS" => "shop-worker-1"})
    begin
      status.should eq(0)
      order = ["pull ", "/app/bin/cli db:migrate", "--name shop-web-v2", "exec shop-web-v2 wget", "--name silth-proxy",
               "stop -t 30 shop-web-v1", "stop -t 30 shop-worker-1", "--name shop-worker-2", "--name shop-scheduler"]
      positions = order.map { |part| calls.index(&.includes?(part)) || raise "no docker call with #{part.inspect}: #{calls}" }
      positions.should eq(positions.sort)
      calls.any?(&.includes?("stop -t 30 shop-web-v2")).should be_false
      calls.find(&.includes?("--name shop-web-v2")).not_nil!.should contain("-v storage:/app/storage")
      File.read(File.join(home, ".silth/shop/Caddyfile")).should eq("shop.example.com {\n  reverse_proxy shop-web-v2:3000\n}\n")
      File.read(File.join(home, ".silth/shop/.env")).should eq("APP_KEY=k\n")
      File.read(File.join(home, ".silth/shop/current")).should eq("v2\n")
    ensure
      FileUtils.rm_rf(home)
    end
  end

  it "keeps the running version when the new one does not answer" do
    script = Silth::Deploy::Script.rollout(DeploySpec.settings, "v3", migrate: false, env: nil)
    status, calls, home = DeploySpec.run(script, {"DOCKER_WEB" => "shop-web-v2", "DOCKER_HEALTHY" => "0"})
    begin
      status.should eq(1)
      calls.should contain("rm -f shop-web-v3")
      calls.any?(&.starts_with?("stop ")).should be_false
      calls.any?(&.includes?("db:migrate")).should be_false
      File.exists?(File.join(home, ".silth/shop/current")).should be_false
    ensure
      FileUtils.rm_rf(home)
    end
  end

  it "builds, pushes and rolls out on every server (dry run)" do
    output = IO::Memory.new
    s = DeploySpec.settings
    Silth::Deploy.deploy(s, "abc123", Silth::Deploy::Runner.new(s, output, dry_run: true))
    text = output.to_s
    text.should contain("$ docker build -t ghcr.io/acme/shop:abc123 -t ghcr.io/acme/shop:latest .")
    text.should contain("$ docker login ghcr.io -u bot --password-stdin")
    text.should_not contain("s3cret")
    text.should contain("$ docker push ghcr.io/acme/shop:abc123")
    text.scan(/\$ ssh deploy@10\.0\.0\.\d bash -s/).size.should eq(2)
    text.scan("/app/bin/cli db:migrate").size.should eq(1) # first server only
  end

  it "writes config/deploy.yml" do
    dir = File.tempname("silth-deploy-init", nil)
    Dir.mkdir_p(dir)
    begin
      Dir.cd(dir) do
        File.write("shard.yml", "name: shop\nversion: 0.1.0\n")
        Silth::DeployInit.new.tap { |c| c.stdout = IO::Memory.new }.run
        File.read("config/deploy.yml").should contain("image: ghcr.io/you/shop")
      end
    ensure
      FileUtils.rm_rf(dir)
    end
  end
end

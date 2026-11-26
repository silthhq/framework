module Silth::Generators
  # `silth new my_app` — creates a complete application skeleton.
  class App
    TEMPLATES = {{ run("./embed", __DIR__ + "/templates/app") }}

    getter created = [] of String

    # *edge* depends on the framework's main branch and the `edge` images instead
    # of the current release line.
    def initialize(@name : String, @database : String = "sqlite", @silth_path : String? = nil, @output : IO = STDOUT, @edge : Bool = false)
    end

    def app_name : String
      Inflector.underscore(File.basename(@name)).gsub(/[^a-z0-9_]/, "_")
    end

    def app_title : String
      Inflector.titleize(app_name)
    end

    def database_url(env : String = "development") : String
      case @database
      when "postgres", "postgresql", "pg" then "postgres://postgres:postgres@localhost:5432/#{app_name}_#{env}"
      when "mysql", "mariadb"             then "mysql://root:root@localhost:3306/#{app_name}_#{env}"
      else                                     "sqlite3://./db/#{env}.sqlite3"
      end
    end

    # The `silth` entry of the app's shard.yml: a local checkout, the main branch
    # (`--edge`), or the release line of this CLI (`~> 0.1.0`: 0.1.x patches only).
    def dependency : String
      if path = @silth_path
        "    path: #{path}"
      elsif @edge
        "    github: silthhq/framework\n    branch: main"
      else
        "    github: silthhq/framework\n    version: ~> #{Silth::VERSION.split(/[-+]/).first}"
      end
    end

    # Tag of the official images the app's Dockerfile builds on.
    def image_tag : String
      @edge ? "edge" : Silth.release_line
    end

    def run(target : String = @name) : Nil
      raise Silth::Error.new("Directory #{target} already exists") if Dir.exists?(target) && !Dir.empty?(target)
      replacements = {
        "__APP_NAME__"     => app_name,
        "__APP_TITLE__"    => app_title,
        "__DB_URL__"       => database_url,
        "__TEST_DB_URL__"  => @database == "sqlite" ? "sqlite3::memory:" : database_url("test"),
        "__APP_KEY__"      => Crypto.generate_app_key,
        "__SILTH_DEP__"    => dependency,
        "__SILTH_IMAGE__"  => image_tag,
      }
      TEMPLATES.each do |path, content|
        dest = path.rchop(".tt").split('/').map { |part| part.starts_with?("dot.") ? "." + part.lchop("dot.") : part }.join('/')
        text = content
        replacements.each { |k, v| text = text.gsub(k, v) }
        file = File.join(target, dest)
        Dir.mkdir_p(File.dirname(file))
        File.write(file, text)
        @created << dest
        @output.puts "  #{"create".colorize(:green)}  #{dest}" unless dest.ends_with?(".keep")
      end
    end
  end
end

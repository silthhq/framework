require "yaml"

module Silth
  class ConfigError < Exception; end

  # YAML configuration loader.
  #
  # Every `config/*.yml` file becomes a top-level key named after the file:
  # `config/database.yml` is reachable through `Silth.config.string("database.url")`.
  #
  # Features:
  # * `${VAR}`, `${VAR:-default}` and `${VAR:?message}` environment interpolation
  # * `when@<env>:` blocks deep-merged when the current environment matches (Symfony style)
  # * typed accessors: `string`, `int`, `bool`, `float`, `array`, `hash`, `bind(T)`
  #
  # ```yaml
  # # config/app.yml
  # name: Silth
  # url: ${APP_URL:-http://localhost:3000}
  # debug: false
  # when@development:
  #   debug: true
  # ```
  class Config
    getter data : YAML::Any
    @overrides = {} of String => YAML::Any

    def initialize(@data : YAML::Any = YAML::Any.new({} of YAML::Any => YAML::Any))
    end

    def self.load(dir : String, env : String = Silth.env) : Config
      root = {} of YAML::Any => YAML::Any
      return new(YAML::Any.new(root)) unless Dir.exists?(dir)
      files = Dir.glob(File.join(dir, "*.yml")) + Dir.glob(File.join(dir, "*.yaml"))
      files.sort.each do |path|
        name = File.basename(path).sub(/\.ya?ml$/, "")
        root[YAML::Any.new(name)] = parse(File.read(path), env, path)
      end
      new(YAML::Any.new(root))
    end

    def self.parse(content : String, env : String = Silth.env, source = "<string>") : YAML::Any
      parsed = content.strip.empty? ? YAML::Any.new({} of YAML::Any => YAML::Any) : YAML.parse(content)
      interpolate(apply_env_blocks(parsed, env), source)
    rescue ex : YAML::ParseException
      raise ConfigError.new("Invalid YAML in #{source}: #{ex.message}")
    end

    # Merges `when@env:` blocks into their parent mapping.
    def self.apply_env_blocks(node : YAML::Any, env : String) : YAML::Any
      if hash = node.as_h?
        base = {} of YAML::Any => YAML::Any
        overlays = [] of YAML::Any
        hash.each do |k, v|
          key = k.as_s? || k.raw.to_s
          if key.starts_with?("when@")
            envs = key.lchop("when@").split(/[,|]/).map(&.strip)
            overlays << apply_env_blocks(v, env) if envs.includes?(env)
          else
            base[k] = apply_env_blocks(v, env)
          end
        end
        result = YAML::Any.new(base)
        overlays.each { |o| result = deep_merge(result, o) }
        result
      elsif arr = node.as_a?
        YAML::Any.new(arr.map { |v| apply_env_blocks(v, env) })
      else
        node
      end
    end

    def self.deep_merge(a : YAML::Any, b : YAML::Any) : YAML::Any
      ah = a.as_h?
      bh = b.as_h?
      return b unless ah && bh
      merged = ah.dup
      bh.each do |k, v|
        merged[k] = merged.has_key?(k) ? deep_merge(merged[k], v) : v
      end
      YAML::Any.new(merged)
    end

    INTERPOLATION = /\$\{([A-Za-z_][A-Za-z0-9_]*)(?:(:-|:\?)([^}]*))?\}/

    def self.interpolate(node : YAML::Any, source = "<string>") : YAML::Any
      case raw = node.raw
      when String
        return node unless raw.includes?("${")
        value = raw.gsub(INTERPOLATION) do |_, m|
          if val = ENV[m[1]]?
            val
          elsif m[2]? == ":?"
            raise ConfigError.new("Missing required environment variable #{m[1]} (#{source}): #{m[3]?}")
          else
            m[3]? || ""
          end
        end
        YAML::Any.new(value)
      when Hash
        h = {} of YAML::Any => YAML::Any
        raw.each { |k, v| h[k] = interpolate(v, source) }
        YAML::Any.new(h)
      when Array
        YAML::Any.new(raw.map { |v| interpolate(v, source) })
      else
        node
      end
    end

    # Override a value at runtime (handy in tests).
    def set(path : String, value) : Nil
      @overrides[path] = to_any(value)
    end

    def reset_overrides : Nil
      @overrides.clear
    end

    def dig?(path : String) : YAML::Any?
      if v = @overrides[path]?
        return v
      end
      node = @data
      path.split('.').each do |part|
        if h = node.as_h?
          node = h[YAML::Any.new(part)]? || return nil
        elsif a = node.as_a?
          idx = part.to_i? || return nil
          node = a[idx]? || return nil
        else
          return nil
        end
      end
      node.raw.nil? ? nil : node
    end

    def has?(path : String) : Bool
      !dig?(path).nil?
    end

    def string?(path : String) : String?
      dig?(path).try { |v| v.raw.to_s }.presence
    end

    def string(path : String) : String
      string?(path) || raise ConfigError.new("Missing configuration value '#{path}'")
    end

    def string(path : String, default : String) : String
      string?(path) || default
    end

    def int?(path : String) : Int64?
      node = dig?(path) || return nil
      case raw = node.raw
      when Int64   then raw
      when Float64 then raw.to_i64
      when String  then raw.strip.to_i64?
      else              nil
      end
    end

    def int(path : String, default : Int) : Int32
      (int?(path) || default).to_i32
    end

    def int64(path : String, default : Int) : Int64
      int?(path) || default.to_i64
    end

    def float(path : String, default : Float64) : Float64
      node = dig?(path) || return default
      case raw = node.raw
      when Float64 then raw
      when Int64   then raw.to_f
      when String  then raw.to_f? || default
      else              default
      end
    end

    def bool?(path : String) : Bool?
      node = dig?(path) || return nil
      case raw = node.raw
      when Bool   then raw
      when Int64  then raw != 0
      when String then %w(1 true yes on).includes?(raw.strip.downcase)
      else             nil
      end
    end

    def bool(path : String, default : Bool = false) : Bool
      v = bool?(path)
      v.nil? ? default : v
    end

    def array(path : String) : Array(String)
      node = dig?(path) || return [] of String
      if arr = node.as_a?
        arr.map(&.raw.to_s)
      else
        node.raw.to_s.split(',').map(&.strip).reject(&.empty?)
      end
    end

    def hash(path : String) : Hash(String, String)
      node = dig?(path) || return {} of String => String
      result = {} of String => String
      node.as_h?.try &.each { |k, v| result[k.raw.to_s] = v.raw.to_s }
      result
    end

    def section(path : String) : Hash(String, YAML::Any)
      node = dig?(path) || return {} of String => YAML::Any
      result = {} of String => YAML::Any
      node.as_h?.try &.each { |k, v| result[k.raw.to_s] = v }
      result
    end

    def keys(path : String) : Array(String)
      section(path).keys
    end

    # Maps a section onto any `YAML::Serializable` type.
    def bind(path : String, type : T.class) : T forall T
      node = dig?(path) || YAML::Any.new({} of YAML::Any => YAML::Any)
      T.from_yaml(node.to_yaml)
    end

    def to_h : Hash(String, YAML::Any)
      section_from(@data)
    end

    private def section_from(node : YAML::Any) : Hash(String, YAML::Any)
      result = {} of String => YAML::Any
      node.as_h?.try &.each { |k, v| result[k.raw.to_s] = v }
      result
    end

    private def to_any(value) : YAML::Any
      case value
      when YAML::Any then value
      when Int       then YAML::Any.new(value.to_i64)
      when Float     then YAML::Any.new(value.to_f64)
      when Array     then YAML::Any.new(value.map { |v| to_any(v) })
      when Hash
        h = {} of YAML::Any => YAML::Any
        value.each { |k, v| h[YAML::Any.new(k.to_s)] = to_any(v) }
        YAML::Any.new(h)
      when Bool then YAML::Any.new(value)
      when Nil  then YAML::Any.new(nil)
      else           YAML::Any.new(value.to_s)
      end
    end
  end
end

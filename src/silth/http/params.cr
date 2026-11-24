require "http/request"
require "http/formdata"
require "uri/params"
require "json"

module Silth
  # A file uploaded through a multipart form. The content lives in a tempfile
  # that is removed at the end of the request.
  class UploadedFile
    getter filename : String
    getter content_type : String
    getter size : Int64
    getter tempfile : File
    getter field : String

    def initialize(@field : String, @filename : String, @content_type : String, @tempfile : File, @size : Int64)
    end

    def path : String
      @tempfile.path
    end

    def extension : String
      File.extname(@filename).lchop('.').downcase
    end

    def read : Bytes
      File.read(path).to_slice
    end

    def move_to(destination : String) : Nil
      Dir.mkdir_p(File.dirname(destination))
      FileUtils.cp(path, destination)
    end

    def cleanup : Nil
      @tempfile.close rescue nil
      File.delete?(path)
    end
  end

  # Request parameters merged from route segments, query string, form body and JSON body.
  # Route params win over body params which win over query params.
  #
  # ```
  # params["id"]               # => String (raises when missing)
  # params["q"]?               # => String?
  # params.int("page", 1)      # => Int32 with default
  # params.nested("post")      # => {"title" => "...", "body" => "..."} from post[title]=...
  # params.file("avatar")      # => UploadedFile?
  # params.json                # => JSON::Any (JSON bodies)
  # ```
  class Params
    class MissingParam < Silth::BadRequest
      def initialize(name)
        super("Missing required parameter '#{name}'")
      end
    end

    getter values = {} of String => String
    getter multi = {} of String => Array(String)
    getter files = {} of String => UploadedFile
    getter json : JSON::Any?

    MAX_BODY = 50 * 1024 * 1024

    def initialize
    end

    def self.parse(request : HTTP::Request, route_params : Hash(String, String) = {} of String => String) : Params
      params = new
      request.query_params.each { |k, v| params.add(k, v) }
      params.parse_body(request)
      route_params.each { |k, v| params.set(k, v) }
      params
    end

    def parse_body(request : HTTP::Request) : Nil
      body = request.body || return
      content_type = request.headers["Content-Type"]? || ""
      if content_type.starts_with?("application/x-www-form-urlencoded")
        URI::Params.parse(body.gets_to_end).each { |k, v| add(k, v) }
      elsif content_type.starts_with?("multipart/form-data")
        HTTP::FormData.parse(request) do |part|
          if filename = part.filename
            next if filename.empty?
            tempfile = File.tempfile("silth-upload", File.extname(filename))
            size = IO.copy(part.body, tempfile)
            tempfile.flush
            @files[part.name] = UploadedFile.new(part.name, filename, part.headers["Content-Type"]? || "application/octet-stream", tempfile, size.to_i64)
          else
            add(part.name, part.body.gets_to_end)
          end
        end
      elsif content_type.includes?("json")
        raw = body.gets_to_end
        return if raw.strip.empty?
        parsed = JSON.parse(raw)
        @json = parsed
        if h = parsed.as_h?
          flatten_json("", h)
        end
      end
    rescue ex : JSON::ParseException
      raise Silth::BadRequest.new("Malformed JSON body: #{ex.message}")
    end

    private def flatten_json(prefix : String, hash : Hash(String, JSON::Any))
      hash.each do |k, v|
        key = prefix.empty? ? k : "#{prefix}[#{k}]"
        case raw = v.raw
        when Hash  then flatten_json(key, raw)
        when Array then raw.each { |item| add("#{key}[]", item.raw.is_a?(String) ? item.as_s : item.to_json) }
        when Nil   then set(key, "")
        when String
          set(key, raw)
        else
          set(key, raw.to_s)
        end
      end
    end

    def add(key : String, value : String) : Nil
      @values[key] = value
      (@multi[key] ||= [] of String) << value
    end

    def set(key : String, value : String) : Nil
      @values[key] = value
      @multi[key] = [value]
    end

    def delete(key : String) : Nil
      @values.delete(key)
      @multi.delete(key)
    end

    def [](key : String | Symbol) : String
      @values[key.to_s]? || raise MissingParam.new(key)
    end

    def []?(key : String | Symbol) : String?
      @values[key.to_s]?
    end

    def has?(key : String | Symbol) : Bool
      @values.has_key?(key.to_s) || @files.has_key?(key.to_s)
    end

    def string(key : String | Symbol, default : String = "") : String
      @values[key.to_s]? || default
    end

    def all(key : String | Symbol) : Array(String)
      @multi[key.to_s]? || @multi["#{key}[]"]? || [] of String
    end

    def int(key : String | Symbol) : Int32
      self[key].to_i? || raise Silth::BadRequest.new("Parameter '#{key}' must be an integer")
    end

    def int(key : String | Symbol, default : Int32) : Int32
      self[key]?.try(&.to_i?) || default
    end

    def int64(key : String | Symbol) : Int64
      self[key].to_i64? || raise Silth::BadRequest.new("Parameter '#{key}' must be an integer")
    end

    def int64(key : String | Symbol, default : Int64) : Int64
      self[key]?.try(&.to_i64?) || default
    end

    def float(key : String | Symbol, default : Float64 = 0.0) : Float64
      self[key]?.try(&.to_f?) || default
    end

    def bool(key : String | Symbol, default : Bool = false) : Bool
      value = self[key]? || return default
      %w(1 true on yes).includes?(value.downcase)
    end

    def time?(key : String | Symbol) : Time?
      value = self[key]?.presence || return nil
      Time.parse_iso8601(value) rescue Time.parse(value, "%F", Time::Location::UTC) rescue nil
    end

    def file(key : String | Symbol) : UploadedFile?
      @files[key.to_s]?
    end

    # Extracts `prefix[field]` keys into a flat hash: `nested("post")`.
    def nested(prefix : String | Symbol) : Hash(String, String)
      start = "#{prefix}["
      result = {} of String => String
      @values.each do |k, v|
        next unless k.starts_with?(start) && k.ends_with?(']')
        inner = k[start.size..-2]
        next if inner.includes?('[')
        result[inner] = v
      end
      result
    end

    # Keeps only the listed keys (strong parameters).
    def permit(*keys : String | Symbol, from : String | Symbol | Nil = nil) : Hash(String, String)
      source = from ? nested(from) : @values
      allowed = keys.map(&.to_s).to_set
      source.select { |k, _| allowed.includes?(k) }
    end

    def to_h : Hash(String, String)
      @values.dup
    end

    def each(& : String, String ->)
      @values.each { |k, v| yield k, v }
    end

    def empty? : Bool
      @values.empty? && @files.empty?
    end

    def cleanup : Nil
      @files.each_value &.cleanup
    end
  end
end

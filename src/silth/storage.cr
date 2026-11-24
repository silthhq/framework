require "http/client"

module Silth
  # File storage with interchangeable disks (local, memory, S3 compatible).
  #
  # ```yaml
  # # config/storage.yml
  # default: local
  # disks:
  #   local:  { driver: local, root: storage/app, url: /files }
  #   public: { driver: local, root: public/uploads, url: /uploads }
  #   s3:
  #     driver: s3
  #     bucket: ${S3_BUCKET}
  #     region: ${S3_REGION:-us-east-1}
  #     key: ${S3_KEY}
  #     secret: ${S3_SECRET}
  #     endpoint: ${S3_ENDPOINT:-}        # MinIO, R2, Scaleway…
  #     path_style: false
  # ```
  #
  # ```
  # Silth.storage.put("avatars/#{user.id}.png", file.read, content_type: "image/png")
  # Silth.storage(:s3).temporary_url("reports/q4.pdf", 15.minutes)
  # ```
  module Storage
    class NotFound < Silth::Error; end

    abstract class Disk
      abstract def put(path : String, content : Bytes | String, content_type : String? = nil) : Nil
      abstract def get?(path : String) : Bytes?
      abstract def exists?(path : String) : Bool
      abstract def delete(path : String) : Bool
      abstract def list(prefix : String = "") : Array(String)
      abstract def url(path : String) : String

      def get(path : String) : Bytes
        get?(path) || raise NotFound.new("File not found: #{path}")
      end

      def read(path : String) : String
        String.new(get(path))
      end

      def size(path : String) : Int64
        get(path).size.to_i64
      end

      def temporary_url(path : String, expires_in : Time::Span = 5.minutes) : String
        SignedURL.sign(url(path), expires_in)
      end

      # Stores an uploaded file under `directory` with a unique name; returns the path.
      def put_file(directory : String, file : UploadedFile, name : String? = nil) : String
        filename = name || "#{Crypto.uuid7}#{File.extname(file.filename).downcase}"
        path = directory.empty? ? filename : "#{directory.rstrip('/')}/#{filename}"
        put(path, file.read, file.content_type)
        path
      end

      def copy(from : String, to : String) : Nil
        put(to, get(from))
      end

      def move(from : String, to : String) : Nil
        copy(from, to)
        delete(from)
      end

      protected def clean(path : String) : String
        cleaned = path.lchop('/')
        raise ArgumentError.new("Invalid storage path: #{path}") if cleaned.split('/').includes?("..")
        cleaned
      end
    end

    class LocalDisk < Disk
      def initialize(@root : String, @base_url : String = "/files")
      end

      private def full(path : String) : String
        File.join(@root, clean(path))
      end

      def put(path : String, content : Bytes | String, content_type : String? = nil) : Nil
        file = full(path)
        Dir.mkdir_p(File.dirname(file))
        File.write(file, content)
      end

      def get?(path : String) : Bytes?
        file = full(path)
        File.file?(file) ? File.read(file).to_slice : nil
      end

      def exists?(path : String) : Bool
        File.file?(full(path))
      end

      def delete(path : String) : Bool
        file = full(path)
        File.file?(file) ? (File.delete(file); true) : false
      end

      def size(path : String) : Int64
        File.size(full(path)).to_i64
      end

      def list(prefix : String = "") : Array(String)
        base = File.join(@root, clean(prefix))
        return [] of String unless Dir.exists?(base) || File.exists?(base)
        Dir.glob(File.join(base, "**", "*")).select { |f| File.file?(f) }.map { |f| f[(@root.rstrip('/').size + 1)..] }.sort
      end

      def url(path : String) : String
        "#{@base_url.rstrip('/')}/#{clean(path)}"
      end

      def path(path : String) : String
        full(path)
      end
    end

    class MemoryDisk < Disk
      getter files = {} of String => Bytes

      def put(path : String, content : Bytes | String, content_type : String? = nil) : Nil
        @files[clean(path)] = content.to_slice.dup
      end

      def get?(path : String) : Bytes?
        @files[clean(path)]?
      end

      def exists?(path : String) : Bool
        @files.has_key?(clean(path))
      end

      def delete(path : String) : Bool
        !@files.delete(clean(path)).nil?
      end

      def list(prefix : String = "") : Array(String)
        @files.keys.select(&.starts_with?(clean(prefix))).sort
      end

      def url(path : String) : String
        "/memory/#{clean(path)}"
      end
    end

    # Amazon S3 and S3 compatible services with an in-house AWS Signature V4 implementation.
    class S3Disk < Disk
      getter bucket : String

      def initialize(@bucket : String, @region : String, @key : String, @secret : String,
                     @endpoint : String? = nil, @path_style : Bool = false, @public_url : String? = nil)
      end

      private def host : String
        if ep = @endpoint.presence
          URI.parse(ep).host.not_nil!
        else
          @path_style ? "s3.#{@region}.amazonaws.com" : "#{@bucket}.s3.#{@region}.amazonaws.com"
        end
      end

      private def scheme_port : {String, Int32?}
        if ep = @endpoint.presence
          uri = URI.parse(ep)
          {uri.scheme || "https", uri.port}
        else
          {"https", nil}
        end
      end

      private def object_path(path : String) : String
        encoded = clean(path).split('/').map { |s| S3Disk.encode(s) }.join('/')
        (@path_style || @endpoint.presence) ? "/#{@bucket}/#{encoded}" : "/#{encoded}"
      end

      def put(path : String, content : Bytes | String, content_type : String? = nil) : Nil
        body = content.to_slice
        headers = HTTP::Headers{"Content-Type" => content_type || MIME.from_filename(path, "application/octet-stream")}
        res = request("PUT", object_path(path), headers, body)
        raise Silth::Error.new("S3 PUT #{path} failed: #{res.status_code} #{res.body}") unless res.success?
      end

      def get?(path : String) : Bytes?
        res = request("GET", object_path(path))
        return nil if res.status_code == 404
        raise Silth::Error.new("S3 GET #{path} failed: #{res.status_code}") unless res.success?
        res.body.to_slice
      end

      def exists?(path : String) : Bool
        request("HEAD", object_path(path)).success?
      end

      def delete(path : String) : Bool
        request("DELETE", object_path(path)).success?
      end

      def size(path : String) : Int64
        res = request("HEAD", object_path(path))
        res.headers["Content-Length"]?.try(&.to_i64) || 0_i64
      end

      def list(prefix : String = "") : Array(String)
        base = (@path_style || @endpoint.presence) ? "/#{@bucket}" : "/"
        res = request("GET", base, query: {"list-type" => "2", "prefix" => clean(prefix)})
        res.body.scan(/<Key>([^<]+)<\/Key>/).map { |m| HTML.unescape(m[1]) }
      end

      def url(path : String) : String
        if pub = @public_url
          "#{pub.rstrip('/')}/#{clean(path)}"
        else
          scheme, port = scheme_port
          "#{scheme}://#{host}#{port ? ":#{port}" : ""}#{object_path(path)}"
        end
      end

      # Presigned GET URL (query string authentication).
      def temporary_url(path : String, expires_in : Time::Span = 5.minutes) : String
        now = Time.utc
        date = now.to_s("%Y%m%d")
        amz_date = now.to_s("%Y%m%dT%H%M%SZ")
        scope = "#{date}/#{@region}/s3/aws4_request"
        query = {
          "X-Amz-Algorithm"     => "AWS4-HMAC-SHA256",
          "X-Amz-Credential"    => "#{@key}/#{scope}",
          "X-Amz-Date"          => amz_date,
          "X-Amz-Expires"       => expires_in.total_seconds.to_i.to_s,
          "X-Amz-SignedHeaders" => "host",
        }
        canonical_query = query.to_a.sort_by(&.[0]).map { |k, v| "#{S3Disk.encode(k)}=#{S3Disk.encode(v)}" }.join('&')
        uri_path = object_path(path)
        canonical = "GET\n#{uri_path}\n#{canonical_query}\nhost:#{host_header}\n\nhost\nUNSIGNED-PAYLOAD"
        signature = sign(date, "AWS4-HMAC-SHA256\n#{amz_date}\n#{scope}\n#{Digest::SHA256.hexdigest(canonical)}")
        scheme, port = scheme_port
        "#{scheme}://#{host}#{port ? ":#{port}" : ""}#{uri_path}?#{canonical_query}&X-Amz-Signature=#{signature}"
      end

      private def host_header : String
        _, port = scheme_port
        port ? "#{host}:#{port}" : host
      end

      private def request(method : String, path : String, headers : HTTP::Headers = HTTP::Headers.new, body : Bytes? = nil,
                          query : Hash(String, String) = {} of String => String) : HTTP::Client::Response
        now = Time.utc
        date = now.to_s("%Y%m%d")
        amz_date = now.to_s("%Y%m%dT%H%M%SZ")
        payload_hash = Digest::SHA256.hexdigest(body || Bytes.empty)
        headers["Host"] = host_header
        headers["X-Amz-Date"] = amz_date
        headers["X-Amz-Content-Sha256"] = payload_hash
        signed = headers.to_a.map { |(k, v)| {k.downcase, v.first.strip} }.sort_by(&.[0])
        canonical_query = query.to_a.sort_by(&.[0]).map { |k, v| "#{S3Disk.encode(k)}=#{S3Disk.encode(v)}" }.join('&')
        canonical = String.build do |io|
          io << method << '\n' << path << '\n' << canonical_query << '\n'
          signed.each { |(k, v)| io << k << ':' << v << '\n' }
          io << '\n' << signed.map(&.[0]).join(';') << '\n' << payload_hash
        end
        scope = "#{date}/#{@region}/s3/aws4_request"
        signature = sign(date, "AWS4-HMAC-SHA256\n#{amz_date}\n#{scope}\n#{Digest::SHA256.hexdigest(canonical)}")
        headers["Authorization"] = "AWS4-HMAC-SHA256 Credential=#{@key}/#{scope}, SignedHeaders=#{signed.map(&.[0]).join(';')}, Signature=#{signature}"
        scheme, port = scheme_port
        client = HTTP::Client.new(host, port, tls: scheme == "https")
        client.connect_timeout = 10.seconds
        target = canonical_query.empty? ? path : "#{path}?#{canonical_query}"
        begin
          client.exec(method, target, headers, body)
        ensure
          client.close
        end
      end

      private def sign(date : String, string_to_sign : String) : String
        k_date = OpenSSL::HMAC.digest(OpenSSL::Algorithm::SHA256, "AWS4#{@secret}", date)
        k_region = OpenSSL::HMAC.digest(OpenSSL::Algorithm::SHA256, k_date, @region)
        k_service = OpenSSL::HMAC.digest(OpenSSL::Algorithm::SHA256, k_region, "s3")
        k_signing = OpenSSL::HMAC.digest(OpenSSL::Algorithm::SHA256, k_service, "aws4_request")
        OpenSSL::HMAC.hexdigest(OpenSSL::Algorithm::SHA256, k_signing, string_to_sign)
      end

      # AWS style URI encoding (RFC 3986 unreserved characters kept).
      def self.encode(value : String) : String
        String.build do |io|
          value.each_byte do |b|
            c = b.unsafe_chr
            if c.ascii_alphanumeric? || c.in?('-', '_', '.', '~')
              io << c
            else
              io << '%' << b.to_s(16, upcase: true).rjust(2, '0')
            end
          end
        end
      end
    end

    @@disks = {} of String => Disk

    def self.disk(name : String? = nil) : Disk
      disk_name = name || Silth.config.string("storage.default", "local")
      @@disks[disk_name] ||= build(disk_name)
    end

    def self.disk=(disk : Disk) : Nil
      @@disks[Silth.config.string("storage.default", "local")] = disk
    end

    def self.register(name : String, disk : Disk) : Nil
      @@disks[name] = disk
    end

    def self.fake(name : String? = nil) : MemoryDisk
      disk = MemoryDisk.new
      @@disks[name || Silth.config.string("storage.default", "local")] = disk
      disk
    end

    def self.build(name : String) : Disk
      c = Silth.config
      base = "storage.disks.#{name}"
      case c.string("#{base}.driver", name == "s3" ? "s3" : "local")
      when "local"  then LocalDisk.new(c.string("#{base}.root", "storage/#{name}"), c.string("#{base}.url", "/files"))
      when "memory" then MemoryDisk.new
      when "s3"
        S3Disk.new(c.string("#{base}.bucket"), c.string("#{base}.region", "us-east-1"), c.string("#{base}.key"), c.string("#{base}.secret"),
          c.string?("#{base}.endpoint"), c.bool("#{base}.path_style", false), c.string?("#{base}.url"))
      else raise ConfigError.new("Unknown storage driver for disk '#{name}'")
      end
    end
  end

  def self.storage(name : String | Symbol | Nil = nil) : Storage::Disk
    Storage.disk(name.try(&.to_s))
  end
end

require "digest/sha256"
require "compress/gzip"

module Silth
  # Asset management without a JavaScript toolchain:
  #
  # * development: files are served straight from `assets/` (no build step)
  # * production: `silth assets:build` copies them to `public/assets` with content
  #   fingerprints (`app-3f2a9c1d.css`), gzip variants and a `manifest.json`
  # * import maps (`config/importmap.yml`) for native ES modules
  class Assets
    getter source_dir : String
    getter output_dir : String
    getter prefix : String
    @manifest : Hash(String, String)?
    @manifest_loaded = false

    def initialize(@source_dir = "assets", @output_dir = "public/assets", @prefix = "/assets")
    end

    def manifest : Hash(String, String)?
      return @manifest if @manifest_loaded && Silth.env != "development"
      @manifest_loaded = true
      path = File.join(@output_dir, "manifest.json")
      @manifest = File.exists?(path) ? Hash(String, String).from_json(File.read(path)) : nil
    end

    # Public URL of a logical asset path (`"app.css"` → `"/assets/app-3f2a9c1d.css"`).
    def path(logical : String) : String
      return logical if logical.starts_with?("http://") || logical.starts_with?("https://") || logical.starts_with?("//")
      clean = logical.lchop('/').lchop("assets/")
      if Silth.env != "development" && (m = manifest) && (digested = m[clean]?)
        "#{@prefix}/#{digested}"
      else
        "#{@prefix}/#{clean}"
      end
    end

    def importmap : Hash(String, String)
      result = {} of String => String
      file = "config/importmap.yml"
      return result unless File.exists?(file)
      yaml = Config.parse(File.read(file), Silth.env, file)
      (yaml["imports"]?.try(&.as_h?) || yaml.as_h? || {} of YAML::Any => YAML::Any).each do |k, v|
        target = v.as_s
        result[k.as_s] = target.starts_with?("/") || target.starts_with?("http") ? target : path(target)
      end
      result
    end

    def importmap_tags(entry : String = "app", nonce : String? = nil) : String
      map = importmap
      map["silth"] ||= "/_silth/silth.js"
      nonce_attr = nonce ? %( nonce="#{nonce}") : ""
      String.build do |io|
        io << %(<script type="importmap") << nonce_attr << '>'
        {imports: map}.to_json(io)
        io << "</script>"
        map.each_value do |url|
          next if url.ends_with?('/')
          io << %(<link rel="modulepreload" href=") << HTML.escape(url) << %(">)
        end
        io << %(<script type="module") << nonce_attr << %(>import ") << HTML.escape(entry) << %(";</script>) if map.has_key?(entry)
      end
    end

    # Fingerprints every asset into `output_dir` and writes the manifest.
    def build(minify : Bool = true) : Hash(String, String)
      manifest = {} of String => String
      return manifest unless Dir.exists?(@source_dir)
      Dir.mkdir_p(@output_dir)
      files = Dir.glob(File.join(@source_dir, "**", "*")).select { |f| File.file?(f) }
      # Non CSS first, so CSS url() references can be rewritten to fingerprinted names.
      files.sort_by! { |f| f.ends_with?(".css") ? 1 : 0 }
      files.each do |file|
        logical = file[(@source_dir.size + 1)..]
        content = File.read(file)
        if logical.ends_with?(".css")
          content = rewrite_css_urls(content, logical, manifest)
          content = minify_css(content) if minify
        end
        digest = Digest::SHA256.hexdigest(content)[0, 8]
        ext = File.extname(logical)
        digested = logical.rchop(ext) + "-" + digest + ext
        write(File.join(@output_dir, digested), content)
        write(File.join(@output_dir, logical), content)
        manifest[logical] = digested
      end
      File.write(File.join(@output_dir, "manifest.json"), manifest.to_pretty_json)
      @manifest = manifest
      @manifest_loaded = true
      manifest
    end

    private def write(path : String, content : String) : Nil
      Dir.mkdir_p(File.dirname(path))
      File.write(path, content)
      if path.matches?(/\.(css|js|svg|json|txt|html|map|xml)$/) && content.bytesize > 1024
        File.open(path + ".gz", "w") do |f|
          Compress::Gzip::Writer.open(f, level: Compress::Gzip::BEST_COMPRESSION) { |gz| gz << content }
        end
      end
    end

    private def rewrite_css_urls(css : String, logical : String, manifest : Hash(String, String)) : String
      dir = File.dirname(logical)
      css.gsub(/url\(\s*['"]?([^'")]+)['"]?\s*\)/) do |match, m|
        ref = m[1]
        next match if ref.starts_with?("data:") || ref.starts_with?("http") || ref.starts_with?("/") || ref.starts_with?("#")
        resolved = Path.posix(dir == "." ? ref : "#{dir}/#{ref}").normalize.to_s
        if digested = manifest[resolved]?
          %(url("#{@prefix}/#{digested}"))
        else
          match
        end
      end
    end

    private def minify_css(css : String) : String
      css.gsub(/\/\*.*?\*\//m, "").gsub(/\s+/, " ").gsub(/\s*([{};:,>])\s*/, "\\1").gsub(";}", "}").strip
    end
  end

  # Serves files from a directory with ETag, caching and precompressed variants.
  class StaticMiddleware < Middleware
    def initialize(@root : String = "public", @url_prefix : String = "/", @fallthrough : Bool = true)
    end

    def call(ctx : Context, chain : Chain) : Nil
      unless ctx.get? && ctx.path.starts_with?(@url_prefix)
        return chain.next(ctx)
      end
      relative = URI.decode(ctx.path[@url_prefix.rchop('/').size..])
      if relative.includes?("..") || relative.includes?('\0')
        return chain.next(ctx)
      end
      file = File.join(@root, relative)
      file = File.join(file, "index.html") if Dir.exists?(file)
      if File.file?(file)
        serve(ctx, file)
      else
        chain.next(ctx)
      end
    end

    def serve(ctx : Context, file : String) : Nil
      info = File.info(file)
      etag = %(W/"#{info.modification_time.to_unix_ms.to_s(36)}-#{info.size.to_s(36)}")
      headers = ctx.response.headers
      headers["ETag"] = etag
      headers["Last-Modified"] = HTTP.format_time(info.modification_time)
      fingerprinted = File.basename(file).matches?(/-[0-9a-f]{8,}\.\w+$/)
      headers["Cache-Control"] = fingerprinted ? "public, max-age=31536000, immutable" : "public, max-age=0, must-revalidate"
      if ctx.header("If-None-Match") == etag
        ctx.head(304)
        return
      end
      content_type = MIME.from_filename(file, "application/octet-stream")
      content_type += "; charset=utf-8" if content_type.starts_with?("text/") || content_type.includes?("javascript")
      gz = file + ".gz"
      if (ctx.header("Accept-Encoding") || "").includes?("gzip") && File.exists?(gz)
        headers["Content-Encoding"] = "gzip"
        headers["Vary"] = "Accept-Encoding"
        ctx.send_file(gz, File.basename(file), "inline", content_type)
      else
        ctx.send_file(file, File.basename(file), "inline", content_type)
      end
    end
  end

  # Framework assets compiled into the binary (`/_silth/*`).
  class InternalAssetsMiddleware < Middleware
    FILES = {
      "/_silth/silth.js"      => {"application/javascript; charset=utf-8", {{ read_file(__DIR__ + "/assets/silth.js") }}},
      "/_silth/livereload.js" => {"application/javascript; charset=utf-8", {{ read_file(__DIR__ + "/assets/livereload.js") }}},
      "/_silth/internal.css"  => {"text/css; charset=utf-8", Brand::INTERNAL_CSS},
      "/_silth/logo.svg"      => {"image/svg+xml", Brand::LOGO_SVG},
    }

    def call(ctx : Context, chain : Chain) : Nil
      if ctx.get? && (asset = FILES[ctx.path]?)
        ctx.response.headers["Cache-Control"] = Silth.env == "development" ? "no-cache" : "public, max-age=3600"
        ctx.send_body(asset[1], asset[0])
      else
        chain.next(ctx)
      end
    end
  end
end

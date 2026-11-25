module Silth::Live
  # A file chosen in a live component. The browser uploads it to a temporary file
  # first (`POST /_silth/live/upload`), then hands the component a signed token, so
  # the component state never carries the bytes.
  #
  # ```
  # class AvatarForm < Silth::LiveComponent
  #   prop avatar : Silth::Live::Upload?, writable: true                                   # <input type="file" silth-model="avatar">
  #   prop photos : Array(Silth::Live::Upload) = [] of Silth::Live::Upload, writable: true # <input type="file" multiple>
  #
  #   action def save
  #     if file = avatar
  #       current_user.update!(avatar_path: file.store("avatars"))
  #       @avatar = nil
  #     end
  #   end
  # end
  # ```
  #
  # ```erb
  # <% if (file = avatar) && file.image? %><img src="<%= file.preview_url %>"><% end %>
  # ```
  class Upload
    PATH    = "/_silth/live/upload"
    PURPOSE = "live-upload"

    class Error < Silth::Error; end

    getter token : String
    getter filename : String
    getter content_type : String
    getter size : Int64
    getter path : String

    def initialize(@token : String, @path : String, @filename : String, @content_type : String, @size : Int64)
    end

    # Copies an uploaded file into the temporary upload directory.
    def self.create(file : UploadedFile) : Upload
      if file.size > max_size
        raise Error.new("#{file.filename} is larger than #{max_size // 1_048_576} MB")
      end
      Dir.mkdir_p(directory)
      path = File.join(directory, Crypto.hex_token(16) + File.extname(file.filename).downcase)
      FileUtils.cp(file.path, path)
      payload = {p: File.expand_path(path), f: file.filename, t: file.content_type, s: file.size}.to_json
      token = Silth.verifier(PURPOSE).generate(payload, expires_in: max_age)
      prune
      new(token, File.expand_path(path), file.filename, file.content_type, file.size)
    end

    # Reads an upload back from its token (raises `Forbidden` when it was tampered with).
    def self.from_token(token : String) : Upload
      payload = Silth.verifier(PURPOSE).verify?(token) || raise Forbidden.new("Invalid or expired upload")
      data = JSON.parse(payload)
      new(token, data["p"].as_s, data["f"].as_s, data["t"].as_s, data["s"].as_i64)
    end

    # Component state carries the token only.
    def self.new(pull : JSON::PullParser) : Upload
      from_token(pull.read_string)
    end

    def to_json(json : JSON::Builder) : Nil
      json.string(@token)
    end

    def image? : Bool
      @content_type.starts_with?("image/")
    end

    def extension : String
      File.extname(@filename).lchop('.').downcase
    end

    def exists? : Bool
      File.exists?(@path)
    end

    def read : Bytes
      raise Error.new("#{@filename} is no longer available (stored or expired)") unless exists?
      File.read(@path).to_slice
    end

    # URL of the temporary file, for previews (`<img src=…>`).
    def preview_url : String
      "#{PATH}?t=#{URI.encode_www_form(@token)}"
    end

    # Moves the file to a storage disk and returns its path there.
    def store(directory : String = "", disk : String? = nil, name : String? = nil) : String
      filename = name || "#{Crypto.uuid7}#{File.extname(@filename).downcase}"
      target = directory.empty? ? filename : "#{directory.rstrip('/')}/#{filename}"
      Storage.disk(disk).put(target, read, @content_type)
      delete
      target
    end

    def delete : Nil
      File.delete?(@path)
    end

    def self.directory : String
      Silth.config.string("live.upload_dir", "tmp/live_uploads")
    end

    def self.max_size : Int64
      Silth.config.int("live.upload_max_size", 10 * 1_048_576).to_i64
    end

    def self.max_age : Time::Span
      Silth.config.int("live.upload_max_age", 86_400).seconds
    end

    @@pruned_at = Time.unix(0)

    # Removes temporary uploads older than `max_age` (at most every ten minutes).
    def self.prune(force : Bool = false) : Nil
      return unless force || Time.utc - @@pruned_at > 10.minutes
      @@pruned_at = Time.utc
      return unless Dir.exists?(directory)
      limit = Time.utc - max_age
      Dir.each_child(directory) do |name|
        file = File.join(directory, name)
        File.delete?(file) if File.info?(file).try(&.modification_time.< limit)
      end
    end

    # Serves POST (store a file, answer `{"token": …}`) and GET (preview) requests.
    def self.handle(ctx : Context) : Nil
      if ctx.request.method == "GET"
        serve_preview(ctx)
      else
        receive(ctx)
      end
    end

    private def self.receive(ctx : Context) : Nil
      if (length = ctx.header("Content-Length").try(&.to_i64?)) && length > max_size + 64 * 1024
        return ctx.json({error: "File too large"}, 413)
      end
      file = ctx.params.file("file") || return ctx.json({error: "Missing file"}, 422)
      upload = create(file)
      ctx.json({token: upload.token, filename: upload.filename, size: upload.size, image: upload.image?})
    rescue ex : Error
      ctx.json({error: ex.message}, 413)
    end

    private def self.serve_preview(ctx : Context) : Nil
      upload = from_token(ctx.params["t"])
      raise NotFound.new("Upload expired") unless upload.exists?
      ctx.response.headers["X-Content-Type-Options"] = "nosniff"
      ctx.response.headers["Cache-Control"] = "private, max-age=300"
      unless upload.image?
        ctx.response.headers["Content-Disposition"] = %(attachment; filename="#{upload.filename.gsub('"', "")}")
      end
      ctx.response.content_type = upload.image? && upload.content_type != "image/svg+xml" ? upload.content_type : "application/octet-stream"
      ctx.response.write(upload.read)
    end
  end
end

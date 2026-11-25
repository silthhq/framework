require "socket"
require "openssl"

module Silth
  # Email messages rendered with Silth templates.
  #
  # ```
  # class WelcomeMail < Silth::Mail
  #   def initialize(@user : User)
  #   end
  #
  #   def build : Nil
  #     to @user.email, @user.name
  #     subject "Welcome to the abyss"
  #     html render_to_string("mails/welcome", layout: "layouts/mail", user: @user)
  #     text "Welcome #{@user.name}!"
  #   end
  # end
  #
  # WelcomeMail.new(user).deliver        # now
  # WelcomeMail.new(user).deliver_later  # in a fiber / the queue
  # ```
  #
  # Markdown mails get a themed HTML layout and a text version for free:
  #
  # ```
  # def build : Nil
  #   to @user.email
  #   subject "Confirm your address"
  #   markdown "mails/confirm", user: @user, url: confirm_url   # src/views/mails/confirm.md.ecr
  # end
  # ```
  abstract class Mail
    include View::Rendering
    include View::Helpers

    record Address, email : String, name : String? = nil do
      def to_s(io : IO) : Nil
        if n = name
          io << '"' << n.gsub('"', "'") << "\" <" << email << '>'
        else
          io << email
        end
      end
    end

    record Attachment, filename : String, content : Bytes, content_type : String, inline : Bool = false

    getter to_list = [] of Address
    getter cc_list = [] of Address
    getter bcc_list = [] of Address
    getter from_address : Address?
    getter reply_to_address : Address?
    getter subject_line = ""
    getter html_body : String?
    getter text_body : String?
    getter attachments = [] of Attachment
    getter headers = {} of String => String
    getter? built = false

    abstract def build : Nil

    def to(email : String, name : String? = nil) : Nil
      @to_list << Address.new(email, name)
    end

    def cc(email : String, name : String? = nil) : Nil
      @cc_list << Address.new(email, name)
    end

    def bcc(email : String, name : String? = nil) : Nil
      @bcc_list << Address.new(email, name)
    end

    def from(email : String, name : String? = nil) : Nil
      @from_address = Address.new(email, name)
    end

    def reply_to(email : String, name : String? = nil) : Nil
      @reply_to_address = Address.new(email, name)
    end

    def subject(text : String) : Nil
      @subject_line = text
    end

    def html(body : String) : Nil
      @html_body = body
    end

    def text(body : String) : Nil
      @text_body = body
    end

    # Renders `src/views/<template>.md.ecr` as a Markdown mail: themed HTML body,
    # text body, `button`/`panel` helpers. Values from `<%= %>` are shown as is.
    macro markdown(template, **locals)
      {% path = template.ends_with?(".ecr") ? template : "src/views/" + template + ".md.ecr" %}
      begin
        {% for key, value in locals %}
          %local{key} = {{value}}
        {% end %}
        {% for key, value in locals %}
          {{key.id}} = %local{key}
        {% end %}
        %previous = @view_io
        %buffer = ::Silth::Mail::MarkdownBuffer.new
        begin
          @view_io = %buffer
          {{ run("./view/ecr_process", path, "@view_io") }}
        ensure
          @view_io = %previous
        end
        markdown_body(%buffer.to_s)
      end
    end

    def header(name : String, value : String) : Nil
      @headers[name] = value
    end

    def attach(path : String, filename : String? = nil, content_type : String? = nil) : Nil
      @attachments << Attachment.new(filename || File.basename(path), File.read(path).to_slice, content_type || MIME.from_filename(path, "application/octet-stream"))
    end

    def attach_data(data : Bytes | String, filename : String, content_type : String = "application/octet-stream") : Nil
      @attachments << Attachment.new(filename, data.to_slice, content_type)
    end

    # :nodoc:
    def prepare! : self
      return self if @built
      build
      @built = true
      @from_address ||= Address.new(Silth.config.string("mail.from.address", "hello@example.com"), Silth.config.string?("mail.from.name"))
      self
    end

    def recipients : Array(String)
      (@to_list + @cc_list + @bcc_list).map(&.email)
    end

    def deliver : Nil
      prepare!
      Mailer.deliver(self)
    end

    def deliver_later : Nil
      prepare!
      mail = self
      if Silth.test?
        Mailer.deliver(mail)
      else
        Concurrency.defer("mail") { Mailer.deliver(mail) }
      end
    end

    # RFC 5322 / MIME rendering.
    def to_mime : String
      prepare!
      boundary = "silth-#{Crypto.hex_token(12)}"
      alt = "silth-alt-#{Crypto.hex_token(12)}"
      domain = (@from_address.try(&.email) || "localhost").partition('@')[2].presence || "localhost"
      String.build do |io|
        io << "From: " << @from_address << "\r\n"
        io << "To: " << @to_list.join(", ") << "\r\n" unless @to_list.empty?
        io << "Cc: " << @cc_list.join(", ") << "\r\n" unless @cc_list.empty?
        io << "Reply-To: " << @reply_to_address << "\r\n" if @reply_to_address
        io << "Subject: " << Mailer.encode_header(@subject_line) << "\r\n"
        io << "Date: " << Time.utc.to_rfc2822 << "\r\n"
        io << "Message-ID: <" << Crypto.uuid7 << '@' << domain << ">\r\n"
        io << "MIME-Version: 1.0\r\n"
        @headers.each { |k, v| io << k << ": " << v << "\r\n" }
        io << "Content-Type: multipart/mixed; boundary=\"" << boundary << "\"\r\n\r\n"
        io << "--" << boundary << "\r\n"
        io << "Content-Type: multipart/alternative; boundary=\"" << alt << "\"\r\n\r\n"
        text = @text_body || @html_body.try { |h| Mailer.html_to_text(h) } || ""
        io << "--" << alt << "\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Transfer-Encoding: base64\r\n\r\n"
        io << Mailer.wrap_base64(text.to_slice) << "\r\n"
        if html = @html_body
          io << "--" << alt << "\r\nContent-Type: text/html; charset=utf-8\r\nContent-Transfer-Encoding: base64\r\n\r\n"
          io << Mailer.wrap_base64(html.to_slice) << "\r\n"
        end
        io << "--" << alt << "--\r\n"
        @attachments.each do |a|
          io << "--" << boundary << "\r\n"
          io << "Content-Type: " << a.content_type << "; name=\"" << a.filename << "\"\r\n"
          io << "Content-Disposition: " << (a.inline ? "inline" : "attachment") << "; filename=\"" << a.filename << "\"\r\n"
          io << "Content-Transfer-Encoding: base64\r\n\r\n"
          io << Mailer.wrap_base64(a.content) << "\r\n"
        end
        io << "--" << boundary << "--\r\n"
      end
    end
  end

  module Mailer
    Log = ::Log.for("silth.mail")

    abstract class Transport
      abstract def send(mail : Mail) : Nil
    end

    # Keeps messages in memory (tests: `Silth::Mailer.sent`).
    class MemoryTransport < Transport
      getter messages = [] of Mail

      def send(mail : Mail) : Nil
        @messages << mail
      end
    end

    class LogTransport < Transport
      def send(mail : Mail) : Nil
        Log.info { "Mail to #{mail.recipients.join(", ")}: #{mail.subject_line}" }
        Log.debug { mail.to_mime }
      end
    end

    # Writes `.eml` files (open them in any mail client) to `tmp/mails`.
    class FileTransport < Transport
      def initialize(@dir : String = "tmp/mails")
      end

      def send(mail : Mail) : Nil
        Dir.mkdir_p(@dir)
        File.write(File.join(@dir, "#{Time.utc.to_s("%Y%m%d-%H%M%S")}-#{Crypto.hex_token(3)}.eml"), mail.to_mime)
      end
    end

    # SMTP with STARTTLS / implicit TLS and AUTH PLAIN/LOGIN.
    class SMTPTransport < Transport
      def initialize(@host : String, @port : Int32 = 587, @username : String? = nil, @password : String? = nil,
                     @tls : String = "starttls", @helo : String = "localhost", @verify : Bool = true)
      end

      def send(mail : Mail) : Nil
        socket = TCPSocket.new(@host, @port, connect_timeout: 10.seconds)
        socket.read_timeout = 30.seconds
        io = @tls == "tls" ? wrap_tls(socket) : socket.as(IO)
        expect(io, 220)
        capabilities = ehlo(io)
        if @tls == "starttls" && capabilities.any?(&.upcase.starts_with?("STARTTLS"))
          command(io, "STARTTLS", 220)
          io = wrap_tls(socket)
          capabilities = ehlo(io)
        end
        if (user = @username) && (pass = @password)
          auth = capabilities.find(&.upcase.starts_with?("AUTH")) || ""
          if auth.upcase.includes?("PLAIN")
            command(io, "AUTH PLAIN #{Base64.strict_encode("\0#{user}\0#{pass}")}", 235)
          else
            command(io, "AUTH LOGIN", 334)
            command(io, Base64.strict_encode(user), 334)
            command(io, Base64.strict_encode(pass), 235)
          end
        end
        command(io, "MAIL FROM:<#{mail.from_address.try(&.email)}>", 250)
        mail.recipients.each { |r| command(io, "RCPT TO:<#{r}>", 250, 251) }
        command(io, "DATA", 354)
        body = mail.to_mime.gsub(/^\./m, "..")
        io << body
        io << "\r\n" unless body.ends_with?("\r\n")
        command(io, ".", 250)
        command(io, "QUIT", 221) rescue nil
      ensure
        socket.try &.close rescue nil
      end

      private def wrap_tls(socket : TCPSocket) : IO
        ctx = OpenSSL::SSL::Context::Client.new
        ctx.verify_mode = OpenSSL::SSL::VerifyMode::NONE unless @verify
        OpenSSL::SSL::Socket::Client.new(socket, ctx, sync_close: false, hostname: @host)
      end

      private def ehlo(io : IO) : Array(String)
        io << "EHLO " << @helo << "\r\n"
        io.flush
        read_response(io, 250)[1]
      end

      private def command(io : IO, line : String, *expected : Int32) : Nil
        io << line << "\r\n"
        io.flush
        read_response(io, *expected)
      end

      private def expect(io : IO, code : Int32) : Nil
        read_response(io, code)
      end

      private def read_response(io : IO, *expected : Int32) : {Int32, Array(String)}
        lines = [] of String
        code = 0
        loop do
          line = io.gets || raise IO::EOFError.new("SMTP connection closed")
          code = line[0, 3].to_i
          lines << (line[4..]? || "")
          break unless line[3]? == '-'
        end
        raise Silth::Error.new("SMTP error #{code}: #{lines.join(" ")}") unless expected.includes?(code)
        {code, lines}
      end
    end

    @@transport : Transport?
    @@memory = MemoryTransport.new

    def self.transport : Transport
      @@transport ||= begin
        config = Silth.config
        driver = config.string("mail.driver", Silth.test? ? "memory" : (Silth.development? ? "file" : "smtp"))
        case driver
        when "memory" then @@memory
        when "log"    then LogTransport.new
        when "file"   then FileTransport.new(config.string("mail.path", "tmp/mails"))
        when "smtp"
          SMTPTransport.new(config.string("mail.host", "localhost"), config.int("mail.port", 587),
            config.string?("mail.username"), config.string?("mail.password"), config.string("mail.encryption", "starttls"),
            config.string("mail.helo", "localhost"), config.bool("mail.verify_tls", true))
        else raise ConfigError.new("Unknown mail driver '#{driver}'")
        end
      end
    end

    def self.transport=(transport : Transport) : Nil
      @@transport = transport
    end

    def self.deliver(mail : Mail) : Nil
      mail.prepare!
      transport.send(mail)
      Instrument.publish(Instrument::Mail.new(mail.recipients.join(", "), mail.subject_line, mail.class.name))
    end

    # Messages captured by the memory transport (tests).
    def self.sent : Array(Mail)
      @@memory.messages
    end

    def self.fake : Nil
      @@memory.messages.clear
      @@transport = @@memory
    end

    def self.encode_header(value : String) : String
      value.ascii_only? ? value : "=?UTF-8?B?#{Base64.strict_encode(value)}?="
    end

    def self.wrap_base64(data : Bytes) : String
      Base64.strict_encode(data).scan(/.{1,76}/).map(&.[0]).join("\r\n")
    end

    def self.html_to_text(html : String) : String
      html.gsub(/<(br|\/p|\/div|\/h\d|\/li)[^>]*>/i, "\n").gsub(/<[^>]+>/, "").gsub(/\n{3,}/, "\n\n").strip
    end
  end
end

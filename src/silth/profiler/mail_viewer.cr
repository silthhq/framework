module Silth
  module Profiler
    # The Mails section: previews (`Silth::MailPreview`), mails captured by the
    # memory transport and `.eml` files written by the file transport.
    #
    # ```text
    # /_silth/profiler/mails                               list
    # /_silth/profiler/mails/preview/<Preview>/<method>    one preview (…/html, …/eml)
    # /_silth/profiler/mails/sent/<n>                      a captured mail (…/html, …/eml)
    # /_silth/profiler/mails/file/<name>.eml               a file written by the file transport
    # ```
    module MailViewer
      PREFIX = "#{Middleware::PREFIX}/mails"

      def self.index : String
        previews = MailPreview.all.flat_map do |(klass, methods)|
          methods.map { |m| %(<tr><td><a class="row-link mono" href="#{PREFIX}/preview/#{klass}/#{m}">#{HTML.escape(klass)}##{HTML.escape(m)}</a></td></tr>) }
        end.join
        sent = Mailer.sent.each_with_index.to_a.reverse.first(50).map do |(m, i)|
          %(<tr><td><a class="row-link" href="#{PREFIX}/sent/#{i}">#{HTML.escape(m.subject_line)}</a></td><td class="s-muted">#{HTML.escape(m.recipients.join(", "))}</td><td class="s-muted mono">#{m.class.name}</td></tr>)
        end.join
        files = eml_files.first(50).map { |f| %(<tr><td><a class="row-link mono" href="#{PREFIX}/file/#{File.basename(f)}">#{HTML.escape(File.basename(f))}</a></td><td class="num s-muted">#{File.size(f)} bytes</td></tr>) }.join
        <<-HTML
          <div class="s-card"><h3>Previews</h3><table class="s-table"><tbody>#{previews.empty? ? %(<tr><td class="s-muted">No preview yet. Add a <code>Silth::MailPreview</code> subclass in src/mails/previews.</td></tr>) : previews}</tbody></table></div>
          <div class="s-card"><h3>Captured by the memory transport</h3><table class="s-table"><tbody>#{sent.empty? ? %(<tr><td class="s-muted">None.</td></tr>) : sent}</tbody></table></div>
          <div class="s-card"><h3>tmp/mails (file transport)</h3><table class="s-table"><tbody>#{files.empty? ? %(<tr><td class="s-muted">None.</td></tr>) : files}</tbody></table></div>
          HTML
      end

      def self.show(rest : String) : String
        mail, base = find(rest) || raise NotFound.new("No such mail")
        headers = {"Subject" => mail.subject_line, "From" => mail.from_address.to_s, "To" => mail.to_list.join(", "),
                   "Cc" => mail.cc_list.join(", "), "Reply-To" => mail.reply_to_address.to_s}.reject { |_, v| v.empty? }
        attachments = mail.attachments.map { |a| %(<span class="s-badge">#{HTML.escape(a.filename)} · #{a.content.size} bytes</span>) }.join(" ")
        html = mail.html_body ? %(<iframe sandbox src="#{base}/html" title="HTML body" style="width:100%;height:640px;border:1px solid var(--rim);border-radius:var(--radius);background:#fff"></iframe>) : %(<p class="s-muted">No HTML body.</p>)
        text = mail.text_body || mail.html_body.try { |h| Mailer.html_to_text(h) } || ""
        <<-HTML
          <div class="s-card"><h2 class="s-title" style="font-size:18px;margin-top:0">#{HTML.escape(mail.subject_line)}</h2>
          <table class="s-table s-kv">#{headers.map { |k, v| %(<tr><td>#{k}</td><td>#{HTML.escape(v)}</td></tr>) }.join}</table>
          #{attachments.empty? ? "" : %(<p>#{attachments}</p>)}<p><a class="s-btn" href="#{base}/eml">Download .eml</a></p></div>
          <div class="s-card"><h3>HTML</h3>#{html}</div>
          <div class="s-card"><h3>Text</h3><pre class="mono" style="white-space:pre-wrap;margin:0">#{HTML.escape(text)}</pre></div>
          HTML
      end

      # `…/html`, `…/eml` and `.eml` files are served as is, outside the layout.
      def self.raw?(rest : String) : Bool
        rest.starts_with?("mails/") && (rest.ends_with?("/html") || rest.ends_with?("/eml") || rest.starts_with?("mails/file/"))
      end

      def self.serve_raw(ctx : Context, rest : String) : Nil
        if name = rest.lchop?("mails/file/")
          path = eml_files.find { |f| File.basename(f) == name } || raise NotFound.new("No such file")
          return ctx.text(File.read(path))
        end
        mail, _ = find(rest.rchop("/html").rchop("/eml")) || raise NotFound.new("No such mail")
        if rest.ends_with?("/eml")
          ctx.response.headers["Content-Disposition"] = %(attachment; filename="#{mail.class.name.underscore.gsub("::", "_")}.eml")
          return ctx.text(mail.to_mime)
        end
        # The mail's own inline styles, nothing else (the page is also sandboxed).
        ctx.response.headers["Content-Security-Policy"] = "default-src 'none'; img-src * data:; style-src 'unsafe-inline'; font-src * data:"
        ctx.html(mail.html_body || "")
      end

      def self.count : Int32
        MailPreview.all.sum { |(_, methods)| methods.size } + Mailer.sent.size
      end

      # The mail designated by `mails/preview/<class>/<method>` or `mails/sent/<n>`, and its URL.
      private def self.find(rest : String) : {Mail, String}?
        parts = rest.split('/')
        mail = case parts[1]?
               when "preview" then MailPreview.render(parts[2]? || "", parts[3]? || "")
               when "sent"    then parts[2]?.try(&.to_i?).try { |i| Mailer.sent[i]? }
               end
        mail.try { |m| {m, "#{Middleware::PREFIX}/#{parts[0, parts[1]? == "preview" ? 4 : 3].join('/')}"} }
      end

      private def self.eml_files : Array(String)
        Dir.exists?("tmp/mails") ? Dir.glob("tmp/mails/*.eml").sort.reverse : [] of String
      end
    end
  end
end

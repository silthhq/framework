module Silth
  abstract class Mail
    # Buffer of Markdown mail templates: `<%= value %>` is written so that the
    # Markdown renderer neither formats it as HTML nor escapes it twice.
    class MarkdownBuffer < IO::Memory
      AMP = '\u{E004}'
      LT  = '\u{E002}'
      GT  = '\u{E003}'

      # Text as it must appear in the rendered mail.
      def write_literal(text : String) : Nil
        text.each_char do |c|
          case c
          when '&' then self << AMP
          when '<' then self << LT
          when '>' then self << GT
          else          self << c
          end
        end
      end

      # Turns the placeholders back into HTML entities, after Markdown rendering.
      def self.restore(html : String) : String
        html.gsub(AMP, "&amp;").gsub(LT, "&lt;").gsub(GT, "&gt;")
      end
    end

    # Sets the HTML body (themed layout, inline styles) and the text body from
    # Markdown source; `markdown "mails/welcome"` renders `welcome.md.ecr` with it.
    def markdown_body(source : String) : Nil
      html = Markdown.to_html(source).gsub(/<a class="anchor"[^>]*>#<\/a>/, "")
      html = MarkdownBuffer.restore(html)
      @html_body = MailTheme.wrap(MailTheme.inline_styles(html), @subject_line)
      @text_body = MailTheme.to_text(html)
    end

    # A call-to-action button, on its own line in a Markdown mail:
    # `<%= button "Confirm my address", confirm_url %>`.
    def button(label : String, url : String) : SafeHTML
      color = MailTheme.color
      SafeHTML.new(%(<table role="presentation" cellpadding="0" cellspacing="0" style="margin:24px 0"><tr><td style="border-radius:6px;background:#{color}">) +
                   %(<a href="#{HTML.escape(url)}" style="display:inline-block;padding:12px 22px;color:#ffffff;font-weight:600;text-decoration:none;border-radius:6px">#{HTML.escape(label)}</a>) +
                   %(</td></tr></table>))
    end

    # A highlighted block: `<%= panel "Your code: 123-456" %>`.
    def panel(text : String) : SafeHTML
      SafeHTML.new(%(<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="margin:16px 0"><tr>) +
                   %(<td style="background:#f4f4f7;border-left:4px solid #{MailTheme.color};padding:14px 18px;color:#33334d">#{HTML.escape(text)}</td></tr></table>))
    end
  end

  module View
    # :nodoc: `<%= %>` in Markdown mail templates.
    def self.escape(io : Mail::MarkdownBuffer, value : SafeHTML) : Nil
      io << value.value
    end

    # :nodoc:
    def self.escape(io : Mail::MarkdownBuffer, value : Nil) : Nil
    end

    # :nodoc:
    def self.escape(io : Mail::MarkdownBuffer, value) : Nil
      io.write_literal(value.to_s)
    end
  end

  # Layout and inline styles of Markdown mails (mail clients ignore `<style>`).
  # Settings: `mail.markdown.color` (buttons, links), `mail.markdown.footer`.
  module MailTheme
    STYLES = {
      "h1"         => "margin:0 0 16px;font-size:22px;line-height:1.3;color:#14141f",
      "h2"         => "margin:24px 0 12px;font-size:18px;color:#14141f",
      "h3"         => "margin:20px 0 10px;font-size:16px;color:#14141f",
      "p"          => "margin:0 0 16px;line-height:1.6",
      "ul"         => "margin:0 0 16px;padding-left:22px;line-height:1.6",
      "ol"         => "margin:0 0 16px;padding-left:22px;line-height:1.6",
      "blockquote" => "margin:0 0 16px;padding:4px 16px;border-left:3px solid #d8d8e6;color:#5c5c77",
      "pre"        => "margin:0 0 16px;padding:12px 14px;background:#f4f4f7;border-radius:6px;overflow:auto;font-size:13px",
      "code"       => "font-family:SFMono-Regular,Menlo,Consolas,monospace;font-size:13px;background:#f4f4f7;padding:1px 4px;border-radius:4px",
      "table"      => "width:100%;border-collapse:collapse;margin:0 0 16px",
      "th"         => "text-align:left;padding:8px;border-bottom:2px solid #e4e4ee",
      "td"         => "padding:8px;border-bottom:1px solid #eeeef4",
      "hr"         => "border:0;border-top:1px solid #e4e4ee;margin:24px 0",
    }

    def self.color : String
      Silth.config.string("mail.markdown.color", "#5b4fd6")
    end

    # Adds `style` attributes to the tags Markdown produced (not to helpers' HTML).
    def self.inline_styles(html : String) : String
      styled = html.gsub(/<(h1|h2|h3|p|ul|ol|blockquote|pre|code|table|th|td|hr)(\s[^>]*)?>/) do |tag, m|
        attrs = m[2]? || ""
        attrs.includes?("style=") ? tag : "<#{m[1]}#{attrs} style=\"#{STYLES[m[1]]}\">"
      end
      styled.gsub(/<a (?![^>]*style=)([^>]*)>/) { |_, m| %(<a #{m[1]} style="color:#{color}">) }
    end

    # The full document around the rendered Markdown.
    def self.wrap(content : String, title : String) : String
      app = Silth.config.string("app.name", "Silth")
      footer = Silth.config.string("mail.markdown.footer", "© #{Time.utc.year} #{app}")
      <<-HTML
        <!doctype html>
        <html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>#{HTML.escape(title)}</title></head>
        <body style="margin:0;padding:0;background:#f2f2f7;font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,Helvetica,Arial,sans-serif;color:#33334d;font-size:15px">
        <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background:#f2f2f7"><tr><td align="center" style="padding:32px 12px">
        <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="max-width:600px">
        <tr><td style="padding:0 8px 16px;font-size:16px;font-weight:700;color:#14141f">#{HTML.escape(app)}</td></tr>
        <tr><td style="background:#ffffff;border-radius:10px;padding:32px">#{content}</td></tr>
        <tr><td style="padding:16px 8px;font-size:12px;color:#8a8aa3;text-align:center">#{HTML.escape(footer)}</td></tr>
        </table></td></tr></table></body></html>
        HTML
    end

    # Plain text version: links become "label (url)", tags go away.
    def self.to_text(html : String) : String
      text = html.gsub(/<a [^>]*href="([^"]*)"[^>]*>(.*?)<\/a>/m) do |_, m|
        label = m[2].gsub(/<[^>]+>/, "")
        label == m[1] ? label : "#{label} (#{m[1]})"
      end
      text = text.gsub(/<li[^>]*>/, "- ").gsub(/<\/(td|th)>/, " ")
      HTML.unescape(Mailer.html_to_text(text)).lines.map(&.rstrip).join('\n')
    end
  end

  # Mail previews, listed in the profiler (`/_silth/profiler/mails`): each public
  # method without arguments returns a mail built with sample data. Previews are
  # rendered, never sent.
  #
  # ```
  # # src/mails/previews/welcome_mail_preview.cr
  # class WelcomeMailPreview < Silth::MailPreview
  #   def welcome : Silth::Mail
  #     WelcomeMail.new(User.first? || User.new(name: "Ada", email: "ada@example.com"))
  #   end
  # end
  # ```
  abstract class MailPreview
    # `{preview class, method names}` for every preview compiled in.
    def self.all : Array({String, Array(String)})
      {% begin %}
        [
          {% for t in @type.all_subclasses.reject(&.abstract?) %}
            { {{t.name.stringify}}, [
              {% for m in t.methods.select { |m| m.visibility == :public && m.args.empty? && !m.name.ends_with?("=") } %}
                {{m.name.stringify}},
              {% end %}
            ] of String },
          {% end %}
        ] of {String, Array(String)}
      {% end %}
    end

    # The mail returned by `preview#method` (nil when unknown).
    def self.render(preview : String, method : String) : Mail?
      {% begin %}
        case {preview, method}
        {% for t in @type.all_subclasses.reject(&.abstract?) %}
          {% for m in t.methods.select { |m| m.visibility == :public && m.args.empty? && !m.name.ends_with?("=") } %}
            when { {{t.name.stringify}}, {{m.name.stringify}} }
              return {{t}}.new.{{m.name}}.as(Mail).prepare!
          {% end %}
        {% end %}
        end
      {% end %}
      nil
    end
  end
end

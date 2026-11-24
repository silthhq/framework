require "html"

module Silth
  # Small, dependency-free Markdown renderer (CommonMark subset + GFM tables,
  # fenced code with syntax highlighting, heading anchors and `> [!NOTE]` callouts).
  #
  # ```
  # Silth::Markdown.to_html("# Hello\n\nSome *text*.")
  # doc = Silth::Markdown.parse(source) # => Document with #html and #headings (TOC)
  # ```
  module Markdown
    record Heading, level : Int32, text : String, id : String

    class Document
      getter html : String
      getter headings : Array(Heading)
      getter front_matter : Hash(String, String)

      def initialize(@html, @headings, @front_matter)
      end

      def title : String?
        @front_matter["title"]? || @headings.find { |h| h.level == 1 }.try(&.text)
      end
    end

    def self.to_html(source : String) : String
      parse(source).html
    end

    def self.parse(source : String) : Document
      front = {} of String => String
      text = source.gsub("\r\n", "\n")
      if text.starts_with?("---\n") && (close = text.index("\n---", 4))
        text[4...close].each_line do |line|
          key, _, value = line.partition(':')
          front[key.strip] = value.strip.strip('"') unless key.strip.empty?
        end
        text = text[(close + 4)..].lchop('\n')
      end
      renderer = Renderer.new(text.lines)
      html = renderer.render
      Document.new(html, renderer.headings, front)
    end

    # :nodoc:
    class Renderer
      getter headings = [] of Heading
      @slugs = Hash(String, Int32).new(0)

      def initialize(@lines : Array(String))
        @pos = 0
      end

      def render : String
        String.build { |io| render_blocks(io, @lines) }
      end

      private def render_blocks(io : IO, lines : Array(String)) : Nil
        i = 0
        while i < lines.size
          line = lines[i]
          stripped = line.strip
          if stripped.empty?
            i += 1
          elsif stripped.starts_with?("```") || stripped.starts_with?("~~~")
            fence = stripped[0, 3]
            lang = stripped[3..].strip
            code = [] of String
            i += 1
            while i < lines.size && !lines[i].strip.starts_with?(fence)
              code << lines[i]
              i += 1
            end
            i += 1
            io << %(<pre class="code" data-lang=") << HTML.escape(lang) << %("><code class="language-) << HTML.escape(lang) << %(">)
            io << Highlighter.highlight(code.join('\n'), lang)
            io << "</code></pre>\n"
          elsif m = stripped.match(/^(\#{1,6})\s+(.*?)\s*#*$/)
            level = m[1].size
            raw = m[2]
            custom_id = raw.match(/\s*\{#([\w\-]+)\}$/)
            raw = raw.sub(/\s*\{#[\w\-]+\}$/, "") if custom_id
            plain = strip_inline(raw)
            id = custom_id ? custom_id[1] : unique_slug(plain)
            @headings << Heading.new(level, plain, id)
            io << "<h" << level << %( id=") << id << %(">) << inline(raw)
            io << %(<a class="anchor" href="#) << id << %(" aria-label="Link to this section">#</a>) if level > 1
            io << "</h" << level << ">\n"
            i += 1
          elsif stripped.matches?(/^(\*\s*){3,}$|^(-\s*){3,}$|^(_\s*){3,}$/)
            io << "<hr>\n"
            i += 1
          elsif stripped.starts_with?('>')
            quote = [] of String
            while i < lines.size && lines[i].strip.starts_with?('>')
              quote << lines[i].strip.lchop('>').lchop(' ')
              i += 1
            end
            if (m = quote.first?.try(&.match(/^\[!(NOTE|TIP|WARNING|IMPORTANT|CAUTION)\]\s*$/i)))
              kind = m[1].downcase
              io << %(<div class="callout callout-) << kind << %("><p class="callout-title">) << kind.capitalize << "</p>"
              render_blocks(io, quote[1..])
              io << "</div>\n"
            else
              io << "<blockquote>"
              render_blocks(io, quote)
              io << "</blockquote>\n"
            end
          elsif stripped.starts_with?('|') && i + 1 < lines.size && lines[i + 1].strip.matches?(/^\|?\s*:?-+:?\s*(\|\s*:?-+:?\s*)*\|?$/)
            i = render_table(io, lines, i)
          elsif list_item?(line)
            i = render_list(io, lines, i)
          elsif stripped.starts_with?('<') && stripped.matches?(/^<\/?(div|section|details|summary|figure|table|aside|nav|p|ul|ol|iframe|video|picture|!--)/i)
            while i < lines.size && !lines[i].strip.empty?
              io << lines[i] << '\n'
              i += 1
            end
          else
            para = [] of String
            while i < lines.size && !lines[i].strip.empty? && !block_start?(lines[i])
              para << lines[i].strip
              i += 1
            end
            io << "<p>" << inline(para.join('\n')) << "</p>\n"
          end
        end
      end

      private def block_start?(line : String) : Bool
        s = line.strip
        s.starts_with?("```") || s.starts_with?('#') && s.matches?(/^\#{1,6}\s/) || s.starts_with?('>') || list_item?(line) || s.starts_with?("~~~")
      end

      private def list_item?(line : String) : Bool
        line.matches?(/^\s*([-*+]|\d+[.)])\s+/)
      end

      private def render_list(io : IO, lines : Array(String), start : Int32) : Int32
        first = lines[start]
        indent = first.size - first.lstrip.size
        ordered = first.lstrip.matches?(/^\d+[.)]/)
        io << (ordered ? "<ol>" : "<ul>")
        i = start
        while i < lines.size
          line = lines[i]
          break if line.strip.empty? && !(i + 1 < lines.size && list_item?(lines[i + 1]) && (lines[i + 1].size - lines[i + 1].lstrip.size) >= indent)
          if line.strip.empty?
            i += 1
            next
          end
          cur_indent = line.size - line.lstrip.size
          break if cur_indent < indent
          if cur_indent > indent && list_item?(line)
            i = render_list(io, lines, i)
            next
          end
          break unless list_item?(line) || cur_indent > indent
          content = line.lstrip.sub(/^([-*+]|\d+[.)])\s+/, "")
          item = [content]
          i += 1
          while i < lines.size && !lines[i].strip.empty? && !list_item?(lines[i]) && (lines[i].size - lines[i].lstrip.size) > indent
            item << lines[i].strip
            i += 1
          end
          text = item.join(' ')
          if task = text.match(/^\[( |x|X)\]\s+(.*)$/)
            io << %(<li class="task"><input type="checkbox" disabled) << (task[1] == " " ? "" : " checked") << "> " << inline(task[2])
          else
            io << "<li>" << inline(text)
          end
          if i < lines.size && list_item?(lines[i]) && (lines[i].size - lines[i].lstrip.size) > indent
            i = render_list(io, lines, i)
          end
          io << "</li>"
        end
        io << (ordered ? "</ol>\n" : "</ul>\n")
        i
      end

      private def render_table(io : IO, lines : Array(String), start : Int32) : Int32
        split = ->(row : String) { row.strip.strip('|').split(/(?<!\\)\|/).map(&.strip.gsub("\\|", "|")) }
        header = split.call(lines[start])
        aligns = split.call(lines[start + 1]).map do |c|
          c.starts_with?(':') && c.ends_with?(':') ? "center" : c.ends_with?(':') ? "right" : c.starts_with?(':') ? "left" : nil
        end
        io << "<div class=\"table-wrap\"><table><thead><tr>"
        header.each_with_index { |h, idx| io << "<th" << (aligns[idx]? ? %( style="text-align:#{aligns[idx]}") : "") << ">" << inline(h) << "</th>" }
        io << "</tr></thead><tbody>"
        i = start + 2
        while i < lines.size && lines[i].strip.starts_with?('|')
          io << "<tr>"
          split.call(lines[i]).each_with_index { |c, idx| io << "<td" << (aligns[idx]? ? %( style="text-align:#{aligns[idx]}") : "") << ">" << inline(c) << "</td>" }
          io << "</tr>"
          i += 1
        end
        io << "</tbody></table></div>\n"
        i
      end

      private def unique_slug(text : String) : String
        base = Inflector.parameterize(text)
        base = "section" if base.empty?
        count = @slugs[base]
        @slugs[base] += 1
        count == 0 ? base : "#{base}-#{count}"
      end

      private def strip_inline(text : String) : String
        text.gsub(/`([^`]+)`/, "\\1").gsub(/\*\*|__|\*|_/, "").gsub(/\[([^\]]+)\]\([^)]+\)/, "\\1")
      end

      # Inline formatting: code, links, images, emphasis, autolinks, line breaks.
      def inline(text : String) : String
        codes = [] of String
        work = text.gsub(/(`+)(.+?)\1/) do |_, m|
          codes << "<code>#{HTML.escape(m[2].strip)}</code>"
          "\u{E000}#{codes.size - 1}\u{E000}"
        end
        html_tags = [] of String
        work = work.gsub(/<\/?[a-zA-Z][^>]*>/) do |tag|
          html_tags << tag
          "\u{E001}#{html_tags.size - 1}\u{E001}"
        end
        work = HTML.escape(work)
        work = work.gsub(/!\[([^\]]*)\]\(([^)\s]+)(?:\s+&quot;([^&]*)&quot;)?\)/) do |_, m|
          %(<img src="#{m[2]}" alt="#{m[1]}"#{m[3]? ? %( title="#{m[3]}") : ""} loading="lazy">)
        end
        work = work.gsub(/\[([^\]]+)\]\(([^)\s]+)(?:\s+&quot;([^&]*)&quot;)?\)/) do |_, m|
          external = m[2].starts_with?("http")
          %(<a href="#{m[2]}"#{external ? %( rel="noopener" target="_blank") : ""}>#{m[1]}</a>)
        end
        work = work.gsub(/(?<![="'>])\bhttps?:\/\/[^\s<]+[^\s<.,;:!?)]/) { |url| %(<a href="#{url}" rel="noopener">#{url}</a>) }
        work = work.gsub(/\*\*(.+?)\*\*|__(.+?)__/) { |_, m| "<strong>#{m[1]? || m[2]}</strong>" }
        work = work.gsub(/(?<![\w*])\*(?!\s)(.+?)(?<!\s)\*(?!\w)|(?<![\w])_(?!\s)(.+?)(?<!\s)_(?![\w])/) { |_, m| "<em>#{m[1]? || m[2]}</em>" }
        work = work.gsub(/~~(.+?)~~/, "<del>\\1</del>")
        work = work.gsub(/ {2,}\n|\\\n/, "<br>\n")
        work = work.gsub(/\x{E001}(\d+)\x{E001}/) { |_, m| html_tags[m[1].to_i] }
        work.gsub(/\x{E000}(\d+)\x{E000}/) { |_, m| codes[m[1].to_i] }
      end
    end

    # Lightweight syntax highlighter producing `<span class="tok-*">` markup.
    module Highlighter
      RULES = {
        "crystal" => [
          {"comment", /\A#[^\n]*/},
          {"string", /\A"(?:\\.|[^"\\])*"|\A'(?:\\.|[^'\\])'/},
          {"symbol", /\A:[a-zA-Z_][\w?!]*/},
          {"ivar", /\A@@?[a-z_]\w*/},
          {"keyword", /\A\b(?:abstract|alias|annotation|as|begin|case|class|def|do|else|elsif|end|ensure|enum|extend|false|for|forall|fun|if|in|include|instance_sizeof|is_a\?|lib|macro|module|next|nil|of|out|private|protected|record|require|rescue|responds_to\?|return|select|self|sizeof|struct|super|then|true|type|typeof|union|unless|until|when|while|with|yield|getter|setter|property|delegate)\b/},
          {"constant", /\A\b[A-Z][\w]*/},
          {"number", /\A\b\d[\d_]*(?:\.\d+)?(?:_?[iuf]\d+)?\b/},
          {"punct", /\A(?:->|=>|\{%|%\}|\{\{|\}\})/},
        ],
        "yaml" => [
          {"comment", /\A#[^\n]*/},
          {"key", /\A[\w@.\-]+(?=:)/},
          {"string", /\A"(?:\\.|[^"\\])*"|\A'[^']*'/},
          {"variable", /\A\$\{[^}]+\}/},
          {"number", /\A\b\d+(?:\.\d+)?\b/},
          {"keyword", /\A\b(?:true|false|null|yes|no)\b/},
        ],
        "bash" => [
          {"comment", /\A#[^\n]*/},
          {"string", /\A"(?:\\.|[^"\\])*"|\A'[^']*'/},
          {"keyword", /\A\b(?:silth|crystal|shards|cd|export|docker|git|curl|brew|npm|sudo)\b/},
          {"variable", /\A\$\w+/},
          {"flag", /\A\s--?[\w\-]+/},
        ],
        "sql" => [
          {"comment", /\A--[^\n]*/},
          {"string", /\A'(?:''|[^'])*'/},
          {"keyword", /\A\b(?i:select|from|where|and|or|not|insert|into|values|update|set|delete|create|table|index|on|join|left|inner|order|by|group|having|limit|offset|returning|as|null|is|in|primary|key|references|default|alter|add|column|drop|exists|if|with|union|distinct)\b/},
          {"number", /\A\b\d+(?:\.\d+)?\b/},
        ],
        "js" => [
          {"comment", /\A\/\/[^\n]*|\A\/\*.*?\*\//m},
          {"string", /\A"(?:\\.|[^"\\])*"|\A'(?:\\.|[^'\\])*'|\A`(?:\\.|[^`\\])*`/},
          {"keyword", /\A\b(?:const|let|var|function|return|if|else|for|while|import|from|export|default|class|new|this|async|await|true|false|null|undefined|of|in)\b/},
          {"number", /\A\b\d+(?:\.\d+)?\b/},
        ],
        "html" => [
          {"comment", /\A<!--.*?-->/m},
          {"ecr", /\A<%.*?%>/m},
          {"tag", /\A<\/?[a-zA-Z][\w\-]*/},
          {"attr", /\A\s[\w\-:@]+(?==)/},
          {"string", /\A"[^"]*"|\A'[^']*'/},
        ],
        "json" => [
          {"key", /\A"(?:\\.|[^"\\])*"(?=\s*:)/},
          {"string", /\A"(?:\\.|[^"\\])*"/},
          {"number", /\A-?\b\d+(?:\.\d+)?(?:[eE][+-]?\d+)?\b/},
          {"keyword", /\A\b(?:true|false|null)\b/},
        ],
      }

      ALIASES = {"cr" => "crystal", "yml" => "yaml", "sh" => "bash", "shell" => "bash", "console" => "bash", "zsh" => "bash",
                 "javascript" => "js", "ts" => "js", "typescript" => "js", "ecr" => "html", "erb" => "html", "xml" => "html", "svg" => "html"}

      def self.highlight(code : String, lang : String) : String
        rules = RULES[ALIASES[lang]? || lang]?
        return HTML.escape(code) unless rules
        String.build do |io|
          pos = 0
          plain = IO::Memory.new
          while pos < code.size
            rest = code[pos..]
            matched = false
            rules.each do |(kind, regex)|
              if (m = regex.match(rest)) && m[0].size > 0
                prev = pos > 0 ? code[pos - 1] : ' '
                next if kind == "keyword" && (prev.alphanumeric? || prev == '_' || prev == '.')
                io << HTML.escape(plain.to_s)
                plain.clear
                io << %(<span class="tok-) << kind << %(">) << HTML.escape(m[0]) << "</span>"
                pos += m[0].size
                matched = true
                break
              end
            end
            unless matched
              plain << code[pos]
              pos += 1
            end
          end
          io << HTML.escape(plain.to_s)
        end
      end
    end
  end
end

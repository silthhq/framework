module Silth
  module Profiler
    # The request timeline: every span of a profile (action, templates,
    # components, queries, HTTP calls, logs…) placed on a shared time axis and
    # nested by containment, plus two synthetic phases around the action.
    #
    # ```text
    # request   GET /posts/1                       ████████████████████  41.2
    #   phase   Before the action                  ███                    5.1
    #     db    SELECT * FROM sessions …            ▌                     0.4
    #   ctrl    PostsController#show                   ██████████████    33.0
    #     db    SELECT * FROM posts …                  ▌                  0.6
    #     view  posts/show.html.ecr                      ██████          12.4
    # ```
    module Timeline
      record Row, span : Span, depth : Int32, end_ms : Float64

      KIND_ORDER = {"request" => 0, "phase" => 1, "controller" => 2, "view" => 3, "component" => 4}
      # Spans that never contain other spans: what happens during them is their sibling.
      LEAVES = {"db", "http"}
      LEGEND     = {"controller" => "Action", "view" => "Templates", "db" => "Database", "http" => "HTTP / jobs / mails", "log" => "Logs", "cache" => "Cache / events"}

      def self.rows(p : Profile) : Array(Row)
        total = p.total_ms
        spans = [Span.new("request", "#{p.method} #{p.url}", p.handler, 0.0, total)]
        if action = p.action_span
          spans << Span.new("phase", "Before the action", "middleware, session, CSRF, auth", 0.0, action.start_ms) if action.start_ms > 0.01
          action_end = action.duration_ms ? action.end_ms : total
          spans << Span.new("phase", "After the action", "response filters and logging", action_end, total - action_end) if total - action_end > 0.01
        end
        spans.concat(p.spans)
        ordered = spans.each_with_index.to_a.sort_by do |(s, i)|
          {s.start_ms.round(3), -(s.instant ? 0.0 : (s.duration_ms || total - s.start_ms)), KIND_ORDER.fetch(s.kind, 9), i}
        end
        stack = [] of Float64
        ordered.map do |(s, _)|
          finish = s.instant ? s.start_ms : (s.duration_ms ? s.end_ms : total)
          while (top = stack.last?) && top < finish - 0.01
            stack.pop
          end
          depth = stack.size
          stack << finish unless s.instant || LEAVES.includes?(s.kind)
          Row.new(s, depth, finish)
        end
      end

      def self.render(p : Profile, limit : Int32 = 600) : String
        rows = self.rows(p)
        total = {p.total_ms, rows.max_of?(&.end_ms) || 0.0, 0.001}.max
        String.build do |io|
          io << %(<div class="s-timeline"><div class="s-tl-head"><div>Span</div><div class="s-tl-scale">)
          5.times do |i|
            align = i == 0 ? "transform:none" : i == 4 ? "transform:translateX(-100%)" : ""
            io << %(<span style="left:#{i * 25}%;#{align}">) << format_ms(total * i / 4) << "</span>"
          end
          io << %(</div><div class="s-tl-ms">ms</div></div>)
          rows.first(limit).each { |row| render_row(io, row, total) }
          io << "</div>"
          io << %(<p class="s-muted">#{rows.size - limit} more rows not shown.</p>) if rows.size > limit
          io << %(<div class="s-legend">)
          LEGEND.each { |kind, name| io << %(<span class="k-#{kind}"><i class="s-tl-swatch"></i>#{name}</span>) }
          io << "</div>"
        end
      end

      private def self.render_row(io : IO, row : Row, total : Float64) : Nil
        s = row.span
        level = case s.level
                when "warn"                     then " warn"
                when "error", "fatal"           then " err"
                else                                 ""
                end
        left = (s.start_ms / total * 100).clamp(0.0, 100.0)
        width = s.instant ? 0.0 : ((row.end_ms - s.start_ms) / total * 100).clamp(0.25, 100.0 - left)
        title = s.detail.empty? ? s.label : "#{s.label}\n#{s.detail}"
        io << %(<div class="s-tl-row k-#{s.kind}#{level}" title="#{HTML.escape(title[0, 600])}">)
        io << %(<div class="s-tl-label" style="padding-left:#{10 + {row.depth, 6}.min * 14}px"><span class="s-tl-kind">#{kind_label(s)}</span><span class="t">#{HTML.escape(s.label[0, 160])}</span></div>)
        io << %(<div class="s-tl-track"><i class="s-tl-bar#{s.instant ? " tick" : ""}" style="left:#{left.round(3)}%;)
        io << %(width:#{width.round(3)}%) unless s.instant
        io << %("></i></div>)
        io << %(<div class="s-tl-ms">#{s.instant ? "+" + format_ms(s.start_ms) : format_ms(row.end_ms - s.start_ms)}</div></div>)
      end

      private def self.kind_label(s : Span) : String
        case s.kind
        when "controller" then "action"
        when "log"        then s.level || "log"
        else                   s.kind
        end
      end

      def self.format_ms(ms : Float64) : String
        ms >= 100 ? ms.round(0).to_i.to_s : ms >= 10 ? ms.round(1).to_s : ms.round(2).to_s
      end
    end
  end
end

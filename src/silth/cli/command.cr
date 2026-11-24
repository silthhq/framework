require "colorize"
require "levenshtein"

module Silth
  # Base class for CLI commands (framework and application).
  #
  # ```
  # class ReportCommand < Silth::Command
  #   command "report:send", "Email the weekly report"
  #
  #   argument recipient : String, "Email address"
  #   option weeks : Int32 = 1, "Number of weeks", short: "w"
  #   option dry_run : Bool = false, "Only print the report"
  #
  #   def run : Nil
  #     info "Building #{weeks} week(s) report for #{recipient}"
  #     success "Sent!"
  #   end
  # end
  # ```
  #
  # Run with `silth report:send ada@example.com --weeks=4 --dry-run`.
  abstract class Command
    annotation Arg
    end

    annotation Opt
    end

    class Error < Silth::Error; end

    property stdout : IO = STDOUT
    property stdin : IO = STDIN
    getter rest = [] of String

    abstract def run : Nil

    def self.command_name : String
      Inflector.dasherize(name.split("::").last.sub(/Command$/, "")).tr("-", ":")
    end

    def self.description : String
      ""
    end

    def self.hidden? : Bool
      false
    end

    macro command(name, description = "", hidden = false)
      def self.command_name : String
        {{name}}
      end

      def self.description : String
        {{description}}
      end

      def self.hidden? : Bool
        {{hidden}}
      end
    end

    macro argument(decl, description = "")
      {% type = decl.type.resolve %}
      {% base = type.union? ? type.union_types.reject(&.nilable?).first : type %}
      @[::Silth::Command::Arg(description: {{description}}, type: {{base}}, required: {{!type.nilable? && decl.value.is_a?(Nop)}})]
      @{{decl.var}} : {{base}}? = {% if decl.value.is_a?(Nop) %}nil{% else %}{{decl.value}}{% end %}

      def {{decl.var}} : {{decl.type}}
        {% if type.nilable? %}@{{decl.var}}{% else %}@{{decl.var}}.not_nil!{% end %}
      end
    end

    macro option(decl, description = "", short = nil)
      {% type = decl.type.resolve %}
      {% base = type.union? ? type.union_types.reject(&.nilable?).first : type %}
      @[::Silth::Command::Opt(description: {{description}}, short: {{short}}, type: {{base}})]
      @{{decl.var}} : {{base}}? = {% if decl.value.is_a?(Nop) %}nil{% else %}{{decl.value}}{% end %}

      def {{decl.var}} : {{decl.type}}
        {% if type.nilable? %}@{{decl.var}}{% else %}@{{decl.var}}.not_nil!{% end %}
      end
    end

    # :nodoc:
    def __parse(args : Array(String)) : Nil
      positional = [] of String
      opts = {} of String => String
      i = 0
      while i < args.size
        arg = args[i]
        if arg == "--"
          positional.concat(args[(i + 1)..])
          break
        elsif arg.starts_with?("--")
          key, eq, value = arg[2..].partition('=')
          if eq.empty?
            if key.starts_with?("no-")
              opts[key[3..].tr("-", "_")] = "false"
            elsif (nxt = args[i + 1]?) && !nxt.starts_with?('-') && !__bool_option?(key.tr("-", "_"))
              opts[key.tr("-", "_")] = nxt
              i += 1
            else
              opts[key.tr("-", "_")] = "true"
            end
          else
            opts[key.tr("-", "_")] = value
          end
        elsif arg.starts_with?('-') && arg.size == 2
          long = __short_to_long(arg[1].to_s)
          raise Error.new("Unknown option #{arg}") unless long
          if !__bool_option?(long) && (nxt = args[i + 1]?)
            opts[long] = nxt
            i += 1
          else
            opts[long] = "true"
          end
        else
          positional << arg
        end
        i += 1
      end
      {% begin %}
        %index = 0
        {% for ivar in @type.instance_vars %}
          {% if ann = ivar.annotation(::Silth::Command::Arg) %}
            if %raw = positional[%index]?
              @{{ivar.name}} = __convert(%raw, {{ann[:type]}})
            elsif {{ann[:required]}}
              raise Error.new("Missing argument <{{ivar.name}}>")
            end
            %index += 1
          {% end %}
        {% end %}
        @rest = positional[%index..]? || [] of String
        {% for ivar in @type.instance_vars %}
          {% if ann = ivar.annotation(::Silth::Command::Opt) %}
            if %val = opts.delete({{ivar.name.stringify}})
              @{{ivar.name}} = __convert(%val, {{ann[:type]}})
            end
          {% end %}
        {% end %}
      {% end %}
      raise Error.new("Unknown option --#{opts.keys.first.tr("_", "-")}") unless opts.empty?
    end

    private def __convert(raw : String, type : String.class) : String
      raw
    end

    private def __convert(raw : String, type : Int32.class) : Int32
      raw.to_i? || raise Error.new("Expected an integer, got '#{raw}'")
    end

    private def __convert(raw : String, type : Int64.class) : Int64
      raw.to_i64? || raise Error.new("Expected an integer, got '#{raw}'")
    end

    private def __convert(raw : String, type : Float64.class) : Float64
      raw.to_f? || raise Error.new("Expected a number, got '#{raw}'")
    end

    private def __convert(raw : String, type : Bool.class) : Bool
      %w(1 true yes on).includes?(raw.downcase)
    end

    private def __convert(raw : String, type : Array(String).class) : Array(String)
      raw.split(',').map(&.strip).reject(&.empty?)
    end

    private def __bool_option?(name : String) : Bool
      {% begin %}
        {% for ivar in @type.instance_vars %}
          {% if (ann = ivar.annotation(::Silth::Command::Opt)) && ann[:type].resolve == Bool %}
            return true if name == {{ivar.name.stringify}}
          {% end %}
        {% end %}
      {% end %}
      false
    end

    private def __short_to_long(short : String) : String?
      {% begin %}
        {% for ivar in @type.instance_vars %}
          {% if (ann = ivar.annotation(::Silth::Command::Opt)) && ann[:short] %}
            return {{ivar.name.stringify}} if short == {{ann[:short]}}
          {% end %}
        {% end %}
      {% end %}
      nil
    end

    def help : String
      String.build do |io|
        io << "\n  " << self.class.description.colorize(:white).bold << "\n\n" unless self.class.description.empty?
        io << "  " << "Usage:".colorize(:yellow) << " silth " << self.class.command_name
        {% begin %}
          {% for ivar in @type.instance_vars %}
            {% if ann = ivar.annotation(::Silth::Command::Arg) %}
              io << ({{ann[:required]}} ? " <{{ivar.name}}>" : " [{{ivar.name}}]")
            {% end %}
          {% end %}
          io << " [options]\n"
          {% args = @type.instance_vars.select(&.annotation(::Silth::Command::Arg)) %}
          {% unless args.empty? %}
            io << "\n  " << "Arguments:".colorize(:yellow) << '\n'
            {% for ivar in args %}
              io << "    " << {{ivar.name.stringify}}.ljust(24).colorize(:green) << {{ivar.annotation(::Silth::Command::Arg)[:description]}} << '\n'
            {% end %}
          {% end %}
          {% opts = @type.instance_vars.select(&.annotation(::Silth::Command::Opt)) %}
          {% unless opts.empty? %}
            io << "\n  " << "Options:".colorize(:yellow) << '\n'
            {% for ivar in opts %}
              {% ann = ivar.annotation(::Silth::Command::Opt) %}
              %flag = {% if ann[:short] %}"-{{ann[:short].id}}, "{% else %}"    "{% end %} + "--{{ivar.name.gsub(/_/, "-")}}"
              io << "    " << %flag.ljust(24).colorize(:green) << {{ann[:description]}} << '\n'
            {% end %}
          {% end %}
        {% end %}
      end
    end

    # --- output helpers --------------------------------------------------------

    def line(text = "") : Nil
      @stdout.puts text
    end

    def info(text : String) : Nil
      @stdout.puts "#{"●".colorize(:cyan)} #{text}"
    end

    def success(text : String) : Nil
      @stdout.puts "#{"✔".colorize(:green)} #{text}"
    end

    def warn(text : String) : Nil
      @stdout.puts "#{"!".colorize(:yellow)} #{text.colorize(:yellow)}"
    end

    def error(text : String) : Nil
      @stdout.puts "#{"✖".colorize(:red)} #{text.colorize(:red)}"
    end

    def comment(text : String) : Nil
      @stdout.puts text.colorize(:dark_gray)
    end

    def table(headers : Array(String), rows : Array(Array(String))) : Nil
      widths = headers.map_with_index { |h, i| ([h.size] + rows.map { |r| (r[i]? || "").size }).max }
      @stdout.puts "  " + headers.map_with_index { |h, i| h.ljust(widths[i]) }.join("  ").colorize(:yellow).to_s
      @stdout.puts "  " + widths.map { |w| "─" * w }.join("  ").colorize(:dark_gray).to_s
      rows.each { |r| @stdout.puts "  " + r.map_with_index { |c, i| c.ljust(widths[i]) }.join("  ") }
    end

    def ask(question : String, default : String? = nil) : String
      @stdout.print "#{"?".colorize(:cyan)} #{question}#{default ? " (#{default})".colorize(:dark_gray) : ""} "
      @stdout.flush
      answer = (@stdin.gets || "").strip
      answer.empty? ? (default || "") : answer
    end

    def confirm?(question : String, default : Bool = false) : Bool
      answer = ask("#{question} #{default ? "[Y/n]" : "[y/N]"}").downcase
      answer.empty? ? default : answer.starts_with?('y')
    end

    def choose(question : String, options : Array(String)) : String
      options.each_with_index { |o, i| @stdout.puts "  #{(i + 1).to_s.colorize(:cyan)}. #{o}" }
      loop do
        answer = ask(question)
        if (idx = answer.to_i?) && options[idx - 1]?
          return options[idx - 1]
        end
        return answer if options.includes?(answer)
      end
    end

    # Shows a progress bar while iterating.
    def progress(items : Enumerable(T), label : String = "", & : T ->) : Nil forall T
      list = items.to_a
      list.each_with_index do |item, i|
        yield item
        pct = ((i + 1) * 100 / {list.size, 1}.max).to_i
        bar = "█" * (pct // 4) + "░" * (25 - pct // 4)
        @stdout.print "\r  #{bar.colorize(:cyan)} #{pct.to_s.rjust(3)}% #{label}"
        @stdout.flush
      end
      @stdout.puts
    end
  end

  # Command registry and dispatcher.
  module CLI
    BANNER = <<-TXT
         ◆  S I L T H
        dark, elegant web framework for Crystal
      TXT

    def self.commands : Hash(String, Command.class)
      {% begin %}
        list = {} of String => Command.class
        {% for klass in Silth::Command.all_subclasses.reject(&.abstract?) %}
          list[{{klass}}.command_name] = {{klass}}
        {% end %}
        list
      {% end %}
    end

    # User defined aliases from `config/cli.yml` (`aliases: { m: db:migrate }`).
    def self.aliases : Hash(String, String)
      return {} of String => String unless File.exists?("config/cli.yml")
      Silth.config.hash("cli.aliases")
    rescue
      {} of String => String
    end

    def self.run(args : Array(String) = ARGV, output : IO = STDOUT) : Int32
      name = args.first? || "help"
      rest = args[1..]? || [] of String
      if expansion = aliases[name]?
        parts = expansion.split(' ')
        name = parts.first
        rest = parts[1..] + rest
      end
      if name.in?("help", "--help", "-h", "list")
        if target = rest.first?.try { |n| commands[n]? }
          output.puts target.new.help
        else
          print_list(output)
        end
        return 0
      end
      klass = commands[name]?
      unless klass
        suggestion = commands.keys.min_by? { |k| Levenshtein.distance(k, name) }
        output.puts "#{"✖".colorize(:red)} Unknown command '#{name}'.#{suggestion ? " Did you mean '#{suggestion}'?" : ""}"
        return 1
      end
      command = klass.new
      command.stdout = output
      if rest.includes?("--help") || rest.includes?("-h")
        output.puts command.help
        return 0
      end
      command.__parse(rest)
      command.run
      0
    rescue ex : Command::Error
      output.puts "#{"✖".colorize(:red)} #{ex.message}"
      1
    rescue ex : Exception
      output.puts "#{"✖".colorize(:red)} #{ex.class.name.colorize(:red).bold}: #{ex.message}"
      if args.includes?("--trace") || ENV["SILTH_TRACE"]?
        output.puts ex.backtrace?.try(&.first(25).join('\n')).colorize(:dark_gray)
      else
        output.puts "  (re-run with SILTH_TRACE=1 for the backtrace)".colorize(:dark_gray)
      end
      1
    end

    def self.print_list(output : IO) : Nil
      output.puts BANNER.colorize(:light_cyan)
      output.puts "\n  #{"Usage:".colorize(:yellow)} silth <command> [arguments] [options]\n"
      groups = commands.reject { |_, k| k.hidden? }.to_a.sort_by(&.[0]).group_by { |(n, _)| n.includes?(':') ? n.split(':').first : "" }
      groups.to_a.sort_by { |(g, _)| g }.each do |group, list|
        output.puts "\n  #{(group.empty? ? "Available commands" : group).colorize(:yellow)}"
        list.each { |(n, k)| output.puts "    #{n.ljust(26).colorize(:green)}#{k.description}" }
      end
      unless aliases.empty?
        output.puts "\n  #{"Aliases (config/cli.yml)".colorize(:yellow)}"
        aliases.each { |a, target| output.puts "    #{a.ljust(26).colorize(:green)}→ #{target}" }
      end
      output.puts
    end
  end
end

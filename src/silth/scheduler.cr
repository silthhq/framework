module Silth
  # Cron expression (5 fields: minute hour day-of-month month day-of-week).
  # Supports `*`, `*/n`, ranges `a-b`, steps `a-b/n`, lists and names (`mon`, `jan`).
  struct Cron
    NAMES = {"sun" => 0, "mon" => 1, "tue" => 2, "wed" => 3, "thu" => 4, "fri" => 5, "sat" => 6,
             "jan" => 1, "feb" => 2, "mar" => 3, "apr" => 4, "may" => 5, "jun" => 6,
             "jul" => 7, "aug" => 8, "sep" => 9, "oct" => 10, "nov" => 11, "dec" => 12}

    getter expression : String
    @fields : Array(Set(Int32))

    def initialize(@expression : String)
      parts = @expression.strip.split(/\s+/)
      raise ArgumentError.new("Cron expression needs 5 fields: #{@expression}") unless parts.size == 5
      ranges = [{0, 59}, {0, 23}, {1, 31}, {1, 12}, {0, 6}]
      @fields = parts.map_with_index { |p, i| parse(p.downcase, ranges[i][0], ranges[i][1]) }
    end

    private def parse(field : String, min : Int32, max : Int32) : Set(Int32)
      set = Set(Int32).new
      field.split(',').each do |part|
        range_part, _, step_part = part.partition('/')
        step = step_part.empty? ? 1 : step_part.to_i
        from, to = if range_part == "*"
                     {min, max}
                   elsif range_part.includes?('-')
                     a, b = range_part.split('-', 2)
                     {value(a), value(b)}
                   else
                     v = value(range_part)
                     {v, step_part.empty? ? v : max}
                   end
        (from..to).step(step).each { |v| set << (max == 6 && v == 7 ? 0 : v) }
      end
      set
    end

    private def value(token : String) : Int32
      NAMES[token]? || token.to_i
    end

    def due?(time : Time) : Bool
      @fields[0].includes?(time.minute) && @fields[1].includes?(time.hour) &&
        @fields[2].includes?(time.day) && @fields[3].includes?(time.month) &&
        @fields[4].includes?(time.day_of_week.value % 7)
    end

    def next_after(time : Time) : Time
      t = time.at_beginning_of_minute + 1.minute
      525_600.times do
        return t if due?(t)
        t += 1.minute
      end
      raise ArgumentError.new("Cron #{@expression} never matches")
    end
  end

  # Task scheduler (`silth schedule:run` from system cron every minute, or `silth schedule:work`).
  #
  # ```
  # Silth.schedule do |s|
  #   s.job(PruneSessionsJob.new).daily_at("03:00")
  #   s.call("refresh-stats") { Stats.refresh }.every(10.minutes).without_overlapping
  #   s.command("cache:clear").weekly_on(:monday, "08:00").timezone("Europe/Paris")
  # end
  # ```
  class Scheduler
    Log = ::Log.for("silth.schedule")

    class Task
      getter name : String
      getter cron : Cron = Cron.new("* * * * *")
      getter location : Time::Location = Time::Location::UTC
      getter? overlapping = true
      getter? one_server = false
      getter last_run : Time? = nil
      getter last_status : String? = nil
      @conditions = [] of -> Bool
      @window : {Int32, Int32}? = nil

      def initialize(@name : String, &@action : -> Nil)
      end

      def cron(expression : String) : self
        @cron = Cron.new(expression)
        self
      end

      def every_minute : self
        cron("* * * * *")
      end

      def every(span : Time::Span) : self
        minutes = span.total_minutes.to_i
        if minutes < 60
          cron("*/#{minutes} * * * *")
        elsif minutes % 60 == 0 && minutes < 1440
          cron("0 */#{minutes // 60} * * *")
        else
          cron("0 0 */#{minutes // 1440} * *")
        end
      end

      def hourly : self
        cron("0 * * * *")
      end

      def hourly_at(minute : Int32) : self
        cron("#{minute} * * * *")
      end

      def daily : self
        cron("0 0 * * *")
      end

      def daily_at(time : String) : self
        h, m = time.split(':').map(&.to_i)
        cron("#{m} #{h} * * *")
      end

      def twice_daily(first : Int32 = 1, second : Int32 = 13) : self
        cron("0 #{first},#{second} * * *")
      end

      def weekly : self
        cron("0 0 * * 0")
      end

      def weekly_on(day : Symbol, time : String = "00:00") : self
        h, m = time.split(':').map(&.to_i)
        cron("#{m} #{h} * * #{day.to_s[0, 3]}")
      end

      def monthly : self
        cron("0 0 1 * *")
      end

      def monthly_on(day : Int32, time : String = "00:00") : self
        h, m = time.split(':').map(&.to_i)
        cron("#{m} #{h} #{day} * *")
      end

      def weekdays : self
        parts = @cron.expression.split(' ')
        cron("#{parts[0]} #{parts[1]} * * 1-5")
      end

      def weekends : self
        parts = @cron.expression.split(' ')
        cron("#{parts[0]} #{parts[1]} * * 0,6")
      end

      def timezone(name : String) : self
        @location = Time::Location.load(name)
        self
      end

      def between(from : String, to : String) : self
        a = from.split(':').map(&.to_i)
        b = to.split(':').map(&.to_i)
        @window = {a[0] * 60 + a[1], b[0] * 60 + b[1]}
        self
      end

      def when(&block : -> Bool) : self
        @conditions << block
        self
      end

      def skip(&block : -> Bool) : self
        @conditions << -> { !block.call }
        self
      end

      # Prevents concurrent runs (cache lock).
      def without_overlapping : self
        @overlapping = false
        self
      end

      # Runs on a single server per minute when several schedulers share a cache.
      def on_one_server : self
        @one_server = true
        self
      end

      def due?(now : Time) : Bool
        local = now.in(@location)
        return false unless @cron.due?(local)
        if w = @window
          minutes = local.hour * 60 + local.minute
          return false unless w[0] <= minutes <= w[1]
        end
        @conditions.all?(&.call)
      end

      def next_run(now : Time = Time.utc) : Time
        @cron.next_after(now.in(@location))
      end

      def run : Nil
        started = Time.instant
        if @one_server
          minute_key = "schedule:#{@name}:#{Time.utc.to_unix // 60}"
          return unless Silth.cache.add(minute_key, "1", 2.minutes)
        end
        if @overlapping
          @action.call
        else
          ran = Silth.cache.lock("schedule:#{@name}", 1.hour) { @action.call; true }
          (Log.info { "Skipped #{@name} (still running)" }; return) if ran.nil?
        end
        @last_status = "ok"
        Log.info { "Ran #{@name} (#{(Time.instant - started).total_milliseconds.round(1)}ms)" }
      rescue ex
        @last_status = "failed: #{ex.message}"
        Log.error(exception: ex) { "Scheduled task #{@name} failed" }
        ErrorReporter.report(ex)
      ensure
        @last_run = Time.utc
      end
    end

    getter tasks = [] of Task

    def call(name : String, &block : -> _) : Task
      task = Task.new(name) { block.call; nil }
      @tasks << task
      task
    end

    def job(job : Job, name : String? = nil) : Task
      call(name || job.class.name) { job.dispatch; nil }
    end

    def command(line : String) : Task
      call("silth #{line}") { CLI.run(line.split(' ')); nil }
    end

    def due(now : Time = Time.utc) : Array(Task)
      @tasks.select(&.due?(now))
    end

    # Runs tasks due this minute (each in its own fiber).
    def run_due(now : Time = Time.utc) : Int32
      list = due(now)
      done = ::Channel(Nil).new
      list.each { |t| spawn { t.run; done.send(nil) } }
      list.size.times { done.receive }
      list.size
    end

    # Long running loop aligned on minute boundaries.
    def work : Nil
      Log.info { "Scheduler started with #{@tasks.size} task(s)" }
      loop do
        now = Time.utc
        sleep (now.at_beginning_of_minute + 1.minute - now)
        run_due(Time.utc)
      end
    end
  end

  @@scheduler = Scheduler.new

  def self.scheduler : Scheduler
    @@scheduler
  end

  def self.schedule(& : Scheduler ->) : Nil
    yield @@scheduler
  end
end

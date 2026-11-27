require "json"

module Silth
  # A calendar date without a time of day nor a time zone: what a `DATE`
  # column holds (a due date, a birthday). PostgreSQL and MySQL `DATE` columns
  # are read as `Date`, written to JSON as `"2026-11-27"`.
  #
  # ```
  # due = Date.new(2026, 11, 27)
  # due + 30                                 # => 2026-12-27
  # due.shift(months: 1)                     # => 2026-12-27 (end of month clamped: Jan 31 + 1 month = Feb 28)
  # Date.parse("2026-02-01").at_end_of_month # => 2026-02-28
  # Date.today < due                         # comparable
  # (Date.new(2026, 12, 25) - due)           # => 28 (days)
  # (due..due + 6).each { |day| }            # ranges of days
  # ```
  struct Date
    include Comparable(Date)

    # Midnight UTC of the day.
    getter time : Time

    def initialize(year : Int, month : Int, day : Int)
      @time = Time.utc(year, month, day)
    end

    # The calendar date of *time*, read in its own location.
    def self.new(time : Time) : self
      new(time.year, time.month, time.day)
    end

    # Today, in *location* (the machine's time zone by default).
    def self.today(location : Time::Location = Time::Location.local) : self
      new(Time.local(location))
    end

    # Parses `"2026-11-27"` (a timestamp gives its date part).
    def self.parse(text : String) : self
      parse?(text) || raise ArgumentError.new("Invalid date: #{text[0, 40].inspect} (expected YYYY-MM-DD)")
    end

    def self.parse?(text : String) : self?
      if m = text.strip.match(/\A(\d{4})-(\d{2})-(\d{2})(?:[T ].*)?\z/)
        year, month, day = m[1].to_i, m[2].to_i, m[3].to_i
        return nil unless 1 <= month <= 12 && 1 <= day <= Time.days_in_month(year, month)
        new(year, month, day)
      end
    end

    def year : Int32
      @time.year
    end

    def month : Int32
      @time.month
    end

    def day : Int32
      @time.day
    end

    def day_of_week : Time::DayOfWeek
      @time.day_of_week
    end

    def day_of_year : Int32
      @time.day_of_year
    end

    def days_in_month : Int32
      Time.days_in_month(year, month)
    end

    def leap_year? : Bool
      Time.leap_year?(year)
    end

    def weekend? : Bool
      day_of_week.saturday? || day_of_week.sunday?
    end

    # *days* later (or earlier when negative).
    def +(days : Int) : Date
      Date.new(@time + days.days)
    end

    def -(days : Int) : Date
      self + (-days)
    end

    def +(span : Time::Span) : Date
      Date.new(@time + span)
    end

    def -(span : Time::Span) : Date
      Date.new(@time - span)
    end

    def +(span : Time::MonthSpan) : Date
      shift(months: span.value.to_i)
    end

    def -(span : Time::MonthSpan) : Date
      shift(months: -span.value.to_i)
    end

    # The number of days between two dates.
    def -(other : Date) : Int32
      ((@time - other.time).total_days).round.to_i
    end

    # Moves by calendar units; the day is clamped to the end of a shorter month.
    def shift(*, years : Int = 0, months : Int = 0, days : Int = 0) : Date
      Date.new(@time.shift(years: years, months: months, days: days))
    end

    # The next day (makes `Range(Date, Date)` iterable).
    def succ : Date
      self + 1
    end

    def pred : Date
      self - 1
    end

    def at_beginning_of_month : Date
      Date.new(year, month, 1)
    end

    def at_end_of_month : Date
      Date.new(year, month, days_in_month)
    end

    def at_beginning_of_year : Date
      Date.new(year, 1, 1)
    end

    def at_end_of_year : Date
      Date.new(year, 12, 31)
    end

    # Monday of the week (ISO weeks).
    def at_beginning_of_week : Date
      self - (day_of_week.value - 1)
    end

    def <=>(other : Date) : Int32
      @time <=> other.time
    end

    def hash(hasher)
      @time.hash(hasher)
    end

    # Midnight of this day in *location*.
    def to_time(location : Time::Location = Time::Location::UTC) : Time
      Time.local(year, month, day, location: location)
    end

    def to_s(io : IO) : Nil
      @time.to_s(io, "%Y-%m-%d")
    end

    # Formats with `Time::Format` directives: `date.to_s("%d/%m/%Y")`.
    def to_s(format : String) : String
      @time.to_s(format)
    end

    def inspect(io : IO) : Nil
      to_s(io)
    end

    def to_json(json : JSON::Builder) : Nil
      json.string(to_s)
    end

    def to_json_object_key : String
      to_s
    end

    def self.new(pull : JSON::PullParser) : self
      text = pull.read_string
      parse?(text) || raise JSON::ParseException.new("Invalid date #{text.inspect} (expected YYYY-MM-DD)", *pull.location)
    end

    def self.from_json_object_key?(key : String) : self?
      parse?(key)
    end
  end
end

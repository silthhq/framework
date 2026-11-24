module Silth
  # Internal instrumentation bus. Subsystems publish events; the profiler,
  # telemetry exporters and logs subscribe.
  #
  # ```
  # Silth::Instrument.subscribe do |event|
  #   if event.is_a?(Silth::Instrument::Query) && event.duration > 100.milliseconds
  #     Log.warn { "Slow query: #{event.sql}" }
  #   end
  # end
  # ```
  module Instrument
    abstract struct Event
      getter at : Time = Time.utc

      def kind : String
        self.class.name.split("::").last.downcase
      end
    end

    struct Query < Event
      getter sql : String
      getter args : Array(String)
      getter duration : Time::Span
      getter connection : String
      getter rows : Int32

      def initialize(@sql, @args, @duration, @connection, @rows = 0)
      end
    end

    struct Cache < Event
      getter operation : String
      getter key : String
      getter hit : Bool
      getter store : String

      def initialize(@operation, @key, @hit, @store)
      end
    end

    struct Mail < Event
      getter to : String
      getter subject : String
      getter mailer : String

      def initialize(@to, @subject, @mailer)
      end
    end

    struct Job < Event
      getter name : String
      getter queue : String
      getter status : String
      getter duration : Time::Span?

      def initialize(@name, @queue, @status, @duration = nil)
      end
    end

    struct AppEvent < Event
      getter name : String
      getter listeners : Int32

      def initialize(@name, @listeners)
      end
    end

    struct HTTPCall < Event
      getter method : String
      getter url : String
      getter status : Int32
      getter duration : Time::Span

      def initialize(@method, @url, @status, @duration)
      end
    end

    struct Notification < Event
      getter name : String
      getter channels : String

      def initialize(@name, @channels)
      end
    end

    struct Action < Event
      getter controller : String
      getter action : String

      def initialize(@controller, @action)
      end
    end

    struct Render < Event
      getter template : String
      getter duration : Time::Span

      def initialize(@template, @duration)
      end
    end

    struct Custom < Event
      getter name : String
      getter data : Hash(String, String)

      def initialize(@name, @data = {} of String => String)
      end
    end

    @@subscribers = [] of Event -> Nil

    def self.subscribe(&block : Event -> Nil) : Nil
      @@subscribers << block
    end

    def self.publish(event : Event) : Nil
      return if @@subscribers.empty?
      @@subscribers.each &.call(event)
    end

    def self.query(sql : String, args, duration : Time::Span, connection : String, rows : Int32 = 0) : Nil
      return if @@subscribers.empty?
      publish(Query.new(sql, args.map { |a| a.nil? ? "NULL" : a.to_s[0, 200] }, duration, connection, rows))
    end

    def self.action(controller : String, action : String) : Nil
      publish(Action.new(controller, action)) unless @@subscribers.empty?
    end

    # Measures a block and publishes a custom event with its duration.
    def self.measure(name : String, &)
      start = Time.instant
      result = yield
      publish(Custom.new(name, {"duration_ms" => (Time.instant - start).total_milliseconds.round(3).to_s}))
      result
    end
  end
end

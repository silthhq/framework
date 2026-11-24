module Silth
  # Base class for application events.
  #
  # ```
  # class UserRegistered < Silth::Event
  #   getter user_id : Int64
  #   def initialize(@user_id); end
  # end
  #
  # Silth::Events.listen(UserRegistered) { |e| WelcomeMail.new(e.user_id).deliver_later }
  # Silth::Events.dispatch(UserRegistered.new(user.id))
  # ```
  abstract class Event
    getter occurred_at : Time = Time.utc

    def event_name : String
      self.class.name
    end
  end

  # Class based listener; `queued` ones run on the job queue.
  #
  # ```
  # class SendWelcomeEmail < Silth::Listener(UserRegistered)
  #   def handle(event : UserRegistered) : Nil
  #     WelcomeMail.new(event.user_id).deliver
  #   end
  # end
  # ```
  abstract class Listener(E)
    abstract def handle(event : E) : Nil

    def self.queued? : Bool
      false
    end

    macro queued
      def self.queued? : Bool
        true
      end
    end

    # :nodoc:
    def self.register : Nil
      Events.listen(E) do |event|
        if queued?
          Concurrency.defer { new.handle(event) }
        else
          new.handle(event)
        end
      end
    end
  end

  module Events
    Log = ::Log.for("silth.events")

    @@listeners = {} of String => Array(Proc(Event, Nil))
    @@wildcards = [] of Proc(Event, Nil)
    @@faked : Array(Event)? = nil

    def self.listen(type : T.class, &block : T -> _) : Nil forall T
      (@@listeners[T.name] ||= [] of Proc(Event, Nil)) << ->(e : Event) { block.call(e.as(T)); nil }
    end

    # Listens to every event (audit logs, analytics…).
    def self.listen_all(&block : Event -> _) : Nil
      @@wildcards << ->(e : Event) { block.call(e); nil }
    end

    def self.dispatch(event : Event) : Nil
      if faked = @@faked
        faked << event
        return
      end
      listeners = @@listeners[event.class.name]? || [] of Proc(Event, Nil)
      Instrument.publish(Instrument::AppEvent.new(event.class.name, listeners.size + @@wildcards.size))
      listeners.each &.call(event)
      @@wildcards.each &.call(event)
    end

    # Dispatches after the surrounding database transaction commits.
    def self.dispatch_after_commit(event : Event) : Nil
      if DB.configured?
        DB.connection.after_commit { dispatch(event) }
      else
        dispatch(event)
      end
    end

    def self.has_listeners?(type : Event.class) : Bool
      !(@@listeners[type.name]?.try(&.empty?) != false)
    end

    def self.forget(type : Event.class) : Nil
      @@listeners.delete(type.name)
    end

    # Registers every class based `Listener` compiled into the program.
    def self.boot : Nil
      {% for listener in Listener.all_subclasses.reject(&.abstract?) %}
        {% unless listener.type_vars.size > 0 && listener.type_vars.first.is_a?(TypeParameter) %}
          {{listener}}.register
        {% end %}
      {% end %}
    end

    # --- testing ----------------------------------------------------------------

    def self.fake : Nil
      @@faked = [] of Event
    end

    def self.unfake : Nil
      @@faked = nil
    end

    def self.dispatched : Array(Event)
      @@faked || [] of Event
    end

    def self.dispatched?(type : T.class) : Bool forall T
      dispatched.any?(T)
    end
  end
end

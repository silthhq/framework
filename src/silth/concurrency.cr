require "wait_group"

module Silth
  # Structured concurrency helpers on top of Crystal fibers and channels.
  #
  # ```
  # users, posts = Silth::Concurrency.run(-> { User.count }, -> { Post.count })
  # results = Silth::Concurrency.map(urls, workers: 8) { |url| Silth::HTTPClient.get(url).status }
  # Silth::Concurrency.defer { Analytics.track(event) }       # after the response
  # Silth::Concurrency.timeout(2.seconds) { slow_call }       # raises Timeout
  # ```
  module Concurrency
    Log = ::Log.for("silth.concurrency")

    class Timeout < Silth::Error; end

    class Failed < Silth::Error
      getter errors : Array(Exception)

      def initialize(@errors : Array(Exception))
        super("#{@errors.size} concurrent task(s) failed: #{@errors.first?.try(&.message)}")
      end
    end

    # Runs every proc concurrently and returns their results in order.
    def self.run(*tasks : -> T) : Array(T) forall T
      map(tasks.to_a, workers: tasks.size) { |t| t.call }
    end

    def self.run(tasks : Array(-> T)) : Array(T) forall T
      map(tasks, workers: tasks.size) { |t| t.call }
    end

    # Parallel map with bounded concurrency; preserves order, re-raises failures.
    def self.map(items : Enumerable(A), workers : Int32 = 8, &block : A -> B) : Array(B) forall A, B
      list = items.to_a
      results = Array(B?).new(list.size, nil)
      errors = [] of Exception
      queue = ::Channel(Int32).new(list.size)
      list.size.times { |i| queue.send(i) }
      queue.close
      wg = WaitGroup.new({workers, list.size}.min)
      {workers, list.size}.min.times do
        spawn do
          begin
            while i = queue.receive?
              begin
                results[i] = block.call(list[i])
              rescue ex
                errors << ex
              end
            end
          ensure
            wg.done
          end
        end
      end
      wg.wait
      raise Failed.new(errors) unless errors.empty?
      results.map(&.as(B))
    end

    def self.each(items : Enumerable(A), workers : Int32 = 8, &block : A -> _) : Nil forall A
      map(items, workers) { |i| block.call(i); nil }
    end

    # Fire and forget in a new fiber; errors are logged and reported.
    def self.defer(name : String = "deferred", &block : -> _) : Nil
      ctx = Context.current?
      spawn(name: name) do
        Fiber.current.silth_context = ctx
        begin
          block.call
        rescue ex
          Log.error(exception: ex) { "Deferred task '#{name}' failed" }
          ErrorReporter.report(ex)
        end
      end
    end

    def self.timeout(span : Time::Span, &block : -> T) : T forall T
      channel = ::Channel(T | Exception).new(1)
      spawn do
        channel.send(block.call)
      rescue ex
        channel.send(ex)
      end
      select
      when value = channel.receive
        raise value if value.is_a?(Exception)
        value
      when timeout(span)
        raise Timeout.new("Operation timed out after #{span.total_seconds}s")
      end
    end

    # Retries a block with exponential backoff.
    def self.retry(times : Int32 = 3, base_delay : Time::Span = 100.milliseconds, on : Exception.class = Exception, &block : -> T) : T forall T
      attempt = 0
      loop do
        attempt += 1
        begin
          return block.call
        rescue ex
          raise ex if attempt >= times || !ex.class.<=(on)
          sleep base_delay * (2 ** (attempt - 1))
        end
      end
    end
  end
end

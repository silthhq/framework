module Silth
  module Profiler
    # Performance budgets: how fast a route should answer.
    #
    # ```yaml
    # # config/profiler.yml
    # budget_ms: 300                 # every route
    # budgets:
    #   "GET /posts": 120            # a route, as `silth routes` prints it
    #   "PostsController#show": 80   # or a handler (also "CounterComponent#increment")
    # budget_strict: false           # true: a spec fails when a request exceeds its budget
    # ```
    #
    # The toolbar's time item turns red past the budget and the dashboard flags
    # the request; in specs, `Silth::Testing` lists the requests over budget at
    # the end of the run.
    module Budget
      # Budget in milliseconds for a request, nil when none applies: the handler's,
      # then the route's, then `budget_ms`.
      def self.for(method : String, route : String, handler : String) : Float64?
        budgets = Silth.config.hash("profiler.budgets")
        value = budgets[handler]? || budgets["#{method} #{route}"]? || Silth.config.string?("profiler.budget_ms")
        value.try(&.to_f?).try { |ms| ms > 0 ? ms : nil }
      end

      def self.strict? : Bool
        Silth.config.bool("profiler.budget_strict", false) || ENV["SILTH_BUDGETS"]? == "strict"
      end
    end
  end
end

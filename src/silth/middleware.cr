module Silth
  # Base class for HTTP middleware.
  #
  # ```
  # class EnsureAdmin < Silth::Middleware
  #   def call(ctx, chain)
  #     raise Silth::Forbidden.new unless ctx.auth_user.try(&.admin?)
  #     chain.next(ctx)
  #   end
  # end
  # ```
  abstract class Middleware
    abstract def call(ctx : Context, chain : Chain) : Nil

    def name : String
      self.class.name.split("::").last
    end
  end

  # Wraps a block as middleware: `app.middleware.use { |ctx, chain| chain.next(ctx) }`.
  class BlockMiddleware < Middleware
    def initialize(@name : String, &@block : Context, Chain -> Nil)
    end

    def call(ctx : Context, chain : Chain) : Nil
      @block.call(ctx, chain)
    end

    def name : String
      @name
    end
  end

  # Position inside a middleware pipeline. Middleware instances are shared,
  # the chain carries the cursor, so the same instance can appear in many stacks.
  struct Chain
    def initialize(@stack : Array(Middleware), @endpoint : Endpoint, @index : Int32 = 0)
    end

    def next(ctx : Context) : Nil
      if middleware = @stack[@index]?
        middleware.call(ctx, Chain.new(@stack, @endpoint, @index + 1))
      else
        @endpoint.call(ctx)
      end
    end
  end

  # Ordered, mutable list of middleware.
  class MiddlewareStack
    getter items = [] of Middleware

    def initialize(@items = [] of Middleware)
    end

    def use(middleware : Middleware) : self
      @items << middleware
      self
    end

    def use(name : String = "block", &block : Context, Chain -> Nil) : self
      use(BlockMiddleware.new(name, &block))
    end

    def prepend(middleware : Middleware) : self
      @items.unshift(middleware)
      self
    end

    def insert_before(klass : Middleware.class, middleware : Middleware) : self
      idx = @items.index { |m| m.class == klass } || @items.size
      @items.insert(idx, middleware)
      self
    end

    def insert_after(klass : Middleware.class, middleware : Middleware) : self
      idx = @items.index { |m| m.class == klass }
      idx ? @items.insert(idx + 1, middleware) : @items << middleware
      self
    end

    def remove(klass : Middleware.class) : self
      @items.reject! { |m| m.class == klass }
      self
    end

    def includes?(klass : Middleware.class) : Bool
      @items.any? { |m| m.class == klass }
    end

    def to_a : Array(Middleware)
      @items
    end
  end
end

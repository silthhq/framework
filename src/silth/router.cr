require "uri"

module Silth
  alias Endpoint = Context -> Nil

  # A single route: verb + path pattern + endpoint + metadata.
  class Route
    getter method : String
    getter path : String
    getter endpoint : Endpoint
    property name : String?
    getter group : String?
    getter middleware : Array(Middleware)
    getter controller : String?
    getter action : String?
    getter constraints : Hash(String, Regex)
    getter meta = {} of String => String
    getter segments : Array(String)
    @pipeline : Array(Middleware)?

    def initialize(@method, @path, @endpoint, @name = nil, @group = nil, @middleware = [] of Middleware,
                   @controller = nil, @action = nil, @constraints = {} of String => Regex)
      @segments = Router.split(@path)
    end

    def param_names : Array(String)
      @segments.compact_map { |s| s.starts_with?(':') || s.starts_with?('*') ? s[1..] : nil }
    end

    # Full middleware list: group stack + route specific middleware.
    def pipeline : Array(Middleware)
      @pipeline ||= (group.try { |g| Silth.app.middleware_groups[g]? } || [] of Middleware) + middleware
    end

    def handler_name : String
      (c = controller) ? "#{c}##{action}" : "closure"
    end
  end

  # Segment trie router: static segments win over parameters which win over globs.
  #
  # Patterns: `/posts/:id`, `/files/*path`, `/posts/:id<\d+>` (inline constraint).
  class Router
    class Node
      getter static = {} of String => Node
      getter params = [] of {String, Regex?, Node}
      property glob : {String, Node}? = nil
      getter routes = {} of String => Route
    end

    record Match, route : Route, params : Hash(String, String)

    getter routes = [] of Route
    getter named = {} of String => Route
    @root = Node.new

    def self.split(path : String) : Array(String)
      path.split('/').reject(&.empty?)
    end

    def add(route : Route) : Route
      node = @root
      route.segments.each do |segment|
        if segment.starts_with?('*')
          existing = node.glob
          if existing
            node = existing[1]
          else
            child = Node.new
            node.glob = {segment[1..], child}
            node = child
          end
        elsif segment.starts_with?(':')
          name, constraint = parse_param(segment[1..], route.constraints)
          entry = node.params.find { |(n, c, _)| n == name && c == constraint }
          unless entry
            entry = {name, constraint, Node.new}
            node.params << entry
            # Constrained params are tried before unconstrained ones.
            node.params.sort_by! { |(_, c, _)| c ? 0 : 1 }
          end
          node = entry[2]
        else
          node = (node.static[segment] ||= Node.new)
        end
      end
      node.routes[route.method] = route
      @routes << route
      if n = route.name
        @named[n] = route
      end
      route
    end

    private def parse_param(raw : String, constraints : Hash(String, Regex)) : {String, Regex?}
      if (lt = raw.index('<')) && raw.ends_with?('>')
        name = raw[0...lt]
        {name, Regex.new("\\A(?:#{raw[(lt + 1)..-2]})\\z")}
      else
        {raw, constraints[raw]?.try { |r| Regex.new("\\A(?:#{r.source})\\z") }}
      end
    end

    def match(method : String, path : String) : Match?
      segments = Router.split(path).map { |s| URI.decode(s) }
      params = {} of String => String
      if node = find(@root, segments, 0, params)
        if route = node.routes[method]? || (method == "HEAD" ? node.routes["GET"]? : nil) || node.routes["ANY"]?
          return Match.new(route, params)
        end
      end
      nil
    end

    # HTTP methods available for a path (used for 405 responses).
    def allowed_methods(path : String) : Array(String)
      segments = Router.split(path).map { |s| URI.decode(s) }
      params = {} of String => String
      node = find(@root, segments, 0, params)
      node ? node.routes.keys : [] of String
    end

    private def find(node : Node, segments : Array(String), index : Int32, params : Hash(String, String)) : Node?
      if index == segments.size
        return node unless node.routes.empty?
        if g = node.glob
          params[g[0]] = ""
          return g[1] unless g[1].routes.empty?
        end
        return nil
      end
      segment = segments[index]
      if child = node.static[segment]?
        if found = find(child, segments, index + 1, params)
          return found
        end
      end
      node.params.each do |(name, constraint, child)|
        next if constraint && !constraint.matches?(segment)
        params[name] = segment
        if found = find(child, segments, index + 1, params)
          return found
        end
        params.delete(name)
      end
      if g = node.glob
        params[g[0]] = segments[index..].join('/')
        return g[1] unless g[1].routes.empty?
      end
      nil
    end

    # Builds the URL of a named route. Unknown params become the query string.
    def url_for(name : String, **params) : String
      hash = {} of String => String
      params.each { |k, v| hash[k.to_s] = v.responds_to?(:to_param) ? v.to_param.to_s : v.to_s }
      url_for(name, hash)
    end

    def url_for(name : String, params : Hash(String, String)) : String
      route = @named[name]? || raise Error.new("Unknown route name '#{name}'. Run `silth routes` to list routes.")
      remaining = params.dup
      path = route.segments.map do |segment|
        if segment.starts_with?(':') || segment.starts_with?('*')
          key = segment[1..].sub(/<.*>\z/, "")
          value = remaining.delete(key) || raise Error.new("Missing parameter '#{key}' for route '#{name}'")
          segment.starts_with?('*') ? value : URI.encode_path_segment(value)
        else
          segment
        end
      end.join('/')
      url = "/#{path}"
      url += "?#{URI::Params.encode(remaining)}" unless remaining.empty?
      url
    end

    def has_route?(name : String) : Bool
      @named.has_key?(name)
    end
  end
end

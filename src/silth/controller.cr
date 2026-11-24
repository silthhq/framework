module Silth
  # Base class for controllers.
  #
  # ```
  # class PostsController < ApplicationController
  #   before_action :authenticate!, except: [:index, :show]
  #
  #   def index
  #     posts = Post.published.order(created_at: :desc).paginate(params.int("page", 1))
  #     render "posts/index", posts: posts
  #   end
  #
  #   def create
  #     post = Post.new(user_id: current_user.id)
  #     post.assign(params.permit(:title, :body, from: :post))
  #     if post.save
  #       redirect route("posts.show", id: post.id), notice: "Post created"
  #     else
  #       render "posts/new", status: 422, post: post
  #     end
  #   end
  # end
  # ```
  abstract class Controller
    include View::Rendering
    include View::Helpers

    LAYOUT = "layouts/application"

    getter ctx : Context

    def initialize(@ctx : Context)
    end

    delegate params, request, response, session, flash, cookies, json, text, html, xml, head,
      no_content, send_file, send_data, stream, sse, redirect_back, problem, wants_json?, to: @ctx

    def action_name : String
      @ctx.route.try(&.action) || ""
    end

    def redirect(to : String, status : Int32 = 302, notice : String? = nil, alert : String? = nil) : Nil
      flash["notice"] = notice if notice
      flash["alert"] = alert if alert
      @ctx.redirect(to, status)
    end

    # Renders a template within the controller layout and sends it as HTML.
    # The layout comes from the closest `LAYOUT` constant (`false` disables it).
    macro render(template, layout = nil, status = 200, **locals)
      {% layout_name = layout %}
      {% if layout_name == nil %}
        {% for t in [@type] + @type.ancestors %}
          {% if layout_name == nil && t.has_constant?("LAYOUT") %}
            {% layout_name = t.constant("LAYOUT") %}
          {% end %}
        {% end %}
      {% end %}
      @ctx.html(render_to_string({{template}}, layout: {{layout_name}}{% unless locals.empty? %}, {{locals.double_splat}}{% end %}), {{status}})
    end

    # Runs `method` before the action. A filter that responds (redirect, render…) halts the request.
    macro before_action(method, only = nil, except = nil, line = __LINE__)
      private def __before_action_{{@type.name.gsub(/[^A-Za-z0-9]/, "_").id}}_{{line}}(action : String) : Nil
        {% if only %} return unless {{(only.is_a?(ArrayLiteral) ? only : [only]).map(&.id.stringify)}}.includes?(action) {% end %}
        {% if except %} return if {{(except.is_a?(ArrayLiteral) ? except : [except]).map(&.id.stringify)}}.includes?(action) {% end %}
        {{method.id}}
        nil
      end
    end

    macro after_action(method, only = nil, except = nil, line = __LINE__)
      private def __after_action_{{@type.name.gsub(/[^A-Za-z0-9]/, "_").id}}_{{line}}(action : String) : Nil
        {% if only %} return unless {{(only.is_a?(ArrayLiteral) ? only : [only]).map(&.id.stringify)}}.includes?(action) {% end %}
        {% if except %} return if {{(except.is_a?(ArrayLiteral) ? except : [except]).map(&.id.stringify)}}.includes?(action) {% end %}
        {{method.id}}
        nil
      end
    end

    # Handles a given exception type inside this controller.
    macro rescue_from(klass, with method, line = __LINE__)
      private def __rescue_from_{{@type.name.gsub(/[^A-Za-z0-9]/, "_").id}}_{{line}}(ex : Exception) : Bool
        if ex.is_a?({{klass}})
          {{method.id}}(ex)
          return true
        end
        false
      end
    end

    # :nodoc:
    def __run_action(action : String, &) : Nil
      Instrument.action(self.class.name, action)
      begin
        {% begin %}
          {% chain = [@type] %}
          {% for a in @type.ancestors.select { |a| a < ::Silth::Controller } %}
            {% chain = [a] + chain %}
          {% end %}
          {% for t in chain %}
            {% for m in t.methods.select { |m| m.name.starts_with?("__before_action_") } %}
              {{m.name.id}}(action)
              return if @ctx.responded?
            {% end %}
          {% end %}
          yield self
          {% for t in chain %}
            {% for m in t.methods.select { |m| m.name.starts_with?("__after_action_") } %}
              {{m.name.id}}(action)
            {% end %}
          {% end %}
        {% end %}
      rescue ex : Exception
        {% begin %}
          {% chain = [@type] + @type.ancestors.select { |a| a < ::Silth::Controller } %}
          {% for t in chain %}
            {% for m in t.methods.select { |m| m.name.starts_with?("__rescue_from_") } %}
              return if {{m.name.id}}(ex)
            {% end %}
          {% end %}
        {% end %}
        raise ex
      end
      @ctx.no_content unless @ctx.responded?
    end

    # --- auth helpers -------------------------------------------------------

    def auth : Auth::Guard
      Auth.guard(@ctx)
    end

    def authenticate! : Nil
      return if @ctx.auth_user
      if wants_json?
        raise Unauthorized.new
      else
        session["_intended"] = @ctx.request.resource if @ctx.session? && @ctx.get?
        @ctx.redirect(Silth.config.string("auth.login_path", "/login"))
      end
    end

    # Raises `Forbidden` unless the current user may perform `ability` on `subject`.
    def authorize!(ability : Symbol | String, subject = nil) : Nil
      Authorization.authorize!(@ctx.auth_user, ability.to_s, subject)
    end

    def can?(ability : Symbol | String, subject = nil) : Bool
      Authorization.allowed?(@ctx.auth_user, ability.to_s, subject)
    end

    # Validates the request against a `Silth::FormRequest` and returns the typed result
    # (raises `UnprocessableEntity` with error details when invalid).
    def validate!(klass : T.class) : T forall T
      klass.from_params!(params)
    end
  end
end

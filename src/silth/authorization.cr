module Silth
  # Authorization policies (Laravel style) with a `before` hook (Symfony voter style).
  #
  # ```
  # class PostPolicy < Silth::Policy
  #   def before(user, ability) : Bool?
  #     true if user.as?(User).try(&.admin?)   # admins can do anything
  #   end
  #
  #   def update?(user : User, post : Post) : Bool
  #     post.user_id == user.id
  #   end
  #
  #   def view?(user : User?, post : Post) : Bool   # nilable user => guests allowed
  #     post.published? || post.user_id == user.try(&.id)
  #   end
  # end
  #
  # authorize! :update, post   # controller: raises 403
  # can?(:update, post)        # views & controllers
  # ```
  abstract class Policy
    # Return true/false to short-circuit, nil to continue with the ability method.
    def before(user : Auth::Authenticatable?, ability : String) : Bool?
      nil
    end
  end

  # Abilities that are not tied to a record.
  #
  # ```
  # Silth::Gate.define("view-admin") { |user| user.as?(User).try(&.admin?) || false }
  # ```
  module Gate
    @@gates = {} of String => Proc(Auth::Authenticatable?, Bool)

    def self.define(ability : String, &block : Auth::Authenticatable? -> Bool) : Nil
      @@gates[ability] = block
    end

    def self.[]?(ability : String) : Proc(Auth::Authenticatable?, Bool)?
      @@gates[ability]?
    end

    def self.defined?(ability : String) : Bool
      @@gates.has_key?(ability)
    end
  end

  module Authorization
    def self.allowed?(user : Auth::Authenticatable?, ability : String, subject = nil) : Bool
      if subject.nil?
        gate = Gate[ability]? || return false
        return gate.call(user)
      end
      result = check_policy(user, ability.rchop('?'), subject)
      result.nil? ? false : result
    end

    def self.authorize!(user : Auth::Authenticatable?, ability : String, subject = nil) : Nil
      raise Forbidden.new unless allowed?(user, ability, subject)
    end

    # Dispatches to `<Ability>?` methods of every policy whose second argument
    # matches the subject type. Generated at compile time.
    def self.check_policy(user : Auth::Authenticatable?, ability : String, subject) : Bool?
      {% begin %}
        {% for policy in Silth::Policy.all_subclasses.reject(&.abstract?) %}
          {% for m in policy.methods.select { |m| m.name.ends_with?("?") && m.args.size == 2 && m.args[1].restriction } %}
            {% utype = m.args[0].restriction %}
            if ability == {{m.name.stringify[0..-2]}} && subject.is_a?({{m.args[1].restriction}})
              %policy = {{policy}}.new
              %before = %policy.before(user, ability)
              return %before unless %before.nil?
              {% if utype && utype.resolve.nilable? %}
                return %policy.{{m.name}}(user.as?({{utype}}), subject)
              {% elsif utype %}
                if %u = user.as?({{utype}})
                  return %policy.{{m.name}}(%u, subject)
                end
                return false
              {% else %}
                return %policy.{{m.name}}(user, subject)
              {% end %}
            end
          {% end %}
        {% end %}
      {% end %}
      nil
    end
  end
end

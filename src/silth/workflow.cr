module Silth
  # Workflow engine and state machines (inspired by Symfony Workflow).
  #
  # ```yaml
  # # config/workflows.yml
  # blog_publishing:
  #   type: state_machine          # or "workflow" (several places at once)
  #   marking_property: status
  #   initial_marking: draft
  #   places: [draft, reviewed, rejected, published]
  #   transitions:
  #     to_review: { from: draft, to: reviewed }
  #     publish:   { from: reviewed, to: published, guard: can_publish }
  #     reject:    { from: reviewed, to: rejected }
  # ```
  #
  # ```
  # Silth::Workflow.guard("blog_publishing", "can_publish") { |subject, user| user.as?(User).try(&.editor?) || false }
  # Silth::Workflow.on("blog_publishing", :entered, "published") { |e| PublishedMail.new(e.subject).deliver_later }
  #
  # wf = Silth::Workflow.get("blog_publishing")
  # wf.can?(post, "publish", user)   # => true
  # wf.apply(post, "publish", user)  # updates post.status and saves
  # wf.enabled_transitions(post)     # => ["publish", "reject"]
  # ```
  module Workflow
    class NotEnabled < Silth::Error; end

    record Transition, name : String, from : Array(String), to : Array(String), guard : String? = nil

    enum Phase
      Guard
      Leave
      Transition
      Enter
      Entered
      Completed
      Announce
    end

    class TransitionEvent
      getter workflow : String
      getter transition : Transition
      getter subject : Model
      getter user : Auth::Authenticatable?
      getter marking : Array(String)
      property? blocked = false
      property block_reason : String? = nil

      def initialize(@workflow, @transition, @subject, @user, @marking)
      end

      def block(reason : String = "Blocked") : Nil
        @blocked = true
        @block_reason = reason
      end
    end

    # Dispatched on the global event bus after each applied transition.
    class Transitioned < Silth::Event
      getter workflow : String
      getter transition : String
      getter from : Array(String)
      getter to : Array(String)
      getter subject_type : String
      getter subject_id : String

      def initialize(@workflow, @transition, @from, @to, @subject_type, @subject_id)
      end
    end

    class Definition
      getter name : String
      getter type : String
      getter places = [] of String
      getter transitions = [] of Transition
      property initial : Array(String) = [] of String
      property marking_property = "status"
      property supports = [] of String
      getter metadata = {} of String => String

      def initialize(@name : String, @type : String = "state_machine")
      end

      def state_machine? : Bool
        @type == "state_machine"
      end

      def place(*names : String) : self
        names.each { |n| @places << n unless @places.includes?(n) }
        self
      end

      def transition(name : String, from : String | Array(String), to : String | Array(String), guard : String? = nil) : self
        from_list = from.is_a?(Array) ? from : [from]
        to_list = to.is_a?(Array) ? to : [to]
        (from_list + to_list).each { |p| place(p) }
        @transitions << Transition.new(name, from_list, to_list, guard)
        self
      end

      # Mermaid `stateDiagram-v2` (paste into docs / GitHub).
      def to_mermaid : String
        String.build do |io|
          io << "stateDiagram-v2\n"
          @initial.each { |p| io << "  [*] --> " << p << '\n' }
          @transitions.each do |t|
            t.from.each { |f| t.to.each { |to| io << "  " << f << " --> " << to << " : " << t.name << '\n' } }
          end
        end
      end

      # Graphviz DOT.
      def to_dot : String
        String.build do |io|
          io << "digraph " << @name << " {\n  rankdir=LR; node [shape=circle, fontname=\"Helvetica\"];\n"
          @places.each { |p| io << "  \"" << p << "\"" << (@initial.includes?(p) ? " [style=bold]" : "") << ";\n" }
          @transitions.each do |t|
            t.from.each { |f| t.to.each { |to| io << "  \"" << f << "\" -> \"" << to << "\" [label=\"" << t.name << "\"];\n" } }
          end
          io << "}\n"
        end
      end

      # Self contained SVG (layered layout by distance from the initial places).
      def to_svg : String
        depth = {} of String => Int32
        queue = Deque(String).new
        @initial.each { |p| depth[p] = 0; queue << p }
        while p = queue.shift?
          @transitions.select(&.from.includes?(p)).each do |t|
            t.to.each { |n| unless depth.has_key?(n); depth[n] = depth[p] + 1; queue << n; end }
          end
        end
        @places.each { |p| depth[p] ||= (depth.values.max? || 0) + 1 }
        columns = depth.group_by { |_, d| d }.transform_values(&.map(&.[0]))
        pos = {} of String => {Int32, Int32}
        columns.each { |d, names| names.each_with_index { |n, i| pos[n] = {60 + d * 190, 50 + i * 90} } }
        width = (columns.keys.max? || 0) * 190 + 160
        height = (columns.values.map(&.size).max? || 1) * 90 + 30
        String.build do |io|
          io << %(<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 #{width} #{height}" style="max-width:100%;font:12px ui-monospace,monospace">)
          io << %(<defs><marker id="arr-#{@name}" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="7" markerHeight="7" orient="auto"><path d="M0 0L10 5L0 10z" fill="#5d8fb8"/></marker></defs>)
          @transitions.each do |t|
            t.from.each do |f|
              t.to.each do |to|
                x1, y1 = pos[f]
                x2, y2 = pos[to]
                mx, my = (x1 + x2) // 2, (y1 + y2) // 2 - (y1 == y2 ? 18 : 0)
                io << %(<path d="M#{x1 + 34} #{y1} Q#{mx} #{my - 20} #{x2 - 36} #{y2}" fill="none" stroke="#5d8fb8" stroke-width="1.4" marker-end="url(#arr-#{@name})"/>)
                io << %(<text x="#{mx}" y="#{my - 16}" fill="#e3bb74" text-anchor="middle">#{HTML.escape(t.name)}</text>)
              end
            end
          end
          pos.each do |place, (x, y)|
            initial = @initial.includes?(place)
            io << %(<circle cx="#{x}" cy="#{y}" r="34" fill="#131620" stroke="#{initial ? "#a6dcff" : "#262b3b"}" stroke-width="#{initial ? 2 : 1.2}"/>)
            io << %(<text x="#{x}" y="#{y + 4}" fill="#ecebf5" text-anchor="middle">#{HTML.escape(place)}</text>)
          end
          io << "</svg>"
        end
      end
    end

    # Runtime for a definition.
    class Machine
      getter definition : Definition

      def initialize(@definition : Definition)
      end

      def marking(subject : Model) : Array(String)
        raw = subject.read_attribute(@definition.marking_property)
        value = raw.to_s
        list = if value.empty?
                 [] of String
               elsif value.starts_with?('[')
                 Array(String).from_json(value)
               else
                 value.split(',').map(&.strip).reject(&.empty?)
               end
        list.empty? ? @definition.initial : list
      end

      def enabled_transitions(subject : Model, user : Auth::Authenticatable? = nil) : Array(String)
        @definition.transitions.select { |t| enabled?(t, subject, user) }.map(&.name).uniq
      end

      def can?(subject : Model, transition : String, user : Auth::Authenticatable? = nil) : Bool
        @definition.transitions.any? { |t| t.name == transition && enabled?(t, subject, user) }
      end

      # Why a transition is blocked (empty when it can be applied).
      def blockers(subject : Model, transition : String, user : Auth::Authenticatable? = nil) : Array(String)
        candidates = @definition.transitions.select { |t| t.name == transition }
        return ["Unknown transition '#{transition}'"] if candidates.empty?
        current = marking(subject)
        reasons = [] of String
        candidates.each do |t|
          missing = t.from - current
          reasons << "Subject is not in place(s) #{missing.join(", ")}" unless missing.empty?
          if missing.empty?
            event = TransitionEvent.new(@definition.name, t, subject, user, current)
            run_guard(t, event)
            reasons << (event.block_reason || "Blocked by guard") if event.blocked?
          end
        end
        reasons
      end

      # Applies a transition, updates the marking property and saves the model.
      def apply(subject : Model, transition : String, user : Auth::Authenticatable? = nil, save : Bool = true) : Array(String)
        t = @definition.transitions.find { |tr| tr.name == transition && enabled?(tr, subject, user) }
        raise NotEnabled.new("Transition '#{transition}' is not enabled for #{subject.class.name} in workflow '#{@definition.name}': #{blockers(subject, transition, user).join("; ")}") unless t
        from = marking(subject)
        event = TransitionEvent.new(@definition.name, t, subject, user, from)
        Workflow.fire(@definition.name, Phase::Leave, t.from, event)
        Workflow.fire(@definition.name, Phase::Transition, [t.name], event)
        new_marking = @definition.state_machine? ? t.to.dup : ((from - t.from) + t.to).uniq
        Workflow.fire(@definition.name, Phase::Enter, t.to, event)
        stored = @definition.state_machine? ? new_marking.first : new_marking.to_json
        subject.write_attribute(@definition.marking_property, stored)
        subject.save! if save
        Workflow.fire(@definition.name, Phase::Entered, t.to, event)
        Workflow.fire(@definition.name, Phase::Completed, [t.name], event)
        Events.dispatch(Transitioned.new(@definition.name, t.name, from, new_marking, subject.class.name, subject.read_attribute(subject.__primary_key_name).to_s))
        new_marking
      end

      private def enabled?(t : Transition, subject : Model, user : Auth::Authenticatable?) : Bool
        current = marking(subject)
        return false unless t.from.all? { |p| current.includes?(p) }
        event = TransitionEvent.new(@definition.name, t, subject, user, current)
        run_guard(t, event)
        !event.blocked?
      end

      private def run_guard(t : Transition, event : TransitionEvent) : Nil
        if name = t.guard
          if guard = Workflow.guards["#{@definition.name}:#{name}"]?
            event.block("Guard '#{name}' refused") unless guard.call(event.subject, event.user)
          elsif Gate.defined?(name)
            event.block("Ability '#{name}' denied") unless Authorization.allowed?(event.user, name)
          end
        end
        Workflow.fire(@definition.name, Phase::Guard, [t.name], event)
      end
    end

    @@definitions = {} of String => Definition
    @@guards = {} of String => Proc(Model, Auth::Authenticatable?, Bool)
    @@listeners = {} of String => Array(Proc(TransitionEvent, Nil))
    @@loaded = false

    def self.definitions : Hash(String, Definition)
      load_config unless @@loaded
      @@definitions
    end

    def self.guards : Hash(String, Proc(Model, Auth::Authenticatable?, Bool))
      @@guards
    end

    # Defines a workflow in Crystal.
    def self.define(name : String, type : String = "state_machine", & : Definition ->) : Definition
      definition = Definition.new(name, type)
      yield definition
      definition.initial = [definition.places.first] if definition.initial.empty? && !definition.places.empty?
      @@definitions[name] = definition
    end

    def self.get(name : String) : Machine
      Machine.new(definitions[name]? || raise Silth::Error.new("Unknown workflow '#{name}'"))
    end

    def self.guard(workflow : String, name : String, &block : Model, Auth::Authenticatable? -> Bool) : Nil
      @@guards["#{workflow}:#{name}"] = block
    end

    # Listens to a phase, optionally for one place or transition name.
    def self.on(workflow : String, phase : Symbol | Phase, target : String? = nil, &block : TransitionEvent -> _) : Nil
      p = phase.is_a?(Phase) ? phase : Phase.parse(phase.to_s)
      key = "#{workflow}:#{p}:#{target || "*"}"
      (@@listeners[key] ||= [] of Proc(TransitionEvent, Nil)) << ->(e : TransitionEvent) { block.call(e); nil }
    end

    # :nodoc:
    def self.fire(workflow : String, phase : Phase, targets : Array(String), event : TransitionEvent) : Nil
      (targets + ["*"]).each do |target|
        @@listeners["#{workflow}:#{phase}:#{target}"]?.try &.each(&.call(event))
      end
    end

    def self.load_config(path : String = "config/workflows.yml") : Nil
      @@loaded = true
      return unless File.exists?(path)
      yaml = Config.parse(File.read(path), Silth.env, path)
      yaml.as_h.each do |name, spec|
        d = Definition.new(name.as_s, spec["type"]?.try(&.as_s) || "state_machine")
        d.marking_property = spec["marking_property"]?.try(&.as_s) || "status"
        d.supports = spec["supports"]?.try(&.as_a.map(&.as_s)) || [] of String
        (spec["places"]?.try(&.as_a) || [] of YAML::Any).each { |p| d.place(p.as_s) }
        (spec["transitions"]?.try(&.as_h) || {} of YAML::Any => YAML::Any).each do |tname, t|
          to_list = t["to"].as_a? ? t["to"].as_a.map(&.as_s) : [t["to"].as_s]
          from_list = t["from"].as_a? ? t["from"].as_a.map(&.as_s) : [t["from"].as_s]
          d.transition(tname.as_s, from_list, to_list, t["guard"]?.try(&.as_s))
        end
        initial = spec["initial_marking"]?
        d.initial = initial ? (initial.as_a? ? initial.as_a.map(&.as_s) : [initial.as_s]) : (d.places.first? ? [d.places.first] : [] of String)
        @@definitions[d.name] = d
      end
    end
  end
end

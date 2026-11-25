module Silth
  # Code generators used by `silth generate <type> <Name> [fields…]`.
  module Generators
    # `title:string`, `body:text?` (nullable), `user:references`, `embedding:vector:1536`, `price:decimal`.
    struct Field
      getter name : String
      getter type : String
      getter nullable : Bool
      getter option : String?

      def initialize(spec : String)
        parts = spec.split(':')
        @name = Inflector.underscore(parts[0])
        raw = parts[1]? || "string"
        @nullable = raw.ends_with?('?')
        @type = raw.rchop('?').downcase
        @option = parts[2]?
      end

      def reference? : Bool
        @type.in?("references", "belongs_to", "ref")
      end

      def column_name : String
        reference? ? "#{@name}_id" : @name
      end

      def crystal_type : String
        base = case @type
               when "text", "string", "uuid", "citext", "email", "url" then "String"
               when "integer", "int"                                  then "Int32"
               when "bigint"                                          then "Int64"
               when "float", "decimal", "number"                      then "Float64"
               when "bool", "boolean"                                 then "Bool"
               when "datetime", "timestamp", "date", "time"          then "Time"
               when "json", "jsonb"                                   then "JSON::Any"
               when "vector"                                          then "Array(Float32)"
               when "references", "belongs_to", "ref"                 then "Int64"
               else                                                        "String"
               end
        nilable = @nullable || base.in?("Time", "JSON::Any", "Array(Float32)")
        base == "Bool" ? "Bool = false" : (nilable ? "#{base}?" : base)
      end

      def migration_line : String
        case @type
        when "references", "belongs_to", "ref" then "t.references :#{@name}#{@nullable ? ", null: true, on_delete: :nullify" : ""}"
        when "text"                            then "t.text :#{@name}#{null_opt}"
        when "integer", "int"                  then "t.integer :#{@name}#{null_opt}"
        when "bigint"                          then "t.bigint :#{@name}#{null_opt}"
        when "float", "number"                 then "t.float :#{@name}#{null_opt}"
        when "decimal"                         then "t.decimal :#{@name}, precision: 10, scale: 2#{null_opt}"
        when "bool", "boolean"                 then "t.boolean :#{@name}, null: false, default: false"
        when "datetime", "timestamp"           then "t.timestamp :#{@name}"
        when "date"                            then "t.date :#{@name}"
        when "time"                            then "t.time :#{@name}"
        when "json", "jsonb"                   then "t.jsonb :#{@name}"
        when "uuid"                            then "t.uuid :#{@name}#{null_opt}"
        when "vector"                          then "t.vector :#{@name}, #{@option || 1536}"
        else                                        "t.string :#{@name}#{null_opt}"
        end
      end

      private def null_opt : String
        @nullable ? "" : ", null: false"
      end

      def form_input : String
        case @type
        when "text"                      then "f.text_area :#{column_name}"
        when "integer", "int", "bigint", "references", "belongs_to", "ref" then "f.number_field :#{column_name}"
        when "float", "decimal", "number" then "f.number_field :#{column_name}, step: \"any\""
        when "bool", "boolean"           then "f.check_box :#{column_name}"
        when "datetime", "timestamp"     then "f.datetime_field :#{column_name}"
        when "date"                      then "f.date_field :#{column_name}"
        when "email"                     then "f.email_field :#{column_name}"
        when "url"                       then "f.url_field :#{column_name}"
        else                                  "f.text_field :#{column_name}"
        end
      end

      def displayable? : Bool
        !@type.in?("vector", "json", "jsonb")
      end

      def string_like? : Bool
        @type.in?("string", "text", "email", "url", "citext")
      end
    end

    class Base
      getter created = [] of String
      property force = false
      property root = "."
      property output : IO = STDOUT

      def create(path : String, content : String) : Nil
        full = File.join(@root, path)
        if File.exists?(full) && !@force
          @output.puts "  #{"skip".colorize(:yellow)}    #{path} (exists)"
          return
        end
        Dir.mkdir_p(File.dirname(full))
        File.write(full, content)
        @created << path
        @output.puts "  #{"create".colorize(:green)}  #{path}"
      end

      # Inserts `content` before the last `end` of `path` (routes, …).
      def inject_before_last_end(path : String, content : String) : Nil
        full = File.join(@root, path)
        return unless File.exists?(full)
        text = File.read(full)
        return if text.includes?(content.strip)
        idx = text.rindex("\nend") || return
        File.write(full, text.insert(idx, "\n" + content.rstrip))
        @output.puts "  #{"update".colorize(:cyan)}  #{path}"
      end

      def timestamp : String
        Time.utc.to_s("%Y%m%d%H%M%S")
      end

      def migration_version(ts : String) : String
        "#{ts[0, 4]}_#{ts[4, 2]}_#{ts[6, 2]}_#{ts[8, 6]}"
      end
    end

    class Scaffold < Base
      getter name : String
      getter fields : Array(Field)

      def initialize(name : String, field_specs : Array(String))
        @name = Inflector.camelize(Inflector.singularize(Inflector.underscore(name)))
        @fields = field_specs.map { |s| Field.new(s) }
      end

      def singular : String
        Inflector.underscore(@name.split("::").last)
      end

      def plural : String
        Inflector.pluralize(singular)
      end

      def table : String
        Inflector.tableize(@name)
      end

      def controller : String
        "#{Inflector.camelize(plural)}Controller"
      end

      # --- model & migration -------------------------------------------------

      def model : Nil
        refs = @fields.select(&.reference?)
        cols = @fields.reject(&.reference?)
        validations = cols.select { |f| !f.nullable && f.string_like? }.map { |f| "  validates #{f.name}, presence: true" }
        search = cols.select(&.string_like?).map { |f| ":#{f.name}" }
        create "src/models/#{singular}.cr", <<-CR
          class #{@name} < ApplicationModel
            primary_key
          #{cols.map { |f| "  column #{f.name} : #{f.crystal_type}" }.join('\n')}
          #{refs.map { |f| "  belongs_to #{f.name} : #{Inflector.camelize(f.name)}#{f.nullable ? ", optional: true" : ""}" }.join('\n')}
            timestamps

          #{validations.join('\n')}

            # scope recent { order(created_at: :desc) }
          #{search.empty? ? "" : "\n  # Full-text search across text columns:\n  scope matching { |q| search([#{search.join(", ")}], q) }"}
          end
          CR
        migration("Create#{Inflector.camelize(table)}", <<-CR)
              create_table :#{table} do |t|
                t.id
          #{@fields.map { |f| "      #{f.migration_line}" }.join('\n')}
                t.timestamps
              end
          CR
      end

      # Writes a migration: `def change` when *down* is nil (reversible body),
      # `up`/`down` otherwise.
      def migration(class_name : String, body : String, down : String? = nil) : Nil
        ts = timestamp
        methods = if down
                    "  def up\n#{body.rstrip}\n  end\n\n  def down\n    #{down}\n  end"
                  else
                    "  def change\n#{body.rstrip}\n  end"
                  end
        create "db/migrations/#{ts}_#{Inflector.underscore(class_name)}.cr", <<-CR
          class #{class_name} < Silth::Migration
            version #{migration_version(ts)}

          #{methods}
          end
          CR
      end

      # --- web scaffold ----------------------------------------------------------

      def web : Nil
        model
        permitted = @fields.map { |f| ":#{f.column_name}" }.join(", ")
        create "src/controllers/#{plural}_controller.cr", <<-CR
          class #{controller} < ApplicationController
            before_action :load_#{singular}, only: [:show, :edit, :update, :destroy]

            def index
              #{plural} = #{@name}.latest.paginate(params.int("page", 1), 20)
              render "#{plural}/index", #{plural}: #{plural}
            end

            def show
              render "#{plural}/show", #{singular}: @#{singular}.not_nil!
            end

            def new
              render "#{plural}/new", #{singular}: #{@name}.new
            end

            def create
              #{singular} = #{@name}.new.assign(params.permit(#{permitted}, from: :#{singular}))
              if #{singular}.save
                redirect route("#{plural}.show", id: #{singular}.id), notice: t("flash.created", default: "#{Inflector.humanize(singular)} created.")
              else
                render "#{plural}/new", status: 422, #{singular}: #{singular}
              end
            end

            def edit
              render "#{plural}/edit", #{singular}: @#{singular}.not_nil!
            end

            def update
              #{singular} = @#{singular}.not_nil!
              if #{singular}.assign(params.permit(#{permitted}, from: :#{singular})).save
                redirect route("#{plural}.show", id: #{singular}.id), notice: t("flash.updated", default: "#{Inflector.humanize(singular)} updated.")
              else
                render "#{plural}/edit", status: 422, #{singular}: #{singular}
              end
            end

            def destroy
              @#{singular}.not_nil!.destroy
              redirect route("#{plural}.index"), notice: t("flash.deleted", default: "#{Inflector.humanize(singular)} deleted.")
            end

            private def load_#{singular}
              @#{singular} = #{@name}.find(params["id"])
            end

            @#{singular} : #{@name}?
          end
          CR
        shown = @fields.select(&.displayable?).first(4)
        create "src/views/#{plural}/index.html.ecr", <<-ECR
          <% content_for :title, "#{Inflector.titleize(plural)}" %>
          <header class="page-header">
            <h1>#{Inflector.titleize(plural)}</h1>
            <%= link_to "New #{Inflector.humanize(singular).downcase}", route("#{plural}.new"), class: "btn btn-primary" %>
          </header>

          <% if #{plural}.empty? %>
            <div class="empty-state">
              <p>No #{Inflector.humanize(plural).downcase} yet.</p>
              <%= link_to "Create the first one", route("#{plural}.new"), class: "btn" %>
            </div>
          <% else %>
            <div class="card">
              <table class="table">
                <thead><tr>#{shown.map { |f| "<th>#{Inflector.humanize(f.column_name)}</th>" }.join}<th></th></tr></thead>
                <tbody>
                  <% #{plural}.each do |#{singular}| %>
                    <tr>
          #{shown.map { |f| "              <td><%= #{singular}.#{f.column_name}#{f.nullable || f.crystal_type.ends_with?('?') ? "?" : ""} %></td>" }.join('\n')}
                      <td class="actions"><%= link_to "Show", route("#{plural}.show", id: #{singular}.id) %></td>
                    </tr>
                  <% end %>
                </tbody>
              </table>
            </div>
            <%= paginate #{plural} %>
          <% end %>
          ECR
        create "src/views/#{plural}/show.html.ecr", <<-ECR
          <% content_for :title, "#{Inflector.humanize(singular)} \#{#{singular}.id}" %>
          <header class="page-header">
            <h1>#{Inflector.humanize(singular)} #<%= #{singular}.id %></h1>
            <div class="actions">
              <%= link_to "Edit", route("#{plural}.edit", id: #{singular}.id), class: "btn" %>
              <%= button_to "Delete", route("#{plural}.destroy", id: #{singular}.id), method: "delete", confirm: "Delete this #{Inflector.humanize(singular).downcase}?", class: "btn btn-danger" %>
            </div>
          </header>
          <dl class="card details">
          #{@fields.select(&.displayable?).map { |f| "  <dt>#{Inflector.humanize(f.column_name)}</dt><dd><%= #{singular}.#{f.column_name}#{f.nullable || f.crystal_type.ends_with?('?') ? "?" : ""} %></dd>" }.join('\n')}
          </dl>
          <p><%= link_to "← Back to #{Inflector.humanize(plural).downcase}", route("#{plural}.index") %></p>
          ECR
        create "src/views/#{plural}/_form.html.ecr", <<-ECR
          <% form_with url: url, method: method, model: #{singular}, class: "form card" do |f| %>
          #{@fields.select(&.displayable?).map { |f| "  <div class=\"field\">\n    <%= f.label :#{f.column_name} %>\n    <%= #{f.form_input} %>\n    <%= f.errors_for :#{f.column_name} %>\n  </div>" }.join('\n')}
            <div class="form-actions"><%= f.submit "Save", class: "btn btn-primary" %></div>
          <% end %>
          ECR
        create "src/views/#{plural}/new.html.ecr", <<-ECR
          <% content_for :title, "New #{Inflector.humanize(singular).downcase}" %>
          <h1>New #{Inflector.humanize(singular).downcase}</h1>
          <%= partial "#{plural}/_form", #{singular}: #{singular}, url: route("#{plural}.create"), method: "post" %>
          <p><%= link_to "← Back", route("#{plural}.index") %></p>
          ECR
        create "src/views/#{plural}/edit.html.ecr", <<-ECR
          <% content_for :title, "Edit #{Inflector.humanize(singular).downcase}" %>
          <h1>Edit #{Inflector.humanize(singular).downcase}</h1>
          <%= partial "#{plural}/_form", #{singular}: #{singular}, url: route("#{plural}.update", id: #{singular}.id), method: "patch" %>
          <p><%= link_to "← Back", route("#{plural}.show", id: #{singular}.id) %></p>
          ECR
        policy
        factory
        create "spec/requests/#{plural}_spec.cr", <<-CR
          require "../spec_helper"

          describe #{controller} do
            it "lists #{plural}" do
              #{@name}Factory.create
              response = client.get("/#{plural}")
              response.should be_ok
            end

            it "creates a #{singular}" do
              response = client.post("/#{plural}", form: {#{@fields.reject(&.reference?).select(&.string_like?).first(1).map { |f| %("#{singular}[#{f.column_name}]" => "Hello") }.join}})
              response.status.should be < 500
            end
          end
          CR
        inject_before_last_end("config/routes.cr", "  resources \"#{plural}\", #{controller}\n")
      end

      # --- JSON API scaffold ------------------------------------------------------

      def api : Nil
        model
        request_fields = @fields.select(&.displayable?).map do |f|
          type = f.crystal_type.split(" = ").first.rchop('?')
          type = "Int64" if f.reference?
          opts = f.string_like? && !f.nullable ? ", min: 1" : ""
          "  field #{f.column_name} : #{type}#{f.nullable || f.type.in?("bool", "boolean") ? "?" : ""}#{opts}"
        end
        create "src/requests/#{singular}_request.cr", <<-CR
          # Validated input for #{@name} create/update (documented in OpenAPI).
          class #{@name}Request < Silth::FormRequest
          #{request_fields.join('\n')}
          end
          CR
        assigns = @fields.select(&.displayable?).map { |f| "      #{singular}.#{f.column_name} = data.#{f.column_name}#{f.nullable || f.type.in?("bool", "boolean") ? " unless data.#{f.column_name}.nil?" : ""}" }.join('\n')
        create "src/controllers/api/#{plural}_controller.cr", <<-CR
          module Api
            class #{controller} < ApiController
              @[Silth::API(summary: "List #{plural}", tags: ["#{Inflector.titleize(plural)}"], response: Silth::DB::Page(#{@name}))]
              def index
                json #{@name}.latest.paginate(params.int("page", 1), params.int("per_page", 20).clamp(1, 100))
              end

              @[Silth::API(summary: "Show a #{singular}", tags: ["#{Inflector.titleize(plural)}"], response: #{@name})]
              def show
                json #{@name}.find(params["id"])
              end

              @[Silth::API(summary: "Create a #{singular}", tags: ["#{Inflector.titleize(plural)}"], body: #{@name}Request, response: #{@name}, status: 201)]
              def create
                data = validate!(#{@name}Request)
                #{singular} = #{@name}.new
          #{assigns.gsub("      ", "      ")}
                #{singular}.save!
                json #{singular}, 201
              end

              @[Silth::API(summary: "Update a #{singular}", tags: ["#{Inflector.titleize(plural)}"], body: #{@name}Request, response: #{@name})]
              def update
                data = validate!(#{@name}Request)
                #{singular} = #{@name}.find(params["id"])
          #{assigns}
                #{singular}.save!
                json #{singular}
              end

              @[Silth::API(summary: "Delete a #{singular}", tags: ["#{Inflector.titleize(plural)}"], status: 204)]
              def destroy
                #{@name}.find(params["id"]).destroy
                no_content
              end
            end
          end
          CR
        factory
        inject_before_last_end("config/routes.cr", "  api do\n    resources \"#{plural}\", Api::#{controller}, except: [:new, :edit]\n  end\n")
      end

      def policy : Nil
        create "src/policies/#{singular}_policy.cr", <<-CR
          class #{@name}Policy < Silth::Policy
            def view?(user : User?, #{singular} : #{@name}) : Bool
              true
            end

            def update?(user : User, #{singular} : #{@name}) : Bool
              true
            end

            def destroy?(user : User, #{singular} : #{@name}) : Bool
              true
            end
          end
          CR
      end

      def factory : Nil
        attrs = @fields.reject(&.reference?).select(&.displayable?).map do |f|
          value = case f.type
                  when "text"                             then "fake.paragraph"
                  when "integer", "int"                   then "fake.number(1, 100)"
                  when "bigint"                           then "fake.number(1, 100).to_i64"
                  when "float", "decimal", "number"       then "fake.price"
                  when "bool", "boolean"                  then "fake.bool"
                  when "datetime", "timestamp", "date"    then "fake.date"
                  when "email"                            then "fake.email"
                  when "url"                              then "fake.url"
                  else                                         f.name.includes?("name") ? "fake.name" : (f.name.includes?("email") ? "fake.email" : "fake.title")
                  end
          "#{f.column_name}: #{value}"
        end
        create "spec/factories/#{singular}_factory.cr", <<-CR
          class #{@name}Factory < Silth::Factory(#{@name})
            def definition : #{@name}
              #{@name}.new(#{attrs.join(", ")})
            end
          end
          CR
      end
    end

    # --- single file generators --------------------------------------------------

    def self.generate(kind : String, name : String, args : Array(String), force : Bool = false, output : IO = STDOUT) : Array(String)
      g = Scaffold.new(name, args)
      g.force = force
      g.output = output
      class_name = Inflector.camelize(Inflector.underscore(name))
      file = Inflector.underscore(name.split("::").last)
      case kind
      when "scaffold", "resource" then g.web
      when "api"                  then g.api
      when "model"
        g.model
        g.factory
      when "migration"
        body = if (m = file.match(/^add_(\w+)_to_(\w+)$/)) && !args.empty?
                 args.map { |a| f = Field.new(a); "    add_column :#{m[2]}, :#{f.column_name}, :#{f.type == "references" ? "bigint" : f.type}#{f.nullable ? "" : ", null: true"}" }.join('\n')
               elsif m = file.match(/^create_(\w+)$/)
                 "    create_table :#{m[1]} do |t|\n      t.id\n#{args.map { |a| "      #{Field.new(a).migration_line}" }.join('\n')}\n      t.timestamps\n    end"
               else
                 "    # execute \"…\""
               end
        reversible = file.matches?(/^create_\w+$/) || (file.matches?(/^add_\w+_to_\w+$/) && !args.empty?)
        g.migration(class_name, body, reversible ? nil : "# reverse the change")
      when "controller"
        actions = args.empty? ? ["index"] : args
        base = class_name.sub(/Controller$/, "")
        dir = Inflector.underscore(base)
        g.create "src/controllers/#{dir}_controller.cr", <<-CR
          class #{base}Controller < ApplicationController
          #{actions.map { |a| "  def #{a}\n    render \"#{dir}/#{a}\"\n  end" }.join("\n\n")}
          end
          CR
        actions.each { |a| g.create "src/views/#{dir}/#{a}.html.ecr", %(<h1>#{base}##{a}</h1>\n<p>Find me in src/views/#{dir}/#{a}.html.ecr</p>\n) }
        actions.each { |a| g.inject_before_last_end("config/routes.cr", "  get \"/#{dir}#{a == "index" ? "" : "/#{a}"}\", #{base}Controller, :#{a}\n") }
      when "component"
        base = class_name.sub(/Component$/, "")
        props = args.map { |a| f = Field.new(a); "  prop #{f.name} : #{f.crystal_type}" }
        g.create "src/components/#{Inflector.underscore(base)}_component.cr", "class #{base}Component < Silth::Component\n#{props.join('\n')}\n  template \"components/#{Inflector.underscore(base)}\"\nend\n"
        g.create "src/views/components/#{Inflector.underscore(base)}.html.ecr", %(<div class="#{Inflector.dasherize(base)}">\n  <%= yield_slot %>\n</div>\n)
      when "live"
        base = class_name.sub(/Component$/, "")
        g.create "src/components/#{Inflector.underscore(base)}_component.cr", <<-CR
          class #{base}Component < Silth::LiveComponent
            prop count : Int32 = 0
            template "components/#{Inflector.underscore(base)}"

            action def increment
              @count = count + 1
            end
          end
          CR
        g.create "src/views/components/#{Inflector.underscore(base)}.html.ecr", <<-ECR
          <div class="live-#{Inflector.dasherize(base)}">
            <p>Count: <strong><%= count %></strong></p>
            <button class="btn" silth-click="increment">+1</button>
          </div>
          ECR
      when "job"
        base = class_name.sub(/Job$/, "")
        g.create "src/jobs/#{Inflector.underscore(base)}_job.cr", <<-CR
          class #{base}Job < Silth::Job
            queue "default"
            retries 3

            # getter user_id : Int64
            # def initialize(@user_id); end

            def perform : Nil
              # …
            end
          end
          CR
      when "mail", "mailer"
        base = class_name.sub(/Mail(er)?$/, "")
        tpl = Inflector.underscore(base)
        g.create "src/mails/#{tpl}_mail.cr", <<-CR
          class #{base}Mail < Silth::Mail
            def initialize(@email : String, @name : String)
            end

            def build : Nil
              to @email, @name
              subject "#{Inflector.humanize(tpl)}"
              markdown "mails/#{tpl}", name: @name
            end
          end
          CR
        g.create "src/views/mails/#{tpl}.md.ecr", <<-MD
          # Hello <%= name %>

          This email was generated by Silth.

          <%= button "Open the app", Silth.config.string("app.url", "http://localhost:3000") %>

          Thanks,
          The team
          MD
        g.create "src/mails/previews/#{tpl}_mail_preview.cr", <<-CR
          # Shown in the profiler: /_silth/profiler/mails
          class #{base}MailPreview < Silth::MailPreview
            def #{tpl} : Silth::Mail
              #{base}Mail.new("ada@example.com", "Ada")
            end
          end
          CR
      when "notification"
        base = class_name
        g.create "src/notifications/#{Inflector.underscore(base)}.cr", <<-CR
          class #{base} < Silth::Notification
            def via(notifiable) : Array(Symbol)
              [:database, :broadcast]
            end

            def to_data(notifiable) : Hash(String, String)
              {"message" => "#{Inflector.humanize(Inflector.underscore(base))}"}
            end
          end
          CR
      when "event"
        g.create "src/events/#{file}.cr", "class #{class_name} < Silth::Event\n  # getter user_id : Int64\n  # def initialize(@user_id); end\nend\n"
      when "listener"
        event = args.first? || "SomeEvent"
        g.create "src/listeners/#{file}.cr", "class #{class_name} < Silth::Listener(#{event})\n  def handle(event : #{event}) : Nil\n  end\nend\n"
      when "policy"
        g.policy
      when "factory"
        g.factory
      when "request"
        g.create "src/requests/#{file}.cr", "class #{class_name} < Silth::FormRequest\n#{args.map { |a| f = Field.new(a); "  field #{f.column_name} : #{f.crystal_type.split(" = ").first}" }.join('\n')}\nend\n"
      when "command"
        base = class_name.sub(/Command$/, "")
        g.create "src/commands/#{Inflector.underscore(base)}_command.cr", <<-CR
          class #{base}Command < Silth::Command
            command "#{Inflector.dasherize(base).tr("-", ":")}", "Describe what it does"
            option dry_run : Bool = false, "Do not change anything"

            def run : Nil
              info "Running #{base}…"
              success "Done"
            end
          end
          CR
      when "middleware"
        g.create "src/middleware/#{file}.cr", "class #{class_name} < Silth::Middleware\n  def call(ctx, chain)\n    chain.next(ctx)\n  end\nend\n"
      when "channel"
        base = class_name.sub(/Channel$/, "")
        g.create "src/channels/#{Inflector.underscore(base)}_channel.cr", <<-CR
          class #{base}Channel < Silth::Channel
            topic "#{Inflector.underscore(base)}:*"

            def join(payload : JSON::Any) : Bool
              true
            end

            def handle_in(event : String, payload : JSON::Any) : Nil
              broadcast(event, payload)
            end
          end
          CR
      when "seeder"
        g.create "db/seeders/#{file}.cr", "class #{class_name} < Silth::Seeder\n  def run\n  end\nend\n"
      when "auth"
        Auth.new(g).run
      when "billing"
        g.migration("CreateSubscriptions", <<-CR, "drop_table :subscriptions\n    remove_column :users, :stripe_id\n    remove_column :users, :pm_type\n    remove_column :users, :pm_last_four\n    remove_column :users, :trial_ends_at")
              create_table :subscriptions do |t|
                t.id
                t.string :billable_type, null: false
                t.string :billable_id, null: false, index: true
                t.string :type, null: false
                t.string :stripe_id, null: false, unique: true
                t.string :stripe_status, null: false
                t.string :stripe_price
                t.integer :quantity
                t.timestamp :trial_ends_at
                t.timestamp :ends_at
                t.timestamps
              end
              add_column :users, :stripe_id, :string, index: true
              add_column :users, :pm_type, :string
              add_column :users, :pm_last_four, :string, limit: 4
              add_column :users, :trial_ends_at, :timestamp
          CR
      when "notifications"
        g.migration("CreateSilthNotifications", <<-CR, "drop_table :silth_notifications")
              create_table :silth_notifications do |t|
                t.id :uuid
                t.string :notifiable_type, null: false
                t.string :notifiable_id, null: false, index: true
                t.string :type, null: false
                t.json :data
                t.timestamp :read_at
                t.timestamps
              end
          CR
      when "workflow"
        g.create "config/workflows.yml", <<-YAML
          #{file}:
            type: state_machine
            marking_property: status
            initial_marking: draft
            places: [draft, review, published, rejected]
            transitions:
              submit:  { from: draft, to: review }
              publish: { from: review, to: published }
              reject:  { from: review, to: rejected }
          YAML
      else
        raise Command::Error.new("Unknown generator '#{kind}'. Try: scaffold api model migration controller component live job mail notification event listener policy factory request command middleware channel seeder auth billing notifications workflow")
      end
      g.created
    end

    # Complete authentication scaffold.
    class Auth
      def initialize(@g : Scaffold)
      end

      def run : Nil
        g = @g
        g.create "src/models/user.cr", <<-CR
          class User < ApplicationModel
            include Silth::Auth::Authenticatable
            include Silth::Notifiable

            primary_key
            column name : String
            column email : String
            column password_digest : String, hidden: true
            column email_verified_at : Time?
            column admin : Bool = false
            timestamps

            property password_confirmation : String? = nil

            validates name, presence: true, length: {max: 120}
            validates email, presence: true, email: true, uniqueness: true

            def before_save
              self.email = email.strip.downcase
            end
          end
          CR
        ts = g.timestamp
        g.create "db/migrations/#{ts}_create_users.cr", <<-CR
          class CreateUsers < Silth::Migration
            version #{g.migration_version(ts)}

            def up
              create_table :users do |t|
                t.id
                t.string :name, null: false
                t.string :email, null: false, unique: true
                t.string :password_digest, null: false
                t.timestamp :email_verified_at
                t.boolean :admin, null: false, default: false
                t.timestamps
              end
              create_table :silth_access_tokens do |t|
                t.id
                t.string :tokenable_type, null: false
                t.string :tokenable_id, null: false, index: true
                t.string :name, null: false
                t.string :token_hash, null: false, unique: true
                t.text :abilities
                t.timestamp :last_used_at
                t.timestamp :expires_at
                t.timestamps
              end
            end

            def down
              drop_table :silth_access_tokens
              drop_table :users
            end
          end
          CR
        g.create "src/controllers/auth/sessions_controller.cr", <<-CR
          module Auth
            class SessionsController < ApplicationController
              def new
                render "auth/login"
              end

              def create
                if auth.attempt(params["email"]?, params["password"]?, remember: params.bool("remember"))
                  redirect session.pull("_intended") || "/", notice: t("auth.welcome_back", default: "Welcome back!")
                else
                  flash.now["alert"] = t("auth.failed", default: "These credentials do not match our records.")
                  render "auth/login", status: 422
                end
              end

              def destroy
                auth.logout
                redirect "/", notice: t("auth.logged_out", default: "See you soon.")
              end
            end
          end
          CR
        g.create "src/controllers/auth/registrations_controller.cr", <<-CR
          module Auth
            class RegistrationsController < ApplicationController
              def new
                render "auth/register", user: User.new
              end

              def create
                user = User.new(name: params["name"]?, email: params["email"]?)
                password = params["password"]?.to_s
                if password.size < 8
                  user.errors.add("password", t("auth.password_too_short", default: "must be at least 8 characters"))
                  return render "auth/register", status: 422, user: user
                end
                user.password = password
                if params["password_confirmation"]? == password && user.save
                  auth.login(user)
                  redirect "/", notice: t("auth.registered", default: "Your account is ready.")
                else
                  user.errors.add("password_confirmation", "doesn't match") unless params["password_confirmation"]? == password
                  render "auth/register", status: 422, user: user
                end
              end
            end
          end
          CR
        g.create "src/controllers/auth/passwords_controller.cr", <<-CR
          module Auth
            class PasswordsController < ApplicationController
              def new
                render "auth/forgot"
              end

              def create
                if user = User.find_by?(email: params["email"]?.to_s.strip.downcase)
                  token = Silth::Auth.password_reset_token(user)
                  PasswordResetMail.new(user, "\#{ctx.base_url}/password/reset/\#{token}").deliver_later
                end
                redirect "/login", notice: t("auth.reset_sent", default: "If that address exists, a reset link is on its way.")
              end

              def edit
                render "auth/reset", token: params["token"]
              end

              def update
                user = Silth::Auth.verify_password_reset(params["token"]).try(&.as?(User))
                return redirect("/password/forgot", alert: t("auth.reset_invalid", default: "This reset link is invalid or expired.")) unless user
                user.password = params["password"]
                user.save!
                auth.login(user)
                redirect "/", notice: t("auth.reset_done", default: "Password updated.")
              end
            end
          end
          CR
        g.create "src/mails/password_reset_mail.cr", <<-CR
          class PasswordResetMail < Silth::Mail
            def initialize(@user : User, @url : String)
            end

            def build : Nil
              to @user.email, @user.name
              subject "Reset your password"
              html render_to_string("mails/password_reset", layout: "layouts/mail", user: @user, url: @url)
            end
          end
          CR
        g.create "src/views/mails/password_reset.html.ecr", <<-ECR
          <h1>Hi <%= user.name %>,</h1>
          <p>Someone asked to reset your password. The link expires in one hour.</p>
          <p><a class="button" href="<%= url %>">Choose a new password</a></p>
          <p>If it wasn't you, ignore this email.</p>
          ECR
        auth_form = ->(title : String, body : String) do
          <<-ECR
            <% content_for :title, "#{title}" %>
            <div class="auth-card card">
              <h1>#{title}</h1>
              #{body}
            </div>
            ECR
        end
        g.create "src/views/auth/login.html.ecr", auth_form.call("Sign in", <<-ECR)
          <form method="post" action="/login" class="form">
              <%= csrf_field %>
              <div class="field"><label for="email">Email</label><input id="email" type="email" name="email" value="<%= params["email"]? %>" required autofocus autocomplete="username"></div>
              <div class="field"><label for="password">Password</label><input id="password" type="password" name="password" required autocomplete="current-password"></div>
              <label class="check"><input type="checkbox" name="remember" value="1"> Remember me</label>
              <button class="btn btn-primary btn-block">Sign in</button>
            </form>
            <p class="muted"><a href="/password/forgot">Forgot your password?</a> · <a href="/register">Create an account</a></p>
          ECR
        g.create "src/views/auth/register.html.ecr", auth_form.call("Create an account", <<-ECR)
          <% form_with url: "/register", model: user, scope: nil, class: "form" do |f| %>
              <div class="field"><%= f.label :name %><%= f.text_field :name, required: true %><%= f.errors_for :name %></div>
              <div class="field"><%= f.label :email %><%= f.email_field :email, required: true %><%= f.errors_for :email %></div>
              <div class="field"><label for="password">Password</label><input id="password" type="password" name="password" required minlength="8" autocomplete="new-password"><%= f.errors_for :password %></div>
              <div class="field"><label for="password_confirmation">Confirm password</label><input id="password_confirmation" type="password" name="password_confirmation" required><%= f.errors_for :password_confirmation %></div>
              <button class="btn btn-primary btn-block">Create account</button>
            <% end %>
            <p class="muted">Already registered? <a href="/login">Sign in</a></p>
          ECR
        g.create "src/views/auth/forgot.html.ecr", auth_form.call("Forgot password", <<-ECR)
          <form method="post" action="/password/forgot" class="form">
              <%= csrf_field %>
              <div class="field"><label for="email">Email</label><input id="email" type="email" name="email" required></div>
              <button class="btn btn-primary btn-block">Send reset link</button>
            </form>
          ECR
        g.create "src/views/auth/reset.html.ecr", auth_form.call("Choose a new password", <<-ECR)
          <form method="post" action="/password/reset/<%= token %>" class="form">
              <%= csrf_field %>
              <div class="field"><label for="password">New password</label><input id="password" type="password" name="password" minlength="8" required></div>
              <button class="btn btn-primary btn-block">Update password</button>
            </form>
          ECR
        g.inject_before_last_end("config/routes.cr", <<-CR)
            scope middleware: [:guest] do
              get "/login", Auth::SessionsController, :new, name: "login"
              post "/login", Auth::SessionsController, :create
              get "/register", Auth::RegistrationsController, :new, name: "register"
              post "/register", Auth::RegistrationsController, :create
              get "/password/forgot", Auth::PasswordsController, :new, name: "password.forgot"
              post "/password/forgot", Auth::PasswordsController, :create
              get "/password/reset/:token", Auth::PasswordsController, :edit, name: "password.reset"
              post "/password/reset/:token", Auth::PasswordsController, :update
            end
            delete "/logout", Auth::SessionsController, :destroy, name: "logout"
          CR
      end
    end
  end

  module Commands
    class Generate < Command
      command "generate", "Generate code (scaffold, api, model, migration, live, job…)"
      argument kind : String, "Generator: scaffold api model migration controller component live job mail notification event listener policy factory request command middleware channel seeder auth billing notifications workflow"
      argument name : String = "", "Class or resource name"
      option force : Bool = false, "Overwrite existing files", short: "f"

      def run : Nil
        raise Command::Error.new("Missing name for generator #{kind}") if name.empty? && !kind.in?("auth", "billing", "notifications")
        files = Generators.generate(kind, name.empty? ? kind : name, rest, force, stdout)
        line
        success "#{files.size} file(s) generated."
        if kind.in?("scaffold", "api", "model", "auth", "billing", "notifications") || kind == "migration"
          comment "  Next: silth db:migrate"
        end
      end
    end

    class G < Command
      command "g", "Alias of generate", hidden: true
      argument kind : String, "Generator"
      argument name : String = "", "Name"
      option force : Bool = false, "Overwrite existing files", short: "f"

      def run : Nil
        files = Generators.generate(kind, name.empty? ? kind : name, rest, force, stdout)
        success "#{files.size} file(s) generated."
      end
    end
  end
end

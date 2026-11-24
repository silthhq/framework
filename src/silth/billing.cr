module Silth
  # Stripe subscription billing (Laravel Cashier equivalent).
  #
  # ```
  # class User < Silth::Model
  #   include Silth::Auth::Authenticatable
  #   include Silth::Billing::Billable
  #   # columns added by `silth generate billing`: stripe_id, pm_type, pm_last_four, trial_ends_at
  # end
  #
  # url = user.checkout("price_123", success_url: "…/thanks", cancel_url: "…/pricing", trial_days: 14)
  # user.subscribed?                    # default subscription active / on trial / grace period
  # user.subscription.try(&.swap("price_pro"))
  # user.billing_portal_url(return_url: "…/account")
  # ```
  #
  # Webhooks: add `Silth::Billing::WebhookMiddleware` (POST /stripe/webhook) and set
  # `STRIPE_WEBHOOK_SECRET`; subscription rows stay in sync automatically.
  module Billing
    Log = ::Log.for("silth.billing")

    class StripeError < Silth::Error
      getter status : Int32
      getter body : JSON::Any?

      def initialize(@status : Int32, message : String, @body : JSON::Any? = nil)
        super(message)
      end
    end

    # Minimal Stripe REST client (form encoded requests, JSON responses).
    module Stripe
      API = "https://api.stripe.com/v1"

      def self.secret : String
        ENV["STRIPE_SECRET"]? || Silth.config.string("billing.stripe.secret")
      end

      def self.request(method : String, path : String, params : Hash(String, String) = {} of String => String) : JSON::Any
        client = HTTPClient.new.basic_auth(secret, "").header("Stripe-Version", Silth.config.string("billing.stripe.api_version", "2024-06-20"))
        response = if method == "GET" || method == "DELETE"
                     client.request(method, API + path, query: params.empty? ? nil : params)
                   else
                     client.header("Idempotency-Key", Crypto.uuid7).request(method, API + path, form: params)
                   end
        body = JSON.parse(response.body.presence || "{}")
        unless response.ok?
          raise StripeError.new(response.status, body["error"]?.try(&.["message"]?.try(&.as_s?)) || "Stripe error #{response.status}", body)
        end
        body
      end

      def self.get(path : String, params = {} of String => String) : JSON::Any
        request("GET", path, params)
      end

      def self.post(path : String, params = {} of String => String) : JSON::Any
        request("POST", path, params)
      end

      def self.delete(path : String) : JSON::Any
        request("DELETE", path)
      end

      # Verifies the `Stripe-Signature` header (HMAC-SHA256, 5 minutes tolerance).
      def self.verify_signature(payload : String, header : String?, secret : String, tolerance : Int32 = 300) : Bool
        return false unless header
        parts = header.split(',').map(&.split('=', 2)).select { |p| p.size == 2 }
        timestamp = parts.find { |p| p[0] == "t" }.try(&.[1]) || return false
        signatures = parts.select { |p| p[0] == "v1" }.map(&.[1])
        return false if (Time.utc.to_unix - timestamp.to_i64).abs > tolerance
        expected = Crypto.hmac_hex(secret, "#{timestamp}.#{payload}")
        signatures.any? { |s| Crypto.secure_compare(expected, s) }
      end
    end

    # Local copy of Stripe subscriptions (`subscriptions` table).
    class Subscription < Model
      table subscriptions

      primary_key
      column billable_type : String
      column billable_id : String
      column type : String = "default"
      column stripe_id : String
      column stripe_status : String
      column stripe_price : String?
      column quantity : Int32? = 1
      column trial_ends_at : Time?
      column ends_at : Time?
      timestamps

      ACTIVE = %w(active trialing past_due)

      def active? : Bool
        (ACTIVE.includes?(stripe_status) && ends_at.nil?) || on_grace_period?
      end

      def valid? : Bool
        active? || on_trial?
      end

      def on_trial? : Bool
        (t = trial_ends_at) ? t > Time.utc : false
      end

      def canceled? : Bool
        !ends_at.nil?
      end

      def on_grace_period? : Bool
        (e = ends_at) ? e > Time.utc : false
      end

      def ended? : Bool
        canceled? && !on_grace_period?
      end

      def past_due? : Bool
        stripe_status == "past_due"
      end

      # Cancels at the end of the period.
      def cancel : self
        sub = Stripe.post("/subscriptions/#{stripe_id}", {"cancel_at_period_end" => "true"})
        self.stripe_status = sub["status"].as_s
        self.ends_at = Time.unix(sub["current_period_end"]?.try(&.as_i64?) || sub["cancel_at"]?.try(&.as_i64?) || Time.utc.to_unix)
        save!
      end

      def cancel_now : self
        Stripe.delete("/subscriptions/#{stripe_id}")
        self.stripe_status = "canceled"
        self.ends_at = Time.utc
        save!
      end

      def resume : self
        raise Silth::Error.new("Only subscriptions on their grace period can be resumed") unless on_grace_period?
        sub = Stripe.post("/subscriptions/#{stripe_id}", {"cancel_at_period_end" => "false"})
        self.stripe_status = sub["status"].as_s
        self.ends_at = nil
        save!
      end

      # Changes the price (prorated by default).
      def swap(price : String, prorate : Bool = true) : self
        sub = Stripe.get("/subscriptions/#{stripe_id}")
        item = sub["items"]["data"][0]["id"].as_s
        Stripe.post("/subscriptions/#{stripe_id}", {
          "items[0][id]"       => item,
          "items[0][price]"    => price,
          "proration_behavior" => prorate ? "create_prorations" : "none",
          "cancel_at_period_end" => "false",
        })
        self.stripe_price = price
        self.ends_at = nil
        save!
      end

      def update_quantity(quantity : Int32) : self
        sub = Stripe.get("/subscriptions/#{stripe_id}")
        item = sub["items"]["data"][0]["id"].as_s
        Stripe.post("/subscription_items/#{item}", {"quantity" => quantity.to_s})
        self.quantity = quantity
        save!
      end

      # Creates or updates the local row from a Stripe subscription object.
      def self.sync(data : JSON::Any, billable_type : String? = nil, billable_id : String? = nil) : Subscription?
        stripe_id = data["id"].as_s
        sub = find_by?(stripe_id: stripe_id)
        if sub.nil?
          meta = data["metadata"]?
          type = billable_type || meta.try(&.["billable_type"]?.try(&.as_s?))
          id = billable_id || meta.try(&.["billable_id"]?.try(&.as_s?))
          return nil unless type && id
          sub = new(billable_type: type, billable_id: id, stripe_id: stripe_id, type: meta.try(&.["type"]?.try(&.as_s?)) || "default")
        end
        sub.stripe_status = data["status"].as_s
        item = data["items"]?.try(&.["data"]?.try(&.[0]?))
        sub.stripe_price = item.try(&.["price"]?.try(&.["id"]?.try(&.as_s?)))
        sub.quantity = item.try(&.["quantity"]?.try(&.as_i?)) || 1
        sub.trial_ends_at = data["trial_end"]?.try(&.as_i64?).try { |t| Time.unix(t) }
        if data["cancel_at_period_end"]?.try(&.as_bool?)
          sub.ends_at = data["current_period_end"]?.try(&.as_i64?).try { |t| Time.unix(t) } || data["cancel_at"]?.try(&.as_i64?).try { |t| Time.unix(t) }
        elsif data["status"].as_s == "canceled"
          sub.ends_at = data["ended_at"]?.try(&.as_i64?).try { |t| Time.unix(t) } || Time.utc
        else
          sub.ends_at = nil
        end
        sub.save!
        sub
      end
    end

    # Mix into the paying model.
    module Billable
      def stripe_id? : String?
        read_attribute("stripe_id").as?(String).presence
      end

      def billable_key : String
        read_attribute(__primary_key_name).to_s
      end

      # Creates the Stripe customer on first use.
      def stripe_customer_id : String
        if id = stripe_id?
          return id
        end
        params = {"metadata[billable_type]" => self.class.name, "metadata[billable_id]" => billable_key}
        if email = read_attribute("email").as?(String)
          params["email"] = email
        end
        if name = read_attribute("name").as?(String)
          params["name"] = name
        end
        customer = Stripe.post("/customers", params)
        write_attribute("stripe_id", customer["id"].as_s)
        save(validate: false)
        customer["id"].as_s
      end

      def subscriptions : ORM::Query(Subscription)
        Subscription.where(billable_type: self.class.name, billable_id: billable_key).latest
      end

      def subscription(type : String = "default") : Subscription?
        subscriptions.where(type: type).first?
      end

      def subscribed?(type : String = "default", price : String? = nil) : Bool
        sub = subscription(type) || return false
        return false unless sub.valid?
        price.nil? || sub.stripe_price == price
      end

      def on_trial?(type : String = "default") : Bool
        if t = read_attribute("trial_ends_at").as?(Time)
          return true if t > Time.utc
        end
        subscription(type).try(&.on_trial?) || false
      end

      # Stripe Checkout session URL (subscription or one-off payment).
      def checkout(price : String, success_url : String, cancel_url : String, mode : String = "subscription",
                   quantity : Int32 = 1, trial_days : Int32? = nil, type : String = "default",
                   allow_promotion_codes : Bool = true) : String
        params = {
          "customer"                => stripe_customer_id,
          "mode"                    => mode,
          "success_url"             => success_url,
          "cancel_url"              => cancel_url,
          "line_items[0][price]"    => price,
          "line_items[0][quantity]" => quantity.to_s,
          "allow_promotion_codes"   => allow_promotion_codes.to_s,
        }
        if mode == "subscription"
          params["subscription_data[metadata][billable_type]"] = self.class.name
          params["subscription_data[metadata][billable_id]"] = billable_key
          params["subscription_data[metadata][type]"] = type
          params["subscription_data[trial_period_days]"] = trial_days.to_s if trial_days
        end
        Stripe.post("/checkout/sessions", params)["url"].as_s
      end

      def billing_portal_url(return_url : String) : String
        Stripe.post("/billing_portal/sessions", {"customer" => stripe_customer_id, "return_url" => return_url})["url"].as_s
      end

      # Creates a subscription directly (payment method already attached).
      def subscribe(price : String, type : String = "default", trial_days : Int32? = nil, payment_method : String? = nil, quantity : Int32 = 1) : Subscription
        params = {
          "customer"                => stripe_customer_id,
          "items[0][price]"         => price,
          "items[0][quantity]"      => quantity.to_s,
          "metadata[billable_type]" => self.class.name,
          "metadata[billable_id]"   => billable_key,
          "metadata[type]"          => type,
        }
        params["trial_period_days"] = trial_days.to_s if trial_days
        params["default_payment_method"] = payment_method if payment_method
        data = Stripe.post("/subscriptions", params)
        Subscription.sync(data, self.class.name, billable_key).not_nil!
      end

      # One-off charge (amount in the smallest currency unit).
      def charge(amount : Int32, payment_method : String, currency : String = "usd", description : String? = nil) : JSON::Any
        params = {"amount" => amount.to_s, "currency" => currency, "customer" => stripe_customer_id, "payment_method" => payment_method,
                  "confirm" => "true", "automatic_payment_methods[enabled]" => "true", "automatic_payment_methods[allow_redirects]" => "never"}
        params["description"] = description if description
        Stripe.post("/payment_intents", params)
      end

      def refund(payment_intent : String, amount : Int32? = nil) : JSON::Any
        params = {"payment_intent" => payment_intent}
        params["amount"] = amount.to_s if amount
        Stripe.post("/refunds", params)
      end

      def invoices(limit : Int32 = 24) : Array(JSON::Any)
        return [] of JSON::Any unless stripe_id?
        Stripe.get("/invoices", {"customer" => stripe_customer_id, "limit" => limit.to_s})["data"].as_a
      end

      def payment_methods : Array(JSON::Any)
        return [] of JSON::Any unless stripe_id?
        Stripe.get("/payment_methods", {"customer" => stripe_customer_id, "type" => "card"})["data"].as_a
      end

      def update_default_payment_method(payment_method : String) : Nil
        Stripe.post("/payment_methods/#{payment_method}/attach", {"customer" => stripe_customer_id})
        Stripe.post("/customers/#{stripe_customer_id}", {"invoice_settings[default_payment_method]" => payment_method})
        card = Stripe.get("/payment_methods/#{payment_method}")
        write_attribute("pm_type", card["card"]?.try(&.["brand"]?.try(&.as_s?)))
        write_attribute("pm_last_four", card["card"]?.try(&.["last4"]?.try(&.as_s?)))
        save(validate: false)
      end
    end

    # Dispatched for every verified Stripe webhook (listen to handle custom events).
    class WebhookReceived < Silth::Event
      getter type : String
      getter payload : JSON::Any

      def initialize(@type, @payload)
      end
    end

    # `POST /stripe/webhook` — verifies signatures and syncs subscriptions.
    class WebhookMiddleware < Silth::Middleware
      def initialize(@path : String = "/stripe/webhook")
      end

      def call(ctx : Context, chain : Chain) : Nil
        return chain.next(ctx) unless ctx.path == @path && ctx.request.method == "POST"
        payload = ctx.request.body.try(&.gets_to_end) || ""
        secret = ENV["STRIPE_WEBHOOK_SECRET"]? || Silth.config.string?("billing.stripe.webhook_secret")
        if secret && !Stripe.verify_signature(payload, ctx.header("Stripe-Signature"), secret)
          return ctx.text("Invalid signature", 400)
        end
        event = JSON.parse(payload)
        type = event["type"].as_s
        object = event["data"]["object"]
        case type
        when "customer.subscription.created", "customer.subscription.updated", "customer.subscription.deleted"
          Subscription.sync(object)
        when "customer.deleted"
          Subscription.where(stripe_id: object["id"].as_s).update_all(stripe_status: "canceled", ends_at: Time.utc)
        end
        Events.dispatch(WebhookReceived.new(type, event))
        ctx.json({received: true})
      rescue ex : JSON::ParseException
        ctx.text("Invalid payload", 400)
      end
    end
  end
end

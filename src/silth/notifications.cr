module Silth
  # Multi-channel notifications (mail, database, broadcast, webhook/Slack).
  #
  # ```
  # class InvoicePaid < Silth::Notification
  #   def initialize(@invoice : Invoice)
  #   end
  #
  #   def via(notifiable) : Array(Symbol)
  #     [:mail, :database, :broadcast]
  #   end
  #
  #   def to_mail(notifiable) : Silth::Mail?
  #     InvoicePaidMail.new(@invoice)
  #   end
  #
  #   def to_data(notifiable) : Hash(String, String)
  #     {"invoice_id" => @invoice.id.to_s, "amount" => @invoice.total.to_s}
  #   end
  # end
  #
  # user.notify(InvoicePaid.new(invoice))   # User includes Silth::Notifiable
  # ```
  abstract class Notification
    abstract def via(notifiable) : Array(Symbol)

    def to_mail(notifiable) : Mail?
      nil
    end

    # Payload stored by the database channel and pushed by the broadcast channel.
    def to_data(notifiable) : Hash(String, String)
      {} of String => String
    end

    # `{url, json_body}` for the webhook channel (Slack, Discord, Teams incoming webhooks…).
    def to_webhook(notifiable) : {String, String}?
      nil
    end

    def notification_type : String
      self.class.name
    end
  end

  # Stored notifications (`silth_notifications` table, created by `silth generate notifications`).
  class DatabaseNotification < Model
    table silth_notifications

    primary_key id : String, uuid: true
    column notifiable_type : String
    column notifiable_id : String
    column type : String
    column data : JSON::Any
    column read_at : Time?
    timestamps

    def read? : Bool
      !read_at.nil?
    end

    def mark_as_read : Nil
      self.read_at = Time.utc
      save(validate: false)
    end
  end

  # Include in models that receive notifications. Requires an `email` column for the mail channel.
  module Notifiable
    def notify(notification : Notification) : Nil
      Notifications.send(self, notification)
    end

    def notify_later(notification : Notification) : Nil
      target = self
      Concurrency.defer("notification") { Notifications.send(target, notification) }
    end

    def notifications : ORM::Query(DatabaseNotification)
      DatabaseNotification.where(notifiable_type: self.class.name, notifiable_id: read_attribute(__primary_key_name).to_s).latest
    end

    def unread_notifications : ORM::Query(DatabaseNotification)
      notifications.where_null(:read_at)
    end

    # Topic used by the broadcast channel.
    def notification_topic : String
      "notifications:#{self.class.name.downcase}:#{read_attribute(__primary_key_name)}"
    end
  end

  module Notifications
    Log = ::Log.for("silth.notifications")

    @@faked : Array({String, Notification})? = nil

    def self.send(notifiable : Model, notification : Notification) : Nil
      channels = notification.via(notifiable)
      if faked = @@faked
        faked << {notifiable.class.name, notification}
        return
      end
      Instrument.publish(Instrument::Notification.new(notification.class.name, channels.join(",")))
      channels.each do |channel|
        case channel
        when :mail
          notification.to_mail(notifiable).try &.deliver
        when :database
          DatabaseNotification.create!(notifiable_type: notifiable.class.name, notifiable_id: notifiable.read_attribute(notifiable.__primary_key_name).to_s,
            type: notification.notification_type, data: JSON.parse(notification.to_data(notifiable).to_json))
        when :broadcast
          if notifiable.responds_to?(:notification_topic)
            Broadcast.to(notifiable.notification_topic, "notification",
              JSON.parse({type: notification.notification_type, data: notification.to_data(notifiable)}.to_json))
          end
        when :webhook, :slack
          if hook = notification.to_webhook(notifiable)
            HTTPClient.new.post(hook[0], body: hook[1]).tap { |r| Log.warn { "Webhook failed: #{r.status}" } unless r.ok? }
          end
        else
          Log.warn { "Unknown notification channel #{channel}" }
        end
      rescue ex
        Log.error(exception: ex) { "Notification #{notification.class.name} failed on #{channel}" }
        ErrorReporter.report(ex)
      end
    end

    def self.fake : Nil
      @@faked = [] of {String, Notification}
    end

    def self.unfake : Nil
      @@faked = nil
    end

    def self.sent : Array({String, Notification})
      @@faked || [] of {String, Notification}
    end

    def self.sent?(type : T.class) : Bool forall T
      sent.any? { |(_, n)| n.is_a?(T) }
    end
  end
end

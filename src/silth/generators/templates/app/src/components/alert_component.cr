# Reusable view component: <%= component AlertComponent, message: "Saved", variant: "success" %>
class AlertComponent < Silth::Component
  prop message : String
  prop variant : String = "info"
  template "components/alert"
end

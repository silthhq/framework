# Toast notifications in a live region: screen readers announce them, they
# disappear after `duration` ms (paused while hovered or focused), errors stay
# until dismissed and are announced at once.
#
# Put the toaster once in the layout: `<%= component UI::Toaster %>`. Then:
#
#   emit "toast", {message: "Saved", variant: "success"}    # from a live action
#   ui.toast("Saved", {variant: "success"})                 # from JavaScript (import { ui } from "ui")
#   <%= component UI::Toast, message: "Welcome back" %>     # rendered by the server, inside the toaster
module UI
  class Toast < Silth::Component
    prop message : String
    prop variant : String = "info" # info, success or error
    prop duration : Int32 = 5000   # ms; 0 keeps it until dismissed
    prop dismiss_label : String = "Dismiss"
    template "components/ui/toast"
  end

  class Toaster < Silth::Component
    prop label : String = "Notifications"
    template "components/ui/toaster"
  end
end

# A modal dialog on the native <dialog> element: focus moves into it and stays
# there, Escape closes it, the page behind is inert, focus returns to the button
# that opened it.
#
#   <% component UI::Dialog, id: "delete-post", title: "Delete this post?", trigger: "Delete" do |d| %>
#     <p>This cannot be undone.</p>
#     <% d.slot :actions do %><%= button_to "Delete", route("posts.destroy", id: post.id), method: "delete" %><% end %>
#   <% end %>
#
# Any `<button data-ui-dialog="delete-post">` opens it too. In a live component,
# `open: true` opens it from the server and `close_action: "closed"` calls that
# action when the user closes it, so the state stays in sync.
module UI
  class Dialog < Silth::Component
    prop id : String
    prop title : String
    prop trigger : String? = nil # label of a button opening it (none: open it from elsewhere)
    prop open : Bool = false     # rendered open (live components)
    prop close_label : String = "Close"
    prop close_action : String? = nil # live action called when the dialog closes
    template "components/ui/dialog"
  end
end

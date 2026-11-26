# A menu button (WAI-ARIA menu pattern): Enter, Space or ↓ opens the menu on its
# first item, ↑ on its last; ↑ ↓ Home End move between items, Escape closes and
# gives focus back to the button, Tab or a click outside closes it.
#
#   <% component UI::Dropdown, label: "Options" do |menu| %>
#     <% menu.item "Edit", href: route("posts.edit", id: post.id) %>
#     <% menu.item "Archive", action: "archive" %>                        # a live action
#     <% menu.item "Delete", href: route("posts.destroy", id: post.id), method: "delete", confirm: "Delete it?" %>
#   <% end %>
module UI
  class Dropdown < Silth::Component
    record Item, label : String, href : String?, method : String?, confirm : String?, action : String?

    prop label : String
    prop id : String? = nil
    prop align : String = "start" # start or end: the side of the button the menu lines up with
    getter items = [] of Item
    template "components/ui/dropdown"

    # Adds an item: a link (`href`, with `method` for DELETE/PATCH links) or a live action (`action`).
    def item(label : String, href : String? = nil, method : String? = nil, confirm : String? = nil, action : String? = nil) : self
      @items << Item.new(label, href, method, confirm, action)
      self
    end

    # The template code component previews show.
    def preview_usage : String?
      lines = @items.map do |i|
        options = {"href" => i.href, "method" => i.method, "confirm" => i.confirm, "action" => i.action}.compact_map { |k, v| v ? "#{k}: #{v.inspect}" : nil }
        "  <% menu.item #{([i.label.inspect] + options).join(", ")} %>"
      end
      (["<% component UI::Dropdown, label: #{label.inspect}#{align == "start" ? "" : ", align: #{align.inspect}"} do |menu| %>"] + lines + ["<% end %>"]).join('\n')
    end

    def dom_id : String
      id || "#{UI.dom_id(label)}-menu"
    end
  end
end

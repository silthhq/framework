# Tabs (WAI-ARIA tabs pattern): ← → move between tabs and show their panel,
# Home and End jump to the first and last; only the selected tab is in the Tab
# order, then its panel.
#
#   <% component UI::Tabs, label: "Account" do |tabs| %>
#     <% tabs.tab "profile", "Profile" do %>…<% end %>
#     <% tabs.tab "billing", "Billing" do %>…<% end %>
#   <% end %>
module UI
  class Tabs < Silth::Component
    record Tab, key : String, label : String

    prop label : String
    prop id : String? = nil
    prop selected : String? = nil # key of the tab shown first (default: the first one)
    getter tabs = [] of Tab
    template "components/ui/tabs"

    # Declares a tab; the block is its panel.
    def tab(key : String, label : String, &block : -> _) : Nil
      @tabs << Tab.new(key, label)
      slot("tab-#{key}") { block.call }
    end

    # Declares a tab with its panel's HTML (previews, code).
    def add_tab(key : String, label : String, html : String) : self
      @tabs << Tab.new(key, label)
      fill_slot("tab-#{key}", html)
      self
    end

    def dom_id : String
      id || "#{UI.dom_id(label)}-tabs"
    end

    # The template code component previews show.
    def preview_usage : String?
      lines = @tabs.map { |t| %(  <% tabs.tab #{t.key.inspect}, #{t.label.inspect} do %>…<% end %>) }
      (["<% component UI::Tabs, label: #{label.inspect}#{selected ? ", selected: #{selected.inspect}" : ""} do |tabs| %>"] + lines + ["<% end %>"]).join('\n')
    end

    def selected?(tab : Tab) : Bool
      tab.key == (selected || @tabs.first?.try(&.key))
    end
  end
end

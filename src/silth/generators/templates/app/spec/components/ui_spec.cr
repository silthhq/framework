require "../spec_helper"

# The UI components render the ARIA their keyboard behavior (assets/js/ui.js) relies on.
describe "UI components" do
  it "renders a dialog labelled by its title, with its opener" do
    html = UI::Dialog.new(id: "confirm", title: "Delete it?", trigger: "Delete").with_slots(content: "<p>Sure?</p>").render
    html.should contain(%(<button type="button" data-ui-dialog="confirm" aria-haspopup="dialog">Delete</button>))
    html.should contain(%(<dialog data-ui="dialog" id="confirm" aria-labelledby="confirm-title"))
    html.should contain(%(<h2 id="confirm-title">Delete it?</h2>))
    html.should_not contain("data-ui-open")
    UI::Dialog.new(id: "x", title: "X", open: true, close_action: "closed").render.should contain(%(data-ui-open data-ui-close-action="closed"))
  end

  it "renders a menu button and its items" do
    html = UI::Dropdown.new(label: "Options").item("Edit", href: "/edit").item("Archive", action: "archive").render
    html.should contain(%(aria-haspopup="menu" aria-expanded="false" aria-controls="options-menu"))
    html.should contain(%(<div role="menu" id="options-menu" aria-labelledby="options-menu-button" hidden))
    html.should contain(%(<a role="menuitem" tabindex="-1" href="/edit">Edit</a>))
    html.should contain(%(<button type="button" role="menuitem" tabindex="-1" silth-click="archive">Archive</button>))
  end

  it "renders tabs with one tab in the Tab order and its panel shown" do
    html = UI::Tabs.new(label: "Account", selected: "billing").add_tab("profile", "Profile", "<p>P</p>").add_tab("billing", "Billing", "<p>B</p>").render
    html.should contain(%(<div role="tablist" aria-label="Account">))
    html.should contain(%(id="account-tabs-tab-billing" aria-controls="account-tabs-panel-billing" aria-selected="true" tabindex="0"))
    html.should contain(%(id="account-tabs-tab-profile" aria-controls="account-tabs-panel-profile" aria-selected="false" tabindex="-1"))
    html.should contain(%(<div role="tabpanel" id="account-tabs-panel-profile" aria-labelledby="account-tabs-tab-profile" tabindex="0" hidden))
  end

  it "renders toasts in live regions" do
    html = UI::Toaster.new.with_slots(content: UI::Toast.new(message: "Saved").render).render
    html.should contain(%(aria-live="polite"))
    html.should contain(%(aria-live="assertive"))
    html.should contain(%(<div data-ui="toast" data-variant="info" data-duration="5000">))
    UI::Toast.new(message: "Failed", variant: "error").render.should contain(%(data-duration="0"))
  end

  it "lists the previews" do
    Silth::ComponentPreview.all.map(&.[0]).should contain("UI::DialogPreview")
  end
end

# Previews of the UI components (src/components/ui), with their keyboard
# behavior: /_silth/profiler/components.
module UI
  class DialogPreview < Silth::ComponentPreview
    description "Modal dialog on <dialog>: Escape closes it, focus stays inside and comes back to the button."

    def default : Silth::Component
      Dialog.new(id: "preview-dialog", title: "Delete this post?", trigger: "Delete…")
        .with_slots(content: "<p>It will be gone for good, comments included.</p>",
          actions: %(<button type="button" class="btn" data-ui-close>Cancel</button><button type="button" class="btn btn-danger" data-ui-close>Delete</button>))
    end

    def open_from_the_server : Silth::Component
      Dialog.new(id: "preview-dialog-open", title: "Session expired", open: true)
        .with_slots(content: "<p>A live component rendered this dialog with <code>open: true</code>.</p>")
    end
  end

  class DropdownPreview < Silth::ComponentPreview
    description "Menu button: arrows, Home, End, a letter to jump, Escape to close."

    def default : Silth::Component
      Dropdown.new(label: "Options").item("Edit", href: "#edit").item("Duplicate", href: "#duplicate")
        .item("Delete", href: "#delete", method: "delete", confirm: "Delete it?")
    end

    def aligned_to_the_end : Silth::Component
      Dropdown.new(label: "Account", align: "end").item("Profile", href: "#profile").item("Settings", href: "#settings").item("Sign out", href: "#logout")
    end
  end

  class TabsPreview < Silth::ComponentPreview
    description "Tabs: ← → Home End move between tabs, Tab goes to the panel."

    def default : Silth::Component
      Tabs.new(label: "Account")
        .add_tab("profile", "Profile", "<p>Name, avatar and bio.</p>")
        .add_tab("security", "Security", "<p>Password and two-factor authentication.</p>")
        .add_tab("billing", "Billing", "<p>Plan, invoices and payment method.</p>")
    end

    def second_selected : Silth::Component
      tabs = default.as(Tabs)
      tabs.selected = "security"
      tabs
    end
  end

  class ToastPreview < Silth::ComponentPreview
    description "Notifications in a live region; errors stay until dismissed."

    def info : Silth::Component
      Toaster.new.with_slots(content: Toast.new(message: "Draft saved.", duration: 0).render)
    end

    def success_and_error : Silth::Component
      Toaster.new.with_slots(content: Toast.new(message: "Post published.", variant: "success", duration: 0).render +
                                      Toast.new(message: "The upload failed.", variant: "error").render)
    end
  end
end

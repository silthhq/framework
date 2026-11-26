# Accessible components shipped with the app, unstyled by default: semantic
# markup and ARIA, `data-ui` hooks for styling (assets/ui.css, yours to change or
# delete) and keyboard behavior in assets/js/ui.js. They are your code: edit them.
#
# Previews: /_silth/profiler/components. Docs: https://silth.dev/docs/basics/ui-components
module UI
  # A DOM id from *text*: "Account settings" → "account-settings".
  def self.dom_id(text : String) : String
    id = text.downcase.gsub(/[^a-z0-9]+/, "-").strip('-')
    id.empty? ? "ui" : id
  end
end

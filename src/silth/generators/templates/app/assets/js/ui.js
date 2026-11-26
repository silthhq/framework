// Keyboard and focus behavior of the UI components (src/components/ui): dialog,
// dropdown menu, tabs and toasts, following the WAI-ARIA Authoring Practices.
// Events are delegated to the document, so markup rendered later (live
// components included) works without setup. This file is yours: change it.
//
//   import { ui } from "ui";
//   ui.toast("Saved", { variant: "success" });
//   ui.openDialog("delete-post");
import { silth } from "silth";

const $$ = (selector, root = document) => Array.from(root.querySelectorAll(selector));

/* ------------------------------------------------------------- dialog */

// Native <dialog>: showModal() traps focus, makes the page inert and closes on
// Escape; focus goes back to the element that opened it.
function openDialog(dialog, opener = document.activeElement) {
  if (!dialog || dialog.open) return;
  dialog.uiOpener = opener;
  dialog.showModal();
}

function closeDialog(dialog) {
  if (dialog?.open) dialog.close();
}

// Server state: a live component renders `data-ui-open` to open the dialog.
function syncDialog(dialog) {
  const wanted = dialog.hasAttribute("data-ui-open");
  if (wanted && !dialog.open) { dialog.uiServerOpen = true; openDialog(dialog); }
  if (!wanted && dialog.open && dialog.uiServerOpen) closeDialog(dialog);
}

document.addEventListener("close", (e) => {
  const dialog = e.target;
  if (!(dialog instanceof HTMLDialogElement) || dialog.dataset.ui !== "dialog") return;
  dialog.uiServerOpen = false;
  if (dialog.uiOpener?.isConnected) dialog.uiOpener.focus();
  const action = dialog.dataset.uiCloseAction;
  if (action && dialog.closest("[data-silth-live]")) silth.call(dialog, action);
}, true);

/* ----------------------------------------------------------- dropdown */

const MENU_BUTTON = '[data-ui="dropdown"] > [aria-haspopup="menu"]';
const menuOf = (button) => document.getElementById(button.getAttribute("aria-controls"));
const buttonOf = (menu) => document.getElementById(menu.getAttribute("aria-labelledby"));
const itemsOf = (menu) => $$('[role="menuitem"]:not([disabled]):not([aria-disabled="true"])', menu);

function openMenu(button, focus = "first") {
  closeMenus(button);
  const menu = menuOf(button);
  if (!menu) return;
  menu.hidden = false;
  button.setAttribute("aria-expanded", "true");
  const items = itemsOf(menu);
  (focus === "last" ? items[items.length - 1] : items[0])?.focus();
}

function closeMenu(button, refocus = false) {
  const menu = button && menuOf(button);
  if (!menu || menu.hidden) return;
  menu.hidden = true;
  button.setAttribute("aria-expanded", "false");
  if (refocus) button.focus();
}

function closeMenus(except = null) {
  $$(`${MENU_BUTTON}[aria-expanded="true"]`).forEach((button) => button !== except && closeMenu(button));
}

function menuKeydown(e, menu) {
  const items = itemsOf(menu);
  const index = items.indexOf(document.activeElement);
  const focus = (i) => { e.preventDefault(); items[(i + items.length) % items.length]?.focus(); };
  switch (e.key) {
    case "ArrowDown": return focus(index + 1);
    case "ArrowUp": return focus(index - 1);
    case "Home": return focus(0);
    case "End": return focus(items.length - 1);
    case "Escape": e.preventDefault(); return closeMenu(buttonOf(menu), true);
    case "Tab": return closeMenu(buttonOf(menu));
    case " ": if (document.activeElement?.tagName === "A") { e.preventDefault(); document.activeElement.click(); } return;
    default: // type a letter: next item starting with it
      if (e.key.length !== 1 || !/\S/.test(e.key)) return;
      const key = e.key.toLowerCase();
      const next = items.slice(index + 1).concat(items.slice(0, index + 1)).find((item) => item.textContent.trim().toLowerCase().startsWith(key));
      next?.focus();
  }
}

/* --------------------------------------------------------------- tabs */

// Automatic activation: moving to a tab shows its panel.
function selectTab(tab, focus = true) {
  const list = tab.closest('[role="tablist"]');
  $$('[role="tab"]', list).forEach((other) => {
    const selected = other === tab;
    other.setAttribute("aria-selected", String(selected));
    other.tabIndex = selected ? 0 : -1;
    const panel = document.getElementById(other.getAttribute("aria-controls"));
    if (panel) panel.hidden = !selected;
  });
  if (focus) tab.focus();
  tab.dispatchEvent(new CustomEvent("ui:tab", { bubbles: true, detail: { id: tab.id } }));
}

function tabKeydown(e, tab) {
  const tabs = $$('[role="tab"]', tab.closest('[role="tablist"]'));
  const index = tabs.indexOf(tab);
  const go = (i) => { e.preventDefault(); selectTab(tabs[(i + tabs.length) % tabs.length]); };
  switch (e.key) {
    case "ArrowRight": return go(index + 1);
    case "ArrowLeft": return go(index - 1);
    case "Home": return go(0);
    case "End": return go(tabs.length - 1);
  }
}

/* ------------------------------------------------------------- toasts */

// Timers pause while a toast is hovered or focused; duration 0 never expires.
function arm(toast) {
  const duration = parseInt(toast.dataset.duration ?? "5000", 10);
  if (!duration || toast.uiTimer) return;
  const state = (toast.uiTimer = { left: duration, started: 0, timer: 0, holds: 0 });
  const run = () => { state.started = Date.now(); state.timer = setTimeout(() => dismiss(toast), state.left); };
  const hold = () => { if (state.holds++ === 0) { clearTimeout(state.timer); state.left -= Date.now() - state.started; } };
  const release = () => { if (--state.holds === 0) run(); };
  toast.addEventListener("mouseenter", hold);
  toast.addEventListener("mouseleave", release);
  toast.addEventListener("focusin", hold);
  toast.addEventListener("focusout", release);
  run();
}

function dismiss(toast) {
  if (!toast?.isConnected) return;
  toast.dataset.state = "closing";
  setTimeout(() => toast.remove(), 160);
}

// Same markup as src/views/components/ui/toast.html.ecr.
function toast(message, { variant = "info", duration = 5000, dismissLabel = "Dismiss" } = {}) {
  const el = document.createElement("div");
  el.dataset.ui = "toast";
  el.dataset.variant = variant;
  el.dataset.duration = variant === "error" ? "0" : String(duration);
  const text = document.createElement("p");
  text.textContent = message;
  const close = document.createElement("button");
  close.type = "button";
  close.dataset.uiDismiss = "";
  close.setAttribute("aria-label", dismissLabel);
  close.textContent = "×";
  el.append(text, close);
  const toaster = document.querySelector('[data-ui="toaster"]');
  if (!toaster) { console.warn("[ui] add <%= component UI::Toaster %> to the layout to show toasts"); return el; }
  toaster.querySelector(variant === "error" ? "[data-urgent]" : '[data-ui="toasts"]:not([data-urgent])').append(el);
  arm(el);
  return el;
}

// `emit "toast", {message: "Saved", variant: "success"}` in a live action.
window.addEventListener("silth:toast", (e) => toast(e.detail?.message ?? "Done", e.detail || {}));

/* ------------------------------------------------------------- events */

document.addEventListener("click", (e) => {
  const opener = e.target.closest("[data-ui-dialog]");
  if (opener) return openDialog(document.getElementById(opener.dataset.uiDialog), opener);
  const closer = e.target.closest("[data-ui-close]");
  if (closer) return closeDialog(closer.closest("dialog"));
  if (e.target.matches?.('dialog[data-ui="dialog"]')) { // the backdrop, around the dialog box
    const box = e.target.getBoundingClientRect();
    const inside = e.clientX >= box.left && e.clientX <= box.right && e.clientY >= box.top && e.clientY <= box.bottom;
    if (!inside && e.detail > 0) closeDialog(e.target);
    return;
  }
  const button = e.target.closest(MENU_BUTTON);
  if (button) return button.getAttribute("aria-expanded") === "true" ? closeMenu(button) : openMenu(button);
  const item = e.target.closest('[data-ui="dropdown"] [role="menuitem"]');
  if (item) { const b = buttonOf(item.closest('[role="menu"]')); setTimeout(() => closeMenu(b, true)); return; }
  if (!e.target.closest('[data-ui="dropdown"]')) closeMenus();
  const tab = e.target.closest('[data-ui="tabs"] [role="tab"]');
  if (tab) return selectTab(tab);
  const dismissButton = e.target.closest("[data-ui-dismiss]");
  if (dismissButton) dismiss(dismissButton.closest('[data-ui="toast"]'));
});

document.addEventListener("keydown", (e) => {
  const button = e.target.closest?.(MENU_BUTTON);
  if (button && (e.key === "ArrowDown" || e.key === "ArrowUp")) { e.preventDefault(); return openMenu(button, e.key === "ArrowUp" ? "last" : "first"); }
  const menu = e.target.closest?.('[data-ui="dropdown"] [role="menu"]');
  if (menu) return menuKeydown(e, menu);
  const tab = e.target.closest?.('[data-ui="tabs"] [role="tab"]');
  if (tab) return tabKeydown(e, tab);
});

function scan(root = document) {
  $$('dialog[data-ui="dialog"][data-ui-open]', root).forEach(syncDialog);
  $$('[data-ui="toast"]', root).forEach((el) => el.closest('[data-ui="toaster"]') && arm(el));
}

new MutationObserver((mutations) => mutations.forEach((m) => {
  if (m.type === "attributes") { if (m.target.matches('dialog[data-ui="dialog"]')) syncDialog(m.target); return; }
  m.addedNodes.forEach((node) => node.nodeType === 1 && scan(node.parentNode || document));
})).observe(document.documentElement, { childList: true, subtree: true, attributes: true, attributeFilter: ["data-ui-open"] });

if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", () => scan()); else scan();

export const ui = {
  toast,
  dismiss,
  openDialog: (id) => openDialog(document.getElementById(id)),
  closeDialog: (id) => closeDialog(document.getElementById(id)),
  selectTab: (id) => { const tab = document.getElementById(id); if (tab) selectTab(tab, false); },
};
export default ui;

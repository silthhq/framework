// Silth client runtime — live components, channels and small UJS helpers.
// Zero dependencies. Served by the framework at /_silth/silth.js (ES module).
//
//   <script type="module" src="/_silth/silth.js"></script>   (or `silth_scripts` helper)
//   import { silth } from "silth"                             (with import maps)

const csrfToken = () => document.querySelector('meta[name="csrf-token"]')?.content || "";
const wsUrl = (path) => `${location.protocol === "https:" ? "wss" : "ws"}://${location.host}${path}`;
let refSeq = 0;
const nextRef = () => String(++refSeq);

/* ------------------------------------------------------------------ morph */

// Patches `from` so that it matches `to` while keeping focus, scroll and input state.
function morphChildren(from, to) {
  const oldNodes = Array.from(from.childNodes);
  const newNodes = Array.from(to.childNodes);
  const keyed = new Map();
  oldNodes.forEach((n) => { const k = nodeKey(n); if (k) keyed.set(k, n); });
  let cursor = from.firstChild;
  for (const newNode of newNodes) {
    const key = nodeKey(newNode);
    let match = key ? keyed.get(key) : null;
    if (!match && cursor && sameKind(cursor, newNode) && !nodeKey(cursor)) match = cursor;
    if (match) {
      if (match !== cursor) from.insertBefore(match, cursor);
      morphNode(match, newNode);
      cursor = match.nextSibling;
    } else {
      from.insertBefore(newNode.cloneNode(true), cursor);
    }
  }
  while (cursor) { const next = cursor.nextSibling; from.removeChild(cursor); cursor = next; }
}

function nodeKey(n) {
  return n.nodeType === 1 ? (n.getAttribute("data-key") || n.id || null) : null;
}

function sameKind(a, b) {
  return a.nodeType === b.nodeType && (a.nodeType !== 1 || a.tagName === b.tagName);
}

// Attributes the runtime sets on mounted components (never sent by the server).
const RUNTIME_ATTRS = new Set(["data-silth-mounted", "data-silth-polling", "aria-busy"]);

function morphNode(from, to) {
  if (from.nodeType !== 1) { if (from.nodeValue !== to.nodeValue) from.nodeValue = to.nodeValue; return; }
  if (from.hasAttribute("silth-ignore")) return;
  // A nested live component keeps its own state while the parent passes the same props.
  if (from.hasAttribute("data-silth-live") && from.dataset.silthMounted &&
      from.getAttribute("data-silth-props") === to.getAttribute("data-silth-props")) return;
  for (const attr of Array.from(from.attributes)) if (!to.hasAttribute(attr.name) && !RUNTIME_ATTRS.has(attr.name)) from.removeAttribute(attr.name);
  for (const attr of Array.from(to.attributes)) if (from.getAttribute(attr.name) !== attr.value) from.setAttribute(attr.name, attr.value);
  const focused = document.activeElement === from;
  if (from.tagName === "INPUT" || from.tagName === "TEXTAREA" || from.tagName === "SELECT") {
    if (!focused && from.type !== "file") {
      if (from.type === "checkbox" || from.type === "radio") from.checked = to.hasAttribute("checked");
      else if ("value" in to) from.value = to.getAttribute("value") ?? to.value ?? "";
    }
    if (from.tagName !== "SELECT") return;
  }
  morphChildren(from, to);
}

function morph(el, html) {
  const tpl = document.createElement("template");
  tpl.innerHTML = html.trim();
  morphChildren(el, tpl.content);
}

/* ---------------------------------------------------------- transport */

class LiveTransport {
  constructor() {
    this.pending = new Map();
    this.queue = [];
    this.connect();
  }
  connect() {
    if (!("WebSocket" in window)) return;
    this.ws = new WebSocket(wsUrl("/_silth/live"));
    this.ws.onopen = () => {
      this.retry = 0;
      document.querySelectorAll("[data-silth-live]").forEach((el) => mountMessage(el));
      this.queue.splice(0).forEach((m) => this.ws.send(m));
    };
    this.ws.onmessage = (e) => {
      const data = JSON.parse(e.data);
      const waiter = data.ref && this.pending.get(data.ref);
      if (waiter) { this.pending.delete(data.ref); waiter(data); } else applyResponse(data);
    };
    this.ws.onclose = () => {
      this.pending.forEach((w) => w(null));
      this.pending.clear();
      setTimeout(() => this.connect(), Math.min(10000, 300 * 2 ** (this.retry = (this.retry || 0) + 1)));
    };
  }
  send(message) {
    message.ref = nextRef();
    const raw = JSON.stringify(message);
    if (this.ws && this.ws.readyState === 1) {
      return new Promise((resolve) => { this.pending.set(message.ref, resolve); this.ws.send(raw); })
        .then((res) => res || this.http(raw));
    }
    return this.http(raw);
  }
  mount(raw) {
    if (this.ws && this.ws.readyState === 1) this.ws.send(raw); else this.queue.push(raw);
  }
  async http(raw) {
    const res = await fetch("/_silth/live", { method: "POST", headers: { "Content-Type": "application/json", "X-CSRF-Token": csrfToken() }, body: raw });
    return res.json();
  }
}

let transport = null;
const getTransport = () => (transport ||= new LiveTransport());

function mountMessage(el) {
  const topics = (el.dataset.silthSubscribe || "").split(",").filter(Boolean);
  getTransport().mount(JSON.stringify({ type: "mount", id: el.id, c: el.dataset.silthLive, s: el.dataset.silthState, topics }));
}

function applyResponse(data) {
  if (!data) return;
  // The profiler's toolbar lists live actions as sub-requests (development only).
  if (data.profile) window.dispatchEvent(new CustomEvent("silth:profile", { detail: data.profile }));
  if (data.error) { console.error("[silth]", data.error); return; }
  if (data.redirect) { location.href = data.redirect; return; }
  const el = document.getElementById(data.id);
  if (el && data.html !== undefined) {
    morph(el, data.html);
    el.dataset.silthState = data.s;
  }
  (data.emits || []).forEach(({ event, payload }) => window.dispatchEvent(new CustomEvent(`silth:${event}`, { detail: payload })));
  // notify_parent: actions of the enclosing live component
  const parent = el?.parentElement?.closest("[data-silth-live]");
  if (parent) (data.parent || []).forEach(({ a, args }) => call(parent, a, args));
}

/* -------------------------------------------------------- components */

const timers = new WeakMap();

// Calls are serialized per component so each one starts from the latest state.
const queues = new WeakMap();

function call(root, action, args = [], models = {}) {
  const next = (queues.get(root) || Promise.resolve()).then(() => perform(root, action, args, models)).catch((e) => console.error("[silth]", e));
  queues.set(root, next);
  return next;
}

async function perform(root, action, args, models) {
  root.setAttribute("aria-busy", "true");
  root.querySelectorAll("[silth-loading]").forEach((n) => n.hidden = false);
  try {
    const data = await getTransport().send({ id: root.id, c: root.dataset.silthLive, s: root.dataset.silthState, a: action, args, m: models });
    applyResponse(data);
  } finally {
    root.removeAttribute("aria-busy");
    root.querySelectorAll("[silth-loading]").forEach((n) => n.hidden = true);
  }
}

function componentOf(el) { return el.closest("[data-silth-live]"); }

function directive(el, name) {
  for (const attr of el.attributes) if (attr.name === name || attr.name.startsWith(name + ".")) return attr;
  return null;
}

function modifiers(attr) {
  const parts = attr.name.split(".").slice(1);
  const debounce = parts.indexOf("debounce");
  const ms = debounce >= 0 ? parseInt(parts[debounce + 1] || "250", 10) : 0;
  return { lazy: parts.includes("lazy"), ms, enter: parts.includes("enter"), prevent: parts.includes("prevent") };
}

function parseArgs(el) {
  const raw = el.getAttribute("silth-args");
  if (!raw) return [];
  try { const v = JSON.parse(raw); return Array.isArray(v) ? v : [v]; } catch { return [raw]; }
}

/* ------------------------------------------------------------ uploads */

// Uploads one file to a temporary location; resolves with its signed token.
// Progress is exposed as `data-silth-progress` (0-100) on the input and `silth:upload-progress` events.
function uploadFile(file, input) {
  return new Promise((resolve, reject) => {
    const xhr = new XMLHttpRequest();
    const body = new FormData();
    body.append("file", file);
    xhr.open("POST", "/_silth/live/upload");
    xhr.setRequestHeader("X-CSRF-Token", csrfToken());
    xhr.responseType = "json";
    xhr.upload.onprogress = (e) => {
      if (!e.lengthComputable) return;
      const percent = Math.round((e.loaded / e.total) * 100);
      input.dataset.silthProgress = String(percent);
      input.dispatchEvent(new CustomEvent("silth:upload-progress", { bubbles: true, detail: { file: file.name, percent } }));
    };
    xhr.onload = () => (xhr.status < 300 && xhr.response?.token ? resolve(xhr.response.token) : reject(new Error(xhr.response?.error || `Upload failed (${xhr.status})`)));
    xhr.onerror = () => reject(new Error("Upload failed"));
    xhr.send(body);
  });
}

async function uploadFiles(root, input, name) {
  const files = Array.from(input.files || []);
  root.setAttribute("aria-busy", "true");
  try {
    const tokens = [];
    for (const file of files) tokens.push(await uploadFile(file, input));
    await call(root, null, [], { [name]: input.multiple ? tokens : (tokens[0] ?? null) });
  } catch (e) {
    console.error("[silth]", e);
    input.dispatchEvent(new CustomEvent("silth:upload-error", { bubbles: true, detail: { message: e.message } }));
  } finally {
    root.removeAttribute("aria-busy");
    delete input.dataset.silthProgress;
  }
}

function inputValue(el) {
  if (el.type === "checkbox") return el.checked;
  if (el.type === "number" || el.type === "range") return el.value === "" ? null : Number(el.value);
  return el.value;
}

function onEvent(type, handler) { document.addEventListener(type, handler, true); }

onEvent("click", (e) => {
  const el = e.target.closest("[silth-click]");
  if (!el) return;
  const root = componentOf(el);
  if (!root) return;
  e.preventDefault();
  const confirmText = el.getAttribute("silth-confirm");
  if (confirmText && !confirm(confirmText)) return;
  call(root, el.getAttribute("silth-click"), parseArgs(el));
});

onEvent("submit", (e) => {
  const form = e.target.closest("form[silth-submit]");
  if (!form) return;
  const root = componentOf(form);
  if (!root) return;
  e.preventDefault();
  const models = {};
  new FormData(form).forEach((v, k) => { models[k] = v; });
  call(root, form.getAttribute("silth-submit"), parseArgs(form), models);
});

const modelHandler = (e) => {
  const el = e.target;
  if (!(el instanceof Element)) return;
  const attr = directive(el, "silth-model");
  if (!attr) return;
  const mods = modifiers(attr);
  if (mods.lazy && e.type === "input") return;
  const root = componentOf(el);
  if (!root) return;
  if (el.type === "file") { if (e.type === "change") uploadFiles(root, el, attr.value); return; }
  const send = () => call(root, null, [], { [attr.value]: inputValue(el) });
  clearTimeout(timers.get(el));
  if (mods.ms > 0 && e.type === "input") timers.set(el, setTimeout(send, mods.ms)); else send();
};
onEvent("input", modelHandler);
onEvent("change", (e) => {
  modelHandler(e);
  const el = e.target.closest?.("[silth-change]");
  if (el && componentOf(el)) call(componentOf(el), el.getAttribute("silth-change"), [inputValue(el)]);
});

onEvent("keydown", (e) => {
  const el = e.target.closest?.("[silth-keydown\\.enter]");
  if (el && e.key === "Enter" && componentOf(el)) { e.preventDefault(); call(componentOf(el), el.getAttribute("silth-keydown.enter"), [inputValue(el)]); }
});

function startPolling(root) {
  const every = root.getAttribute("silth-poll");
  if (!every || root.dataset.silthPolling) return;
  root.dataset.silthPolling = "1";
  const ms = every.endsWith("ms") ? parseInt(every) : parseFloat(every) * 1000;
  const tick = () => { if (document.body.contains(root)) { if (!document.hidden) call(root, root.getAttribute("silth-poll-action") || null); setTimeout(tick, ms); } };
  setTimeout(tick, ms);
}

function scan(scope = document) {
  scope.querySelectorAll("[data-silth-live]").forEach((root) => {
    if (root.dataset.silthMounted) return;
    root.dataset.silthMounted = "1";
    if (root.dataset.silthSubscribe) mountMessage(root);
    startPolling(root.querySelector("[silth-poll]") ? root : root);
    root.querySelectorAll("[silth-poll]").forEach(() => startPolling(root));
  });
}

/* -------------------------------------------------------------- UJS */

// <a href="/posts/1" data-method="delete" data-confirm="Sure?">Delete</a>
onEvent("click", (e) => {
  const link = e.target.closest("a[data-method], a[data-confirm], button[data-confirm]");
  if (!link) return;
  const text = link.dataset.confirm;
  if (text && !confirm(text)) { e.preventDefault(); e.stopImmediatePropagation(); return; }
  const method = link.dataset.method;
  if (!method || link.tagName !== "A") return;
  e.preventDefault();
  const form = document.createElement("form");
  form.method = "post";
  form.action = link.href;
  form.innerHTML = `<input type="hidden" name="_method" value="${method}"><input type="hidden" name="_csrf" value="${csrfToken()}">`;
  document.body.appendChild(form);
  form.submit();
});

// Auto-dismiss flash messages: <div class="flash" data-dismiss="4000">
function dismissFlashes(scope = document) {
  scope.querySelectorAll("[data-dismiss]").forEach((el) => {
    setTimeout(() => { el.style.transition = "opacity .4s"; el.style.opacity = "0"; setTimeout(() => el.remove(), 400); }, parseInt(el.dataset.dismiss || "4000"));
  });
}

/* ----------------------------------------------------------- channels */

export class Socket {
  constructor(path = "/_silth/socket") {
    this.path = path;
    this.channels = new Map();
    this.pending = new Map();
    this.buffer = [];
    this.connect();
    this.heartbeat = setInterval(() => this.push("phoenix", "heartbeat", {}), 30000);
  }
  connect() {
    this.ws = new WebSocket(wsUrl(this.path));
    this.ws.onopen = () => {
      this.retry = 0;
      this.buffer.splice(0).forEach((m) => this.ws.send(m));
      this.channels.forEach((ch) => ch.joined && ch.rejoin());
    };
    this.ws.onmessage = (e) => {
      const [ref, topic, event, payload] = JSON.parse(e.data);
      if (ref && this.pending.has(ref)) { this.pending.get(ref)(payload); this.pending.delete(ref); return; }
      this.channels.get(topic)?.trigger(event, payload);
    };
    this.ws.onclose = () => setTimeout(() => this.connect(), Math.min(10000, 500 * 2 ** (this.retry = (this.retry || 0) + 1)));
  }
  push(topic, event, payload) {
    const ref = nextRef();
    const raw = JSON.stringify([ref, topic, event, payload]);
    if (this.ws.readyState === 1) this.ws.send(raw); else this.buffer.push(raw);
    return new Promise((resolve) => this.pending.set(ref, resolve));
  }
  channel(topic, params = {}) {
    if (!this.channels.has(topic)) this.channels.set(topic, new Channel(this, topic, params));
    return this.channels.get(topic);
  }
}

class Channel {
  constructor(socket, topic, params) { this.socket = socket; this.topic = topic; this.params = params; this.handlers = {}; this.joined = false; }
  join() { this.joined = true; return this.socket.push(this.topic, "join", this.params); }
  rejoin() { this.socket.push(this.topic, "join", this.params); }
  leave() { this.joined = false; return this.socket.push(this.topic, "leave", {}); }
  push(event, payload = {}) { return this.socket.push(this.topic, event, payload); }
  on(event, handler) { (this.handlers[event] ||= []).push(handler); return this; }
  trigger(event, payload) { (this.handlers[event] || []).forEach((h) => h(payload)); }
}

let defaultSocket = null;

export const silth = {
  socket: (path) => (path ? new Socket(path) : (defaultSocket ||= new Socket())),
  call: (el, action, args) => call(componentOf(el) || el, action, args),
  morph,
  scan,
  csrfToken,
  fetch: (url, opts = {}) => fetch(url, { ...opts, headers: { "X-CSRF-Token": csrfToken(), "X-Requested-With": "XMLHttpRequest", ...(opts.headers || {}) } }),
};

window.silth = silth;

const boot = () => { scan(); dismissFlashes(); };
if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", boot); else boot();
new MutationObserver((mutations) => mutations.forEach((m) => m.addedNodes.forEach((n) => { if (n.nodeType === 1) { scan(n.parentNode || document); } }))).observe(document.documentElement, { childList: true, subtree: true });

export default silth;

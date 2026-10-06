"use strict";
const $ = id => document.getElementById(id);
const idleMilliseconds = 5 * 60 * 1000;
let worker, workerReady, settings, connected = false, busy = false, serial = 0, offset = 0, area = "all", idleTimer, searchTimer, pageState;
let richDocument = null;
let sessionGeneration = 0;
let cancelWorkerStart = null;
const pending = new Map();

function status(message) { $("status").textContent = message; }
function setBusy(value) {
  busy = value;
  for (const button of document.querySelectorAll("button:not(#disconnect):not(#close-copy):not(#close-clip):not(#close-rich)")) button.setAttribute("aria-disabled", String(value));
  $("history").setAttribute("aria-busy", String(value));
}
function touch() {
  clearTimeout(idleTimer);
  if (connected) idleTimer = setTimeout(() => disconnect("Disconnected after five minutes without activity."), idleMilliseconds);
}
function disconnect(message = "Disconnected.") {
  sessionGeneration++;
  cancelWorkerStart?.(); cancelWorkerStart = null;
  worker?.terminate(); worker = null;
  for (const promise of pending.values()) promise.reject(new Error("Disconnected."));
  pending.clear(); connected = false; pageState = null; clearTimeout(idleTimer); clearTimeout(searchTimer);
  offset = 0; area = "all"; document.querySelector('input[name=area][value=all]').checked = true;
  for (const id of ["token", "password", "config-file", "clip-text", "clip-name", "copy-text", "search"]) $(id).value = "";
  $("entries").replaceChildren(); $("history").hidden = true; $("connection").hidden = false; $("disconnect").hidden = true;
  $("page-links").replaceChildren(); $("page-links-top").replaceChildren(); $("page-number").textContent = "";
  if ($("copy-dialog").open) $("copy-dialog").close();
  if ($("clip-dialog").open) $("clip-dialog").close();
  if ($("rich-dialog").open) $("rich-dialog").close();
  clearRichView();
  setBusy(false); status(message);
}
async function startWorker() {
  if (worker) return workerReady;
  worker = new Worker("./worker.js");
  const activeWorker = worker;
  workerReady = new Promise((resolve, reject) => {
    const timer = setTimeout(() => { cancelWorkerStart = null; reject(new Error("Browser client did not start.")); }, 30000);
    cancelWorkerStart = () => { clearTimeout(timer); reject(new Error("Disconnected.")); };
    worker.onmessage = event => {
      if (worker !== activeWorker) return;
      const result = event.data;
      if (result.ready) { clearTimeout(timer); cancelWorkerStart = null; resolve(); return; }
      if (result.startupError) { clearTimeout(timer); cancelWorkerStart = null; reject(new Error(result.startupError)); return; }
      const task = pending.get(result.id);
      if (!task) return;
      pending.delete(result.id);
      result.error ? task.reject(new Error(result.error)) : task.resolve(result);
    };
    worker.onerror = () => { if (worker !== activeWorker) return; clearTimeout(timer); cancelWorkerStart = null; reject(new Error("Browser client failed.")); disconnect("Browser client failed; disconnected."); };
  });
  return workerReady;
}
async function request(action, data = {}) {
  const generation = sessionGeneration;
  await startWorker();
  if (generation !== sessionGeneration || !worker) throw new Error("Disconnected.");
  return new Promise((resolve, reject) => {
    const id = ++serial;
    const timer = setTimeout(() => { pending.delete(id); reject(new Error("Request timed out. Refresh before retrying a clip.")); disconnect("Connection timed out; disconnected." ); }, 60000);
    pending.set(id, { resolve: result => { clearTimeout(timer); resolve(result); }, reject: error => { clearTimeout(timer); reject(error); } });
    worker.postMessage({ id, Action: action, Query: $("search").value, Offset: offset, Area: area, ...data });
  });
}
function render(page) {
  pageState = page;
  offset = page.offset;
  const fragment = document.createDocumentFragment();
  for (const row of page.rows) {
    const item = document.createElement("li");
    const title = document.createElement("h3"); title.textContent = (row.pinned ? "Pinned. " : "") + (row.name || row.text.slice(0, 90));
    const text = document.createElement("p"); text.textContent = row.text + (row.truncated ? "\n[Preview shortened]" : "");
    const metadata = document.createElement("p"); metadata.className = "metadata";
    metadata.textContent = [row.device, row.group, row.created ? new Date(row.created).toLocaleString() : ""].filter(Boolean).join(". ");
    const copy = document.createElement("button"); copy.textContent = row.rich ? row.rtfOnly ? "Copy plain text" : "Copy formatted" : "Copy";
    copy.setAttribute("aria-label", copy.textContent + " " + (row.name || row.text.slice(0, 90)));
    copy.addEventListener("click", () => row.rich ? copyRichEntry(row) : copyEntry(row.id));
    item.append(title, text, metadata);
    if (row.rich) {
      const view = document.createElement("button"); view.textContent = "View entry";
      view.setAttribute("aria-label", "View " + (row.name || row.text.slice(0, 90)));
      view.addEventListener("click", () => viewRichEntry(row)); item.append(view);
    }
    item.append(copy);
    const destination = ClipmanLinks.target(row);
    if (destination) {
      const open = document.createElement("a");
      open.textContent = (row.name.trim() || destination) + " (opens in new tab)";
      open.href = destination; open.target = "_blank"; open.rel = "noopener noreferrer";
      open.className = "open-link"; item.append(open);
    }
    fragment.append(item);
  }
  if (!page.rows.length) { const empty = document.createElement("li"); empty.textContent = "No matching entries."; fragment.append(empty); }
  $("entries").replaceChildren(fragment);
  const label = area === "all" ? "Text and Links" : area === "text" ? "Text" : area === "rich" ? "Rich Text" : "Links";
  $("history-title").textContent = `${label} history`;
  $("entries").setAttribute("aria-label", `${label} history`);
  const current = Math.floor(offset / page.size) + 1, total = Math.ceil(page.total / page.size);
  $("page-number").textContent = page.total ? `Page ${current} of ${total}. Entries ${offset + 1}-${offset + page.rows.length} of ${page.total}.` : "0 entries";
  renderPagination(current, total);
  return `${page.total} clipboard ${page.total === 1 ? "entry" : "entries"}. ${label} history.${total ? ` Page ${current} of ${total}.` : ""} Server sync connected.`;
}
function renderPagination(current, total) {
  const focused = document.activeElement;
  for (const suffix of ["", "-top"]) {
    const container = $("page-links" + suffix);
    const focusedNumber = container.contains(focused) ? focused.dataset.page : null;
    const fragment = document.createDocumentFragment();
    let previous = 0;
    for (const page of ClipmanPaging.pages(total, current)) {
      if (previous && page > previous + 1) {
        const gap = document.createElement("span"); gap.textContent = "..."; gap.setAttribute("aria-hidden", "true"); fragment.append(gap);
      }
      const button = document.createElement("button"); button.textContent = String(page); button.dataset.page = String(page);
      button.setAttribute("aria-label", `Page ${page}`);
      if (page === current) button.setAttribute("aria-current", "page");
      button.addEventListener("click", () => goToPage(page)); fragment.append(button); previous = page;
    }
    container.replaceChildren(fragment);
    $("previous" + suffix).disabled = current <= 1;
    $("next" + suffix).disabled = current >= total;
    if (focusedNumber || (focused === $("previous" + suffix) || focused === $("next" + suffix)) && focused.disabled) {
      const target = container.querySelector(`[data-page="${focusedNumber}"]`) || container.querySelector('[aria-current="page"]');
      if (target) target.focus(); else $("search").focus();
    }
  }
}
async function goToPage(page) {
  if (busy || !pageState || page < 1 || page > Math.ceil(pageState.total / pageState.size)) return;
  const nextOffset = (page - 1) * pageState.size;
  if (nextOffset === offset) return;
  const previousOffset = offset; offset = nextOffset;
  if (!await run("page")) offset = previousOffset;
}
async function run(action, data = {}, success = "") {
  if (busy) return;
  const generation = sessionGeneration;
  setBusy(true); status(action === "add" ? "Adding clip; server sync in progress." : action === "rich" ? "Loading entry." : "Loading history.");
  try {
    const result = await request(action, data);
    if (generation !== sessionGeneration) return null;
    setBusy(false);
    const summary = result.page ? render(result.page) : "";
    status(success || summary);
    touch(); return result;
  } catch (error) {
    if (generation === sessionGeneration) { setBusy(false); status(error.message); }
    return null;
  }
}
async function copyEntry(id) {
  const generation = sessionGeneration;
  const result = await run("copy", { EntryID: id });
  if (!result) return;
  try { await navigator.clipboard.writeText(result.text); if (generation === sessionGeneration) status("Copied entry."); }
  catch (_) {
    if (generation !== sessionGeneration) return;
    $("copy-text").value = result.text; $("copy-dialog").showModal(); $("copy-text").focus(); $("copy-text").select(); status("Clipboard access unavailable. Copy the selected text, or press Copy.");
  }
}
function clearRichView() {
  richDocument = null; $("rich-content").replaceChildren(); $("rich-format").textContent = ""; $("rich-title").textContent = "View entry";
}
function plainFallback(text, message) {
  $("copy-text").value = text; $("copy-dialog").showModal(); $("copy-text").focus(); $("copy-text").select(); status(message);
}
async function viewRichEntry(row) {
  const result = await run("rich", {EntryID: row.id});
  if (!result) return;
  try {
    richDocument = result.rich;
    $("rich-title").textContent = row.name || "View entry";
    $("rich-format").textContent = richDocument.rtfOnly ? "RTF only. Plain-text preview." : "Formatted content";
    if (richDocument.rtfOnly) { const text=document.createElement("pre"); text.textContent=richDocument.text; $("rich-content").replaceChildren(text); }
    else $("rich-content").replaceChildren(ClipmanRich.clean(richDocument.html, true));
    $("copy-rich").textContent = richDocument.rtfOnly ? "Copy plain text" : "Copy formatted";
    $("rich-dialog").showModal(); $("rich-content").focus(); status("Entry opened.");
  } catch (_) { clearRichView(); status("Formatted content could not be displayed safely."); }
}
async function copyRichEntry(row) {
  if (busy) return;
  const generation = sessionGeneration;
  const loaded = run("rich", {EntryID:row.id});
  try {
    if (row.rtfOnly) {
      const result=await loaded; if (!result) return;
      await navigator.clipboard.writeText(result.rich.text); if (generation === sessionGeneration) status("Copied plain text. Browser RTF copying is unavailable."); return;
    }
    // Give the browser the clipboard request during the user's click gesture.
    if (!globalThis.ClipboardItem || !navigator.clipboard?.write) throw new Error("Formatted clipboard unavailable.");
    const document=loaded.then(result=>{ if (!result) throw new Error("Could not load entry."); return result.rich; });
    const data={
      "text/plain": document.then(value=>new Blob([value.text],{type:"text/plain"})),
      "text/html": document.then(value=>new Blob([ClipmanRich.clean(value.html)],{type:"text/html"}))
    };
    if (row.image) data["image/png"] = document.then(value=>ClipmanRich.pngBlob(value));
    await navigator.clipboard.write([new ClipboardItem(data)]);
    if (generation === sessionGeneration) status("Copied formatted entry.");
  } catch (_) {
    const result=await loaded;
    if (result && generation === sessionGeneration) plainFallback(result.rich.text,"Formatted clipboard access unavailable. Copy the selected plain text instead.");
  }
}
$("close-rich").addEventListener("click", () => $("rich-dialog").close());
$("rich-dialog").addEventListener("close", clearRichView);
$("copy-rich").addEventListener("click", async () => {
  if (busy || !richDocument) return;
  const generation = sessionGeneration;
  const value = richDocument;
  try {
    if (value.rtfOnly) { await navigator.clipboard.writeText(value.text); if (generation === sessionGeneration) status("Copied plain text. Browser RTF copying is unavailable."); }
    else { await navigator.clipboard.write([ClipmanRich.clipboardItem(value)]); if (generation === sessionGeneration) status("Copied formatted entry."); }
  } catch (_) { if (generation === sessionGeneration) status("Clipboard access unavailable. Close this viewer and use the entry's Copy button for a plain-text fallback."); }
});
$("connect-form").addEventListener("submit", async event => {
  event.preventDefault();
  if (busy || !settings) return;
  const data = { Token: $("token").value, Password: $("password").value, Device: $("device").value, Endpoint: settings.direct ? location.origin : location.origin + "/relay", Key: settings.key || "" };
  $("token").value = ""; $("password").value = "";
  const result = await run("connect", data);
  data.Token = ""; data.Password = "";
  if (!result) { disconnect($("status").textContent); return; }
  connected = true; $("connection").hidden = true; $("history").hidden = false; $("disconnect").hidden = false;
  $("config-file").value = ""; $("search").focus(); touch();
});
$("config-file").addEventListener("change", async () => {
  const file = $("config-file").files[0];
  if (!file) return;
  const generation = sessionGeneration;
  try {
    if (file.size > 32768) throw new Error("Connection file is too large.");
    const config = JSON.parse(await file.text());
    if (generation !== sessionGeneration) return;
    if (config.clipman !== "server-connection" || config.version !== 1) throw new Error("Unsupported connection file.");
    const normalize = address => new URL(address.replace(/^clipman:/, "http:")).href.replace(/\/$/, "");
    if (normalize(config.address) !== normalize(settings.server)) throw new Error("This preview is bound to a different server.");
    $("token").value = config.token || ""; status("Server connection loaded. Enter your history password.");
  } catch (error) { if (generation === sessionGeneration) status(error.message); }
});
$("disconnect").addEventListener("click", () => { disconnect(); $("token").focus(); });
$("refresh").addEventListener("click", () => run("refresh"));
$("new-clip").addEventListener("click", () => { if (busy) return; $("clip-dialog").showModal(); $("clip-text").focus(); });
$("close-clip").addEventListener("click", () => $("clip-dialog").close());
function searchWhenReady() {
  if (busy) { searchTimer = setTimeout(searchWhenReady, 150); return; }
  offset = 0; run("page");
}
$("search").addEventListener("input", () => { clearTimeout(searchTimer); searchTimer = setTimeout(searchWhenReady, 150); });
for (const suffix of ["", "-top"]) {
  $("previous" + suffix).addEventListener("click", () => { if (pageState) goToPage(Math.floor(offset / pageState.size)); });
  $("next" + suffix).addEventListener("click", () => { if (pageState) goToPage(Math.floor(offset / pageState.size) + 2); });
}
$("history-area").addEventListener("change", event => {
  if (busy) { document.querySelector(`input[name=area][value=${area}]`).checked = true; return; }
  area = event.target.value; offset = 0;
  clearTimeout(searchTimer); run("page");
});
$("clip-form").addEventListener("submit", async event => {
  event.preventDefault();
  if (busy) return;
  const text = $("clip-text").value, name = $("clip-name").value;
  const result = await run("add", { Text: text, Name: name }, "Clip saved to server.");
  if (result && $("clip-text").value === text && $("clip-name").value === name) { $("clip-text").value = ""; $("clip-name").value = ""; $("clip-dialog").close(); }
});
$("clip-form").addEventListener("keydown", event => {
  if (event.key !== "Enter" || !(event.ctrlKey || event.metaKey) || event.altKey || event.shiftKey) return;
  event.preventDefault();
  if (event.repeat || event.isComposing || busy || !$("clip-dialog").open) return;
  $("clip-form").requestSubmit();
});
$("paste").addEventListener("click", async () => {
  if (busy) return;
  const generation = sessionGeneration;
  try {
    const text = await navigator.clipboard.readText();
    if (generation !== sessionGeneration) return;
    $("clip-text").value = text; status(text ? "Clipboard text loaded." : "Nothing to paste.");
  } catch (_) { if (generation === sessionGeneration) { status("Clipboard access unavailable. Paste directly into Text or link."); $("clip-text").focus(); } }
});
$("close-copy").addEventListener("click", () => { $("copy-dialog").close(); $("copy-text").value = ""; });
$("copy-dialog").addEventListener("close", () => { $("copy-text").value = ""; });
$("copy-again").addEventListener("click", async () => { if (busy) return; try { await navigator.clipboard.writeText($("copy-text").value); $("copy-dialog").close(); status("Copied entry."); } catch (_) { $("copy-text").focus(); $("copy-text").select(); status("Use your browser's Copy command on the selected text."); } });
document.addEventListener("keydown", touch); document.addEventListener("pointerdown", touch);
window.addEventListener("pagehide", () => disconnect());
(async () => {
  const generation = sessionGeneration;
  try {
    const response = await fetch("./preview.json", { cache: "no-store", credentials: "omit" });
    if (!response.ok) throw new Error("Browser access unavailable.");
    settings = await response.json();
    if (generation !== sessionGeneration) return;
    if (settings.direct && (location.protocol !== "https:" || settings.server !== location.origin || !isSecureContext)) throw new Error("HTTPS required.");
    $("server").textContent = settings.server; $("token").value = settings.token || ""; delete settings.token;
    await startWorker(); if (generation === sessionGeneration) status("Ready to connect.");
  } catch (_) { if (generation === sessionGeneration) { status("Could not load Clipman. Server-hosted browser access requires HTTPS."); $("connect").disabled = true; } }
})();

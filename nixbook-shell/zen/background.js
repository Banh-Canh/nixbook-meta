// nixbook's desktop agents in the browser (nixbook-desktop-mcp's browser_*
// tools): their requests come from the nixbook-zen-bridge native host (a
// private Unix socket on the other side), are done here through the
// WebExtension APIs and the page itself, and answered. No mouse, no
// keyboard: tabs in the background, in another Zen workspace or behind
// another window work the same, and the user keeps working meanwhile.
//
// The page-side code (nixbookPage) is injected only when a tool asks for it.
// Off limits, whatever the agent asks: private windows, password fields, and
// the tabs the request's guard names (sites by regex, containers by name;
// desktop-mcp sends its settings with every request).
"use strict";

const HOST = "nixbook_zen";
let port = null;

function connect() {
  try {
    port = browser.runtime.connectNative(HOST);
  } catch (e) {
    port = null;
    setTimeout(connect, 10000);
    return;
  }
  port.onMessage.addListener(async (msg) => {
    let reply;
    try {
      reply = { id: msg.id, ok: true, result: await handle(msg) };
    } catch (e) {
      reply = { id: msg.id, ok: false, error: String((e && e.message) || e) };
    }
    if (port) port.postMessage(reply);
  });
  // The host gone (Zen keeps no host running when it isn't needed, or it
  // crashed): connected again a little later.
  port.onDisconnect.addListener(() => {
    port = null;
    setTimeout(connect, 5000);
  });
}
connect();

// ── Tabs ──
const containerNames = new Map();
async function containerOf(tab) {
  const id = tab.cookieStoreId;
  if (!id || id === "firefox-default") return "";
  if (!containerNames.has(id)) {
    try {
      containerNames.set(id, (await browser.contextualIdentities.get(id)).name);
    } catch (e) {
      containerNames.set(id, "");
    }
  }
  return containerNames.get(id);
}

function refusedWhy(tab, container, guard) {
  if (tab.incognito) return "a private window";
  const g = guard || {};
  if (
    (g.containers || []).some(
      (c) => c.toLowerCase() === container.toLowerCase() && c,
    )
  )
    return `the ${container} container`;
  for (const s of g.sites || []) {
    try {
      if (new RegExp(s, "i").test(tab.url || ""))
        return "a site the agents may not use";
    } catch (e) {}
  }
  return "";
}

function urlRefused(url, guard) {
  if (!/^https?:\/\//i.test(url)) return "only http and https addresses";
  for (const s of (guard || {}).sites || []) {
    try {
      if (new RegExp(s, "i").test(url)) return "a site the agents may not use";
    } catch (e) {}
  }
  return "";
}

async function describe(tab, guard) {
  const container = await containerOf(tab);
  const out = {
    id: tab.id,
    window: tab.windowId,
    active: tab.active,
    container: container || undefined,
    pinned: tab.pinned || undefined,
    audible: tab.audible || undefined,
    // Zen hides the tabs of its other workspaces.
    otherWorkspace: tab.hidden || undefined,
    loading: tab.status === "loading" || undefined,
  };
  const why = refusedWhy(tab, container, guard);
  if (why) out.private = why;
  else {
    out.title = tab.title;
    out.url = tab.url;
  }
  return out;
}

// The tab asked for (by id), or the one shown in the last focused window.
async function tabFor(msg, allowRefused = false) {
  let tab;
  if (msg.tab !== undefined && msg.tab !== null) {
    try {
      tab = await browser.tabs.get(Number(msg.tab));
    } catch (e) {
      throw new Error(`no tab ${msg.tab} (browser_tabs lists them)`);
    }
  } else {
    [tab] = await browser.tabs.query({ active: true, lastFocusedWindow: true });
    if (!tab) throw new Error("no tab: give `tab` (browser_tabs lists them)");
  }
  if (!allowRefused) {
    const why = refusedWhy(tab, await containerOf(tab), msg.guard);
    if (why)
      throw new Error(
        `refused: tab ${tab.id} is in ${why}; ask the user to do this themselves`,
      );
  }
  return tab;
}

function sleep(ms) {
  return new Promise((r) => setTimeout(r, ms));
}

async function waitLoaded(tabId, ms) {
  const end = Date.now() + ms;
  while (Date.now() < end) {
    const t = await browser.tabs.get(tabId);
    if (t.status === "complete") return true;
    await sleep(200);
  }
  return false;
}

async function inPage(tab, op, o) {
  const code = `(${nixbookPage.toString()})(${JSON.stringify(op)}, ${JSON.stringify(o || {})})`;
  let results;
  try {
    results = await browser.tabs.executeScript(tab.id, {
      code,
      runAt: "document_idle",
    });
  } catch (e) {
    throw new Error(
      `the page can't be read (${(e && e.message) || e}): a browser page, or still loading`,
    );
  }
  const r = results && results[0];
  if (r && r.error) throw new Error(r.error);
  return r;
}

async function handle(msg) {
  const guard = msg.guard;
  switch (msg.cmd) {
    case "ping":
      return { ok: true, version: browser.runtime.getManifest().version };
    case "tabs": {
      const tabs = await browser.tabs.query({});
      const out = [];
      for (const t of tabs)
        if (!t.incognito) out.push(await describe(t, guard));
      return out;
    }
    case "open": {
      const why = urlRefused(String(msg.url || ""), guard);
      if (why) throw new Error(`refused: ${why}`);
      // In the background unless asked: the user's view doesn't move.
      const tab = await browser.tabs.create({
        url: msg.url,
        active: !!msg.active,
      });
      if (msg.wait !== false) await waitLoaded(tab.id, 15000);
      return describe(await browser.tabs.get(tab.id), guard);
    }
    case "tab": {
      const tab = await tabFor(msg, msg.action === "close");
      switch (msg.action) {
        case "activate":
          await browser.tabs.update(tab.id, { active: true });
          break;
        case "close":
          await browser.tabs.remove(tab.id);
          return { closed: tab.id };
        case "reload":
          await browser.tabs.reload(tab.id);
          break;
        case "back":
          await browser.tabs.goBack(tab.id);
          break;
        case "forward":
          await browser.tabs.goForward(tab.id);
          break;
        case "navigate": {
          const why = urlRefused(String(msg.url || ""), guard);
          if (why) throw new Error(`refused: ${why}`);
          await browser.tabs.update(tab.id, { url: msg.url });
          break;
        }
        case "mute":
        case "unmute":
          await browser.tabs.update(tab.id, { muted: msg.action === "mute" });
          break;
        default:
          throw new Error(
            "action: activate, close, reload, back, forward, navigate, mute or unmute",
          );
      }
      await sleep(300);
      await waitLoaded(tab.id, 15000);
      return describe(await browser.tabs.get(tab.id), guard);
    }
    case "read": {
      const tab = await tabFor(msg);
      const r = await inPage(tab, "read", {
        text: msg.text !== false,
        chars: Math.max(500, Math.min(60000, Number(msg.chars) || 12000)),
        max: Math.max(10, Math.min(400, Number(msg.max) || 150)),
        query: msg.query || "",
      });
      r.tab = tab.id;
      return r;
    }
    case "act": {
      const tab = await tabFor(msg);
      const r = await inPage(tab, "act", {
        ref: msg.ref,
        name: msg.name,
        action: msg.action,
        value: msg.value,
        append: !!msg.append,
      });
      // A click that navigates: its page, once loaded.
      await sleep(400);
      await waitLoaded(tab.id, 10000);
      const after = await browser.tabs.get(tab.id);
      r.tab = tab.id;
      r.url = after.url;
      r.title = after.title;
      return r;
    }
    case "wait": {
      const tab = await tabFor(msg);
      const end =
        Date.now() +
        Math.max(100, Math.min(30000, Number(msg.timeout) || 10000));
      while (Date.now() < end) {
        const t = await browser.tabs.get(tab.id);
        if (
          msg.until === "url"
            ? (t.url || "").includes(msg.text || "")
            : t.status === "complete"
        ) {
          if (msg.until !== "text")
            return { tab: t.id, url: t.url, title: t.title, ok: true };
          try {
            const r = await inPage(t, "has", { text: msg.text });
            if (r && r.found)
              return { tab: t.id, url: t.url, title: t.title, ok: true };
          } catch (e) {}
        }
        await sleep(300);
      }
      return { tab: tab.id, ok: false };
    }
    case "screenshot": {
      const tab = await tabFor(msg);
      const data = await browser.tabs.captureTab(tab.id, {
        format: "jpeg",
        quality: 80,
      });
      return { tab: tab.id, title: tab.title, url: tab.url, data };
    }
    default:
      throw new Error(`unknown command ${msg.cmd}`);
  }
}

// ── In the page (the extension's isolated world: the page's own scripts
// can't see this code nor the references it keeps) ──
function nixbookPage(op, o) {
  const clean = (s) =>
    String(s || "")
      .replace(/\s+/g, " ")
      .trim();
  const isPassword = (el) =>
    el.tagName === "INPUT" && (el.type || "").toLowerCase() === "password";
  const visible = (el) => {
    const r = el.getBoundingClientRect();
    if (r.width < 1 || r.height < 1) return false;
    const s = getComputedStyle(el);
    return s.visibility !== "hidden" && s.display !== "none";
  };
  const TAGS = {
    a: "link",
    button: "button",
    select: "list",
    textarea: "text field",
    summary: "summary",
  };
  const role = (el) => {
    const r = el.getAttribute("role");
    if (r) return r;
    const t = el.tagName.toLowerCase();
    if (t === "input") {
      const ty = (el.type || "text").toLowerCase();
      if (ty === "password") return "password field";
      if (["submit", "button", "reset", "image"].includes(ty)) return "button";
      if (
        [
          "checkbox",
          "radio",
          "file",
          "range",
          "color",
          "date",
          "time",
          "datetime-local",
          "month",
          "week",
        ].includes(ty)
      )
        return ty;
      return "text field";
    }
    if (el.isContentEditable) return "text editor";
    return TAGS[t] || t;
  };
  const label = (el) => {
    const by = (el.getAttribute("aria-labelledby") || "")
      .split(/\s+/)
      .map((id) =>
        id && document.getElementById(id)
          ? document.getElementById(id).innerText
          : "",
      )
      .join(" ");
    const labels =
      el.labels && el.labels.length
        ? Array.from(el.labels)
            .map((l) => l.innerText)
            .join(" ")
        : "";
    let own = "";
    if (!["INPUT", "TEXTAREA", "SELECT"].includes(el.tagName))
      own = el.innerText || el.textContent;
    else if (
      ["submit", "button", "reset"].includes((el.type || "").toLowerCase())
    )
      own = el.value;
    return clean(
      el.getAttribute("aria-label") ||
        by ||
        labels ||
        own ||
        el.getAttribute("title") ||
        el.getAttribute("placeholder") ||
        el.getAttribute("alt") ||
        el.getAttribute("name") ||
        "",
    ).slice(0, 120);
  };
  const refs = (window.__nixbookRefs = window.__nixbookRefs || {
    map: new Map(),
  });

  if (op === "has") {
    const t = clean(o.text).toLowerCase();
    return {
      found:
        !!t &&
        clean(document.body ? document.body.innerText : "")
          .toLowerCase()
          .includes(t),
    };
  }

  if (op === "read") {
    const SEL =
      'a[href], button, input:not([type="hidden"]), select, textarea, summary, [role="button"], [role="link"], ' +
      '[role="checkbox"], [role="radio"], [role="tab"], [role="menuitem"], [role="option"], [role="switch"], ' +
      '[role="textbox"], [role="combobox"], [role="searchbox"], [contenteditable=""], [contenteditable="true"]';
    const words = clean(o.query)
      .toLowerCase()
      .split(" ")
      .filter((w) => w);
    refs.map = new Map();
    let n = 0;
    let total = 0;
    const elements = [];
    for (const el of document.querySelectorAll(SEL)) {
      if (!visible(el)) continue;
      total++;
      const name = label(el);
      if (words.length && !words.some((w) => name.toLowerCase().includes(w)))
        continue;
      if (elements.length >= o.max) continue;
      const ref = ++n;
      refs.map.set(ref, el);
      const r = role(el);
      const e = { ref, role: r, name };
      if (r === "password field") e.password = true;
      else if (
        ["INPUT", "TEXTAREA", "SELECT"].includes(el.tagName) &&
        !["submit", "button", "reset", "checkbox", "radio", "image"].includes(
          (el.type || "").toLowerCase(),
        )
      ) {
        const v = clean(el.value).slice(0, 80);
        if (v) e.value = v;
      }
      if (el.type === "checkbox" || el.type === "radio") e.checked = el.checked;
      else if (el.getAttribute("aria-checked"))
        e.checked = el.getAttribute("aria-checked") === "true";
      if (el.getAttribute("aria-selected") === "true") e.selected = true;
      if (el.disabled || el.getAttribute("aria-disabled") === "true")
        e.disabled = true;
      if (el.tagName === "A" && el.href) e.href = el.href.slice(0, 200);
      if (el.tagName === "SELECT")
        e.options = Array.from(el.options)
          .slice(0, 25)
          .map((x) => clean(x.label || x.text));
      const box = el.getBoundingClientRect();
      if (box.bottom < 0 || box.top > innerHeight) e.offscreen = true;
      elements.push(e);
    }
    let text = "";
    if (o.text) {
      const root =
        document.querySelector("main, article, [role='main']") || document.body;
      text = (root ? root.innerText : "").replace(/\n{3,}/g, "\n\n").trim();
    }
    return {
      title: document.title,
      url: location.href,
      text: text.slice(0, o.chars),
      textTotal: text.length,
      elements,
      shown: elements.length,
      total,
      selection: clean(String(getSelection())).slice(0, 500),
    };
  }

  if (op === "act") {
    const el = refs.map.get(Number(o.ref));
    if (!el || !el.isConnected)
      return { error: "the page changed since browser_read: read it again" };
    const now = label(el);
    const want = clean(o.name).toLowerCase();
    if (
      want &&
      !(now.toLowerCase().includes(want) || want.includes(now.toLowerCase()))
    )
      return {
        error: `element ${o.ref} is now ${JSON.stringify(now)}, not ${JSON.stringify(o.name)}: read the page again`,
      };
    if (isPassword(el))
      return {
        error:
          "refused: password fields are off limits; ask the user to do this step",
      };
    const fire = (target) => {
      target.scrollIntoView({ block: "center", inline: "center" });
      try {
        target.focus({ preventScroll: true });
      } catch (e) {}
      const b = target.getBoundingClientRect();
      const at = {
        bubbles: true,
        cancelable: true,
        composed: true,
        view: window,
        button: 0,
        clientX: b.x + b.width / 2,
        clientY: b.y + b.height / 2,
      };
      target.dispatchEvent(
        new PointerEvent(
          "pointerdown",
          Object.assign({ pointerType: "mouse", isPrimary: true }, at),
        ),
      );
      target.dispatchEvent(new MouseEvent("mousedown", at));
      target.dispatchEvent(
        new PointerEvent(
          "pointerup",
          Object.assign({ pointerType: "mouse", isPrimary: true }, at),
        ),
      );
      target.dispatchEvent(new MouseEvent("mouseup", at));
      target.click();
    };
    const changed = (target, data) => {
      target.dispatchEvent(
        new InputEvent("input", {
          bubbles: true,
          inputType: "insertText",
          data,
        }),
      );
      target.dispatchEvent(new Event("change", { bubbles: true }));
    };
    const value =
      o.value === undefined || o.value === null ? "" : String(o.value);
    switch (o.action) {
      case "click":
        fire(el);
        break;
      case "type":
        if (el.isContentEditable) {
          el.focus();
          if (!o.append) document.execCommand("selectAll", false);
          document.execCommand("insertText", false, value);
        } else if (["INPUT", "TEXTAREA"].includes(el.tagName)) {
          el.focus();
          // Through the browser's own setter (this world doesn't see the
          // page's overrides): React and the like see the change.
          el.value = o.append ? el.value + value : value;
          changed(el, value);
        } else
          return {
            error: `a ${role(el)} takes no text: click it, or pick a text field`,
          };
        break;
      case "select": {
        if (el.tagName !== "SELECT")
          return {
            error: "select is for lists (role list): click the option instead",
          };
        const w = value.toLowerCase();
        const opt =
          Array.from(el.options).find(
            (x) =>
              clean(x.label || x.text).toLowerCase() === w ||
              x.value.toLowerCase() === w,
          ) ||
          Array.from(el.options).find((x) =>
            clean(x.label || x.text)
              .toLowerCase()
              .includes(w),
          );
        if (!opt)
          return {
            error: `no option ${JSON.stringify(value)} (they are: ${Array.from(
              el.options,
            )
              .map((x) => clean(x.text))
              .join(", ")})`,
          };
        el.value = opt.value;
        changed(el, opt.value);
        break;
      }
      case "check": {
        const on = !["false", "0", "off", "no"].includes(value.toLowerCase());
        const state =
          el.type === "checkbox" || el.type === "radio"
            ? el.checked
            : el.getAttribute("aria-checked") === "true";
        if (state !== on) fire(el);
        break;
      }
      case "submit": {
        const form = el.form || el.closest("form");
        if (!form) return { error: "not in a form: click its button instead" };
        const isSubmit =
          (el.tagName === "BUTTON" || el.tagName === "INPUT") &&
          (el.type || "").toLowerCase() === "submit";
        form.requestSubmit(isSubmit ? el : undefined);
        break;
      }
      case "press": {
        const key = value || "Enter";
        el.focus();
        for (const type of ["keydown", "keypress", "keyup"])
          el.dispatchEvent(
            new KeyboardEvent(type, {
              key,
              code: key.length === 1 ? `Key${key.toUpperCase()}` : key,
              bubbles: true,
              cancelable: true,
            }),
          );
        // Pages don't act on a synthetic Enter: the form is sent the way it would be.
        if (key === "Enter" && el.form && el.tagName === "INPUT")
          el.form.requestSubmit();
        break;
      }
      case "focus":
        el.focus();
        break;
      case "scroll":
        el.scrollIntoView({ block: "center" });
        break;
      default:
        return {
          error:
            "action: click, type, select, check, submit, press, focus or scroll",
        };
    }
    const after = el.isConnected ? { role: role(el), name: label(el) } : null;
    if (
      after &&
      ["INPUT", "TEXTAREA", "SELECT"].includes(el.tagName) &&
      !isPassword(el)
    )
      after.value = clean(el.value).slice(0, 80);
    if (after && (el.type === "checkbox" || el.type === "radio"))
      after.checked = el.checked;
    return { done: o.action, element: after };
  }
  return { error: `unknown page operation ${op}` };
}

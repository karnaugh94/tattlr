/* tattlr: right-click feedback / bug report menu for shiny apps */
(function () {
  "use strict";
  // use_tattlr() in the UI plus the copy injected by tattlr_server(): only run once
  if (window.tattlr) return;
  window.tattlr = {};

  // html-to-image.js sits next to this file and is only loaded when needed
  var scriptSrc = (document.currentScript && document.currentScript.src) || "";
  var cfgEl = document.getElementById("tattlr-config");
  var cfg = { button: false, buttonPosition: "bottom-right", label: "Send feedback / report bug", consoleBuffer: 20,
    inputLog: 30, autoErrors: false, autoErrorsPrompt: false, autoErrorsLimit: 5, screenshot: false };
  function readConfig() {
    cfgEl = cfgEl || document.getElementById("tattlr-config");
    if (cfgEl) {
      try { Object.assign(cfg, JSON.parse(cfgEl.textContent)); } catch (e) {}
    }
  }
  readConfig();

  /* ---- console error buffer (starts as early as possible) ---- */
  var consoleErrors = [];
  var IGNORE = /ResizeObserver loop/;
  function pushError(kind, msg) {
    msg = String(msg).slice(0, 1000);
    if (IGNORE.test(msg)) return;
    var last = consoleErrors[consoleErrors.length - 1];
    if (last && last.kind === kind && last.message === msg) { last.count = (last.count || 1) + 1; return; }
    consoleErrors.push({ time: new Date().toISOString(), kind: kind, message: msg });
    while (consoleErrors.length > (cfg.consoleBuffer || 20)) consoleErrors.shift();
  }
  var origError = console.error;
  console.error = function () {
    try {
      pushError("console.error", Array.prototype.map.call(arguments, function (a) {
        if (a instanceof Error) return a.stack || a.message;
        if (typeof a === "object") { try { return JSON.stringify(a); } catch (e) { return String(a); } }
        return String(a);
      }).join(" "));
    } catch (e) {}
    return origError.apply(console, arguments);
  };
  window.addEventListener("error", function (e) {
    pushError("window.onerror", (e.message || "") + (e.filename ? " (" + e.filename + ":" + e.lineno + ")" : ""));
  });
  window.addEventListener("unhandledrejection", function (e) {
    pushError("unhandledrejection", e.reason && (e.reason.stack || e.reason.message) || e.reason);
  });

  /* ---- input log: recent input changes, for "steps before the report" ---- */
  var inputLog = [];
  function logInput(e) {
    if (!cfg.inputLog || !e.name || e.name.charAt(0) === ".") return;
    var value;
    if (e.el && e.el.type === "password") value = '"<redacted>"';
    else { try { value = JSON.stringify(e.value); } catch (err) { value = String(e.value); } }
    if (value === undefined) value = "null";
    if (value.length > 300) value = value.slice(0, 300) + "...";
    var now = Date.now(), entry = { t: now, time: new Date(now).toISOString(), name: e.name, value: value };
    // typing or dragging a slider fires many changes: keep the latest one. Look
    // a few entries back, since some frameworks echo each change into another
    // input (shinyMobile's lastInputChanged)
    for (var i = inputLog.length - 1; i >= Math.max(0, inputLog.length - 3); i--) {
      if (now - inputLog[i].t >= 1500) break;
      if (inputLog[i].name === e.name) { inputLog.splice(i, 1); break; }
    }
    inputLog.push(entry);
    while (inputLog.length > cfg.inputLog) inputLog.shift();
  }

  /* ---- automatic error reports (outputs that fail to render) ---- */
  var autoSent = {}, autoCount = 0;
  function onOutputError(e) {
    if (!cfg.autoErrors || !e.name || !e.error) return;
    var type = [].concat(e.error.type || []);
    if (type.indexOf("shiny.silent.error") >= 0 || type.indexOf("validation") >= 0) return;
    var key = e.name + "|" + e.error.message;
    if (autoSent[key] || autoCount >= cfg.autoErrorsLimit) return;
    autoSent[key] = true;
    autoCount++;
    var el = document.getElementById(e.name) || document.body;
    // let the error render first, so the context sees the output in its error state
    setTimeout(function () {
      Shiny.setInputValue(".tattlr_auto_error", {
        output_id: e.name, message: e.error.message, call: e.error.call || null, type: type,
        context: collectContext(el)
      }, { priority: "event" });
      if (cfg.autoErrorsPrompt) {
        toast("Something went wrong and was reported automatically.", false, {
          label: "Add details", onclick: function () { openModal(el, { subject: "Error in " + e.name }); }
        });
      }
    }, 0);
  }

  /* ---- context collection ---- */
  function cssPath(el) {
    var parts = [];
    while (el && el.nodeType === 1 && parts.length < 5) {
      if (el.id) { parts.unshift("#" + el.id); break; }
      var sel = el.tagName.toLowerCase();
      var cls = (el.getAttribute("class") || "").trim().split(/\s+/).filter(Boolean)
        .filter(function (c) { return c.indexOf("tattlr") !== 0; }).slice(0, 2);
      if (cls.length) sel += "." + cls.join(".");
      var parent = el.parentElement;
      if (parent) {
        var same = Array.prototype.filter.call(parent.children, function (c) { return c.tagName === el.tagName; });
        if (same.length > 1) sel += ":nth-of-type(" + (same.indexOf(el) + 1) + ")";
      }
      parts.unshift(sel);
      el = parent;
    }
    return parts.join(" > ");
  }

  function namespaceOf(id) {
    if (!id || id.indexOf("-") < 0) return null;
    return id.slice(0, id.lastIndexOf("-"));
  }

  function closest(el, sel) { return el && el.closest ? el.closest(sel) : null; }
  function cssEscape(x) { return window.CSS && CSS.escape ? CSS.escape(x) : x.replace(/"/g, '\\"'); }

  /* match the app's light/dark look rather than the OS setting */
  function isDark() {
    var html = document.documentElement, body = document.body;
    if (html.getAttribute("data-bs-theme") === "dark" || body.getAttribute("data-bs-theme") === "dark") return true;
    if (html.getAttribute("data-bs-theme") === "light") return false;
    if (/(^|\s)(dark|dark-mode|theme-dark)(\s|$)/.test(html.className + " " + body.className)) return true;
    var els = [body, html];
    for (var i = 0; i < els.length; i++) {
      var m = getComputedStyle(els[i]).backgroundColor.match(/rgba?\(([^)]+)\)/);
      if (!m) continue;
      var v = m[1].split(",").map(parseFloat);
      if (v.length > 3 && v[3] < 0.1) continue;
      return 0.2126 * v[0] + 0.7152 * v[1] + 0.0722 * v[2] < 128;
    }
    return !!(window.matchMedia && window.matchMedia("(prefers-color-scheme: dark)").matches);
  }
  function themed(cls) { return cls + (isDark() ? " tattlr-dark" : ""); }

  /* an open Bootstrap modal traps focus, so mount inside it when there is one */
  function host() { return document.querySelector(".modal.show, .modal.in") || document.body; }

  function collectContext(target) {
    var isBody = !target || target === document.body || target === document.documentElement;
    var container = closest(target, ".shiny-input-container");
    var input = closest(target, ".shiny-bound-input") ||
      (container && container.querySelector(".shiny-bound-input"));
    var output = closest(target, ".shiny-bound-output");
    var withId = closest(target, "[id]");
    // only shiny-bound ids follow the module "ns-id" convention
    var boundId = (input && input.id) || (output && output.id) || null;

    var PANE = ".tab-pane, .tabs > .tab";
    var pageChain = [];
    var pane = closest(target, PANE);
    while (pane) {
      pageChain.unshift(pane.getAttribute("data-value") || (pane.id || "").replace(/^shiny-tab-/, ""));
      pane = closest(pane.parentElement, PANE);
    }

    var tabsets = Array.prototype.map.call(document.querySelectorAll(".shiny-tab-input"), function (ul) {
      var a = ul.querySelector("a.active, li.active > a, .nav-link.active");
      return { id: ul.id || null, active: a ? (a.getAttribute("data-value") || a.textContent.trim()) : null };
    });

    var outputErrors = Array.prototype.map.call(document.querySelectorAll(".shiny-output-error"), function (el) {
      return {
        id: el.id || null,
        validation: el.className.indexOf("shiny-output-error-validation") >= 0,
        message: (el.textContent || "").trim().slice(0, 1000)
      };
    });

    var passwordIds = Array.prototype.map.call(document.querySelectorAll("input[type=password][id]"),
      function (el) { return el.id; });

    var label = (container && container.querySelector("label")) ||
      (input && input.id && document.querySelector('label[for="' + cssEscape(input.id) + '"]'));
    return {
      url: location.href,
      client_time: new Date().toISOString(),
      element: isBody ? null : {
        tag: target.tagName.toLowerCase(),
        id: target.id || null,
        classes: target.getAttribute("class") || null,
        text: (target.innerText || target.textContent || "").trim().replace(/\s+/g, " ").slice(0, 200),
        selector: cssPath(target),
        html: (target.outerHTML || "").slice(0, 600)
      },
      input_id: input ? input.id : null,
      input_label: label ? label.textContent.trim() : null,
      output_id: output ? output.id : null,
      nearest_id: withId ? withId.id : null,
      namespace: namespaceOf(boundId),
      page: pageChain,
      tabsets: tabsets,
      output_errors: outputErrors,
      password_inputs: passwordIds,
      console_errors: consoleErrors.slice(),
      input_log: inputLog.map(function (x) { return { time: x.time, name: x.name, value: x.value }; })
    };
  }

  function environmentInfo() {
    var n = navigator;
    var info = {
      user_agent: n.userAgent,
      platform: (n.userAgentData && n.userAgentData.platform) || n.platform,
      language: n.language,
      languages: n.languages ? Array.prototype.slice.call(n.languages) : null,
      screen: screen.width + "x" + screen.height,
      viewport: window.innerWidth + "x" + window.innerHeight,
      device_pixel_ratio: window.devicePixelRatio,
      timezone: (Intl.DateTimeFormat().resolvedOptions() || {}).timeZone,
      color_scheme: window.matchMedia && window.matchMedia("(prefers-color-scheme: dark)").matches ? "dark" : "light",
      touch: "ontouchstart" in window
    };
    if (n.userAgentData && n.userAgentData.brands) {
      info.browser = n.userAgentData.brands.map(function (b) { return b.brand + " " + b.version; }).join(", ");
    }
    return info;
  }

  /* ---- DOM helpers ---- */
  function h(tag, attrs, children) {
    var el = document.createElement(tag);
    Object.keys(attrs || {}).forEach(function (k) {
      if (k === "text") el.textContent = attrs[k];
      else if (k.indexOf("on") === 0) el.addEventListener(k.slice(2), attrs[k]);
      else el.setAttribute(k, attrs[k]);
    });
    (children || []).forEach(function (c) { if (c) el.appendChild(c); });
    return el;
  }

  /* ---- screenshot: opt-in, with free text and marked areas masked ---- */
  var libPromise = null;
  function loadLib() {
    if (window.htmlToImage) return Promise.resolve(window.htmlToImage);
    if (libPromise) return libPromise;
    var src = scriptSrc || (document.querySelector('script[src*="tattlr.js"]') || {}).src || "";
    libPromise = new Promise(function (resolve, reject) {
      var s = document.createElement("script");
      s.src = src.replace(/[^\/]*$/, "html-to-image.js");
      s.onload = function () {
        if (window.htmlToImage) resolve(window.htmlToImage); else reject(new Error("html-to-image did not load"));
      };
      s.onerror = function () { libPromise = null; reject(new Error("could not load html-to-image")); };
      document.head.appendChild(s);
    });
    return libPromise;
  }
  var NOT_IN_SHOT = /(^|\s)tattlr-(overlay|menu|toast|fab)(\s|$)/;
  function inShot(node) {
    if (node.nodeType !== 1) return true;
    // same-origin iframes would be copied without the masking styles
    if (node.tagName === "IFRAME") return false;
    if (typeof node.className === "string" && NOT_IN_SHOT.test(node.className)) return false;
    // hidden tabs and pages: copying them only slows big apps down
    return getComputedStyle(node).display !== "none";
  }
  function opaque(c) { return c && c !== "transparent" && !/rgba\(.*,\s*0\)$/.test(c); }
  var PIXEL = "data:image/gif;base64,R0lGODlhAQABAAAAACH5BAEKAAEALAAAAAABAAEAAAICTAEAOw==";
  // A JPEG data URL of what the user sees (the viewport), at most 1600px
  // wide. While it is taken, .tattlr-capturing on <html> blanks every
  // free-text field (sent to shiny or not) and anything marked .tattlr-mask
  // or [data-tattlr-mask]; the copy is made from those masked styles.
  function screenshot() {
    return loadLib().then(function (lib) {
      var root = document.documentElement, body = document.body;
      var vw = window.innerWidth, vh = window.innerHeight;
      var pw = Math.max(root.scrollWidth, vw), ph = Math.max(root.scrollHeight, vh);
      // canvases over ~16k px get scaled down, which would break the crop below
      var r = Math.min(window.devicePixelRatio || 1, 2, 1600 / vw, 16000 / ph, 16000 / pw);
      // <html>, not <body>: a first child's top margin collapses through body
      var at = root.getBoundingClientRect();
      var bg = getComputedStyle(body).backgroundColor;
      if (!opaque(bg)) bg = getComputedStyle(root).backgroundColor;
      if (!opaque(bg)) bg = isDark() ? "#212529" : "#ffffff";
      var opts = { pixelRatio: r, backgroundColor: bg, filter: inShot, imagePlaceholder: PIXEL,
        width: pw, height: ph, skipAutoScale: true,
        // CSS variables are already resolved in the other properties; copying
        // them onto every element (Framework7 and Bootstrap 5 define hundreds)
        // made the copy tens of MB and the capture time out
        includeStyleProperties: Array.prototype.filter.call(getComputedStyle(root),
          function (p) { return p.indexOf("--") !== 0; }) };
      // images and fonts are fetched again; don't let a slow host stall the capture
      if (window.AbortSignal && AbortSignal.timeout) opts.fetchRequestInit = { signal: AbortSignal.timeout(4000) };
      root.classList.add("tattlr-capturing");
      var done = function () { root.classList.remove("tattlr-capturing"); };
      var timeout = new Promise(function (_, reject) {
        setTimeout(function () { reject(new Error("the screenshot timed out")); }, 20000);
      });
      return Promise.race([lib.toCanvas(root, opts), timeout]).then(function (full) {
        done();
        var out = document.createElement("canvas");
        out.width = Math.round(vw * r); out.height = Math.round(vh * r);
        var ctx = out.getContext("2d");
        ctx.fillStyle = bg; ctx.fillRect(0, 0, out.width, out.height);
        // the copy starts at the page's top-left corner, which scrolling moves
        ctx.drawImage(full, Math.round(at.left * r), Math.round(at.top * r));
        return out.toDataURL("image/jpeg", 0.8);
      }, function (e) { done(); throw e; });
    });
  }

  /* ---- context menu ---- */
  var menu = null, pendingTarget = null;
  function hideMenu() { if (menu) { menu.remove(); menu = null; } }

  function showMenu(x, y, target) {
    hideMenu();
    pendingTarget = target;
    menu = h("div", { "class": themed("tattlr-menu"), role: "menu" }, [
      h("button", { type: "button", "class": "tattlr-menu-item", role: "menuitem", text: cfg.label,
        onclick: function () { hideMenu(); openModal(pendingTarget); } }),
      h("div", { "class": "tattlr-menu-hint", text: "Shift + right-click for the browser menu" })
    ]);
    host().appendChild(menu);
    var r = menu.getBoundingClientRect();
    menu.style.left = Math.min(x, window.innerWidth - r.width - 4) + "px";
    menu.style.top = Math.min(y, window.innerHeight - r.height - 4) + "px";
    menu.querySelector("button").focus();
  }

  document.addEventListener("contextmenu", function (e) {
    if (e.shiftKey) return;
    if (closest(e.target, ".tattlr-modal, .tattlr-menu")) return;
    e.preventDefault();
    showMenu(e.clientX, e.clientY, e.target);
  });
  document.addEventListener("mousedown", function (e) {
    if (menu && !menu.contains(e.target)) hideMenu();
  });
  document.addEventListener("keydown", function (e) {
    if (e.key === "Escape") { hideMenu(); closeModal(); }
  });
  window.addEventListener("blur", hideMenu);
  window.addEventListener("scroll", hideMenu, true);

  /* ---- modal ---- */
  var overlay = null;
  function closeModal() { if (overlay) { overlay.remove(); overlay = null; } }

  function describeTarget(ctx) {
    var bits = [];
    if (ctx.input_id) bits.push("input “" + (ctx.input_label || ctx.input_id) + "”");
    else if (ctx.output_id) bits.push("output " + ctx.output_id);
    else if (ctx.element) bits.push(ctx.element.text ? "“" + ctx.element.text.slice(0, 40) + "”" : ctx.element.tag);
    if (ctx.namespace) bits.push("module " + ctx.namespace);
    if (ctx.page.length) bits.push("page " + ctx.page.join(" / "));
    return bits.length ? bits.join(" · ") : "the whole app";
  }

  function openModal(target, prefill) {
    closeModal();
    var ctx = collectContext(target);
    if (target && target.classList) target.classList.add("tattlr-highlight");
    var unhighlight = function () { if (target && target.classList) target.classList.remove("tattlr-highlight"); };

    var subject = h("input", { type: "text", id: "tattlr-subject", maxlength: "200", autocomplete: "off" });
    var email = h("input", { type: "email", id: "tattlr-email", maxlength: "200", placeholder: "Optional, if you want a reply" });
    var body = h("textarea", { id: "tattlr-body", rows: "5", maxlength: "10000" });
    if (prefill && prefill.subject) subject.value = prefill.subject;
    var env = h("input", { type: "checkbox", id: "tattlr-env" });
    env.checked = true;
    var err = h("div", { "class": "tattlr-error", role: "alert" });
    var send = h("button", { type: "submit", "class": "tattlr-btn tattlr-btn-primary", text: "Send" });

    // nothing is captured until the box is ticked; the preview is what gets sent
    var shot = null, shotBox = null, shotRow = null;
    if (cfg.screenshot) {
      shotBox = h("input", { type: "checkbox", id: "tattlr-shot" });
      var preview = h("div", { "class": "tattlr-shot-preview", "aria-live": "polite" });
      var showShot = function () {
        preview.textContent = "";
        preview.appendChild(h("img", { src: shot, alt: "Screenshot that will be attached",
          title: "Click to enlarge", onclick: function () { preview.classList.toggle("tattlr-shot-large"); } }));
        preview.appendChild(h("div", { "class": "tattlr-note",
          text: "Typed text and confidential areas are hidden. Untick to leave it out." }));
      };
      shotBox.addEventListener("change", function () {
        if (!shotBox.checked) { preview.textContent = ""; return; }
        if (shot) { showShot(); return; }
        send.disabled = true;
        preview.textContent = "Taking screenshot…";
        screenshot().then(function (url) {
          shot = url;
          send.disabled = false;
          if (shotBox.checked) showShot(); else preview.textContent = "";
        }, function (e) {
          send.disabled = false;
          shotBox.checked = false;
          preview.textContent = "The screenshot could not be taken.";
          pushError("tattlr", "screenshot failed: " + (e && e.message || e));
        });
      });
      shotRow = h("div", {}, [h("label", { "class": "tattlr-check" }, [shotBox,
        document.createTextNode(" Attach a screenshot of the page")]), preview]);
    }

    var form = h("form", { "class": "tattlr-modal", role: "dialog", "aria-modal": "true",
      "aria-labelledby": "tattlr-title" }, [
      h("h2", { id: "tattlr-title", text: "Send feedback" }),
      h("p", { "class": "tattlr-about", text: "About: " + describeTarget(ctx) }),
      h("label", { "for": "tattlr-subject", text: "Subject" }), subject,
      h("label", { "for": "tattlr-email", text: "Email" }), email,
      h("label", { "for": "tattlr-body", text: "Message" }), body,
      h("label", { "class": "tattlr-check" }, [env,
        document.createTextNode(" Include browser, OS and screen details")]),
      shotRow,
      h("p", { "class": "tattlr-note",
        text: "The current state of the app (filters, selections, page) is attached so we can reproduce the issue." }),
      err,
      h("div", { "class": "tattlr-actions" }, [
        h("button", { type: "button", "class": "tattlr-btn", text: "Cancel",
          onclick: function () { unhighlight(); closeModal(); } }),
        send
      ])
    ]);

    form.addEventListener("submit", function (e) {
      e.preventDefault();
      if (!subject.value.trim() && !body.value.trim()) {
        err.textContent = "Please add a subject or a message.";
        return;
      }
      if (email.value && !email.checkValidity()) {
        err.textContent = "That email address doesn't look right.";
        return;
      }
      if (!window.Shiny || !Shiny.setInputValue) {
        err.textContent = "The app is not connected, so the report can't be sent.";
        return;
      }
      send.disabled = true;
      send.textContent = "Sending…";
      unhighlight();
      Shiny.setInputValue(".tattlr_submit", {
        subject: subject.value.trim(),
        email: email.value.trim(),
        body: body.value,
        include_env: env.checked,
        environment: env.checked ? environmentInfo() : null,
        screenshot: shotBox && shotBox.checked && shot ? shot : null,
        context: ctx
      }, { priority: "event" });
    });

    overlay = h("div", { "class": themed("tattlr-overlay"),
      onmousedown: function (e) { if (e.target === overlay) { unhighlight(); closeModal(); } },
      // keep Escape (and other keys) from reaching a surrounding Bootstrap modal
      onkeydown: function (e) { e.stopPropagation(); if (e.key === "Escape") { unhighlight(); closeModal(); } } }, [form]);
    host().appendChild(overlay);
    subject.focus();
  }

  /* ---- toast / server ack ---- */
  function toast(msg, ok, action) {
    var t = h("div", { "class": themed("tattlr-toast") + (ok ? "" : " tattlr-toast-error"), role: "status" }, [
      document.createTextNode(msg),
      action ? h("button", { type: "button", "class": "tattlr-toast-action", text: action.label,
        onclick: function () { t.remove(); action.onclick(); } }) : null
    ]);
    document.body.appendChild(t);
    setTimeout(function () { t.remove(); }, action ? 10000 : 4000);
  }

  var registered = false;
  function registerHandlers() {
    if (registered) return;
    registered = true;
    Shiny.addCustomMessageHandler("tattlr_ack", function (msg) {
      closeModal();
      toast(msg.message, msg.ok);
    });
    Shiny.addCustomMessageHandler("tattlr_config", function (msg) { Object.assign(cfg, msg); });
  }

  // shiny's events are jQuery events, which addEventListener doesn't see
  var $ = window.jQuery;
  if ($) {
    $(document).on("shiny:inputchanged", logInput);
    $(document).on("shiny:error", onOutputError);
  }
  // tell the server which inputs are passwords (for reports built server-side)
  var pwTimer = null, lastPw = null;
  function sendPasswords() {
    clearTimeout(pwTimer);
    pwTimer = setTimeout(function () {
      var ids = Array.prototype.map.call(document.querySelectorAll("input[type=password][id]"),
        function (el) { return el.id; });
      var key = ids.join(",");
      if (key === lastPw || !window.Shiny || !Shiny.setInputValue) return;
      lastPw = key;
      Shiny.setInputValue(".tattlr_passwords", ids);
    }, 200);
  }
  function hello() {
    registerHandlers();
    Shiny.setInputValue(".tattlr_hello", Date.now(), { priority: "event" });
    sendPasswords();
    if ($) $(document).on("shiny:bound", sendPasswords);
  }

  var tries = 0;
  function init() {
    readConfig();
    // when injected by tattlr_server() the config tag can land just after this script
    if (!cfgEl && tries++ < 40) { setTimeout(init, 50); return; }
    if (cfg.button) {
      document.body.appendChild(h("button", { type: "button", "class": themed("tattlr-fab tattlr-fab-" + cfg.buttonPosition), text: "Feedback",
        onclick: function () { openModal(document.body); } }));
    }
    if (window.Shiny && Shiny.shinyapp && Shiny.shinyapp.isConnected()) hello();
    else if ($) $(document).one("shiny:connected", hello);
  }

  if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", init);
  else init();

  window.tattlr.open = function (el) { openModal(el || document.body); };
  window.tattlr.context = collectContext;
})();

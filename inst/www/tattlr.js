/* tattlr: right-click feedback / bug report menu for shiny apps */
(function () {
  "use strict";

  var cfgEl = document.getElementById("tattlr-config");
  var cfg = { button: false, label: "Send feedback / report bug", consoleBuffer: 20 };
  function readConfig() {
    cfgEl = cfgEl || document.getElementById("tattlr-config");
    if (cfgEl) {
      try { Object.assign(cfg, JSON.parse(cfgEl.textContent)); } catch (e) {}
    }
  }
  readConfig();

  /* ---- console error buffer (starts as early as possible) ---- */
  var consoleErrors = [];
  function pushError(kind, msg) {
    consoleErrors.push({ time: new Date().toISOString(), kind: kind, message: String(msg).slice(0, 1000) });
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

  function collectContext(target) {
    var isBody = !target || target === document.body || target === document.documentElement;
    var container = closest(target, ".shiny-input-container");
    var input = closest(target, ".shiny-bound-input") ||
      (container && container.querySelector(".shiny-bound-input"));
    var output = closest(target, ".shiny-bound-output");
    var withId = closest(target, "[id]");
    var bestId = (input && input.id) || (output && output.id) || (withId && withId.id) || null;

    var pageChain = [];
    var pane = closest(target, ".tab-pane");
    while (pane) {
      pageChain.unshift(pane.getAttribute("data-value") || pane.id);
      pane = closest(pane.parentElement, ".tab-pane");
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

    var label = container && container.querySelector("label");
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
      namespace: namespaceOf(bestId),
      page: pageChain,
      tabsets: tabsets,
      output_errors: outputErrors,
      password_inputs: passwordIds,
      console_errors: consoleErrors.slice()
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

  /* ---- context menu ---- */
  var menu = null, pendingTarget = null;
  function hideMenu() { if (menu) { menu.remove(); menu = null; } }

  function showMenu(x, y, target) {
    hideMenu();
    pendingTarget = target;
    menu = h("div", { "class": "tattlr-menu", role: "menu" }, [
      h("button", { type: "button", "class": "tattlr-menu-item", role: "menuitem", text: cfg.label,
        onclick: function () { hideMenu(); openModal(pendingTarget); } }),
      h("div", { "class": "tattlr-menu-hint", text: "Shift + right-click for the browser menu" })
    ]);
    document.body.appendChild(menu);
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

  function openModal(target) {
    closeModal();
    var ctx = collectContext(target);
    if (target && target.classList) target.classList.add("tattlr-highlight");
    var unhighlight = function () { if (target && target.classList) target.classList.remove("tattlr-highlight"); };

    var subject = h("input", { type: "text", id: "tattlr-subject", maxlength: "200", autocomplete: "off" });
    var email = h("input", { type: "email", id: "tattlr-email", maxlength: "200", placeholder: "Optional, if you want a reply" });
    var body = h("textarea", { id: "tattlr-body", rows: "5", maxlength: "10000" });
    var env = h("input", { type: "checkbox", id: "tattlr-env" });
    env.checked = true;
    var err = h("div", { "class": "tattlr-error", role: "alert" });
    var send = h("button", { type: "submit", "class": "tattlr-btn tattlr-btn-primary", text: "Send" });

    var form = h("form", { "class": "tattlr-modal", role: "dialog", "aria-modal": "true",
      "aria-labelledby": "tattlr-title" }, [
      h("h2", { id: "tattlr-title", text: "Send feedback" }),
      h("p", { "class": "tattlr-about", text: "About: " + describeTarget(ctx) }),
      h("label", { "for": "tattlr-subject", text: "Subject" }), subject,
      h("label", { "for": "tattlr-email", text: "Email" }), email,
      h("label", { "for": "tattlr-body", text: "Message" }), body,
      h("label", { "class": "tattlr-check" }, [env,
        document.createTextNode(" Include browser, OS and screen details")]),
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
        context: ctx
      }, { priority: "event" });
    });

    overlay = h("div", { "class": "tattlr-overlay",
      onmousedown: function (e) { if (e.target === overlay) { unhighlight(); closeModal(); } } }, [form]);
    document.body.appendChild(overlay);
    subject.focus();
  }

  /* ---- toast / server ack ---- */
  function toast(msg, ok) {
    var t = h("div", { "class": "tattlr-toast" + (ok ? "" : " tattlr-toast-error"), role: "status", text: msg });
    document.body.appendChild(t);
    setTimeout(function () { t.remove(); }, 4000);
  }

  function registerHandlers() {
    Shiny.addCustomMessageHandler("tattlr_ack", function (msg) {
      closeModal();
      toast(msg.message, msg.ok);
    });
  }

  function init() {
    readConfig();
    if (cfg.button) {
      document.body.appendChild(h("button", { type: "button", "class": "tattlr-fab", text: "Feedback",
        onclick: function () { openModal(document.body); } }));
    }
    if (window.Shiny && Shiny.addCustomMessageHandler) registerHandlers();
    else document.addEventListener("shiny:connected", registerHandlers, { once: true });
  }

  if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", init);
  else init();

  window.tattlr = { open: function (el) { openModal(el || document.body); }, context: collectContext };
})();

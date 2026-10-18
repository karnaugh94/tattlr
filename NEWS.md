# tattlr 0.1.0

First release.

* Right-click "Send feedback / Report bug" menu (and an optional floating
  button) for any shiny app, switched on with `TATTLR_ENABLED` or
  `options(tattlr.enabled = TRUE)`. `tattlr_server()` is the only call needed.
* Reports capture the clicked element, module namespace, active tabs, input
  values, outputs in error, recent JS console errors and the last input
  changes, and are written as Markdown with a runnable `input <- list(...)`,
  a `shiny::testServer()` replay and, for URL-bookmarking apps, a link that
  restores the inputs.
* Password inputs are always redacted; other inputs with `redact`.
* Automatic, rate-limited reports of outputs that fail to render and of
  sessions that crash (`auto_errors = TRUE`), with R tracebacks on
  shiny >= 1.8.1.
* Destinations: folder, email, GitHub issues, Microsoft Teams, Azure DevOps
  work items, Slack, or any `function(report, markdown)`.
* Opt-in screenshot (`screenshot = TRUE`) with typed text and areas marked
  `tattlr-mask` blanked before capture.
* Works with bslib, bs4Dash, shinyMobile, golem and plain Bootstrap 3/5
  apps, including inside `showModal()` dialogs and dark themes.

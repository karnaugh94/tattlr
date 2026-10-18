# tattlr

Right-click → **Send feedback / report bug**, anywhere in a shiny app. When you switch it on with an env var or option, users get a small modal (subject, optional email, message, and a checkbox for browser/OS/screen details). The package then writes a Markdown debugging report that includes a ready-to-run reprex of every input value.

![The feedback modal](man/figures/modal.png)

When it's disabled (the default), `tattlr_server()` and `use_tattlr()` do nothing and nothing is sent to the browser.

## Install

```r
remotes::install_github("karnaugh94/tattlr")
# or from a local copy
install.packages("path/to/tattlr", repos = NULL, type = "source")
# or: remotes::install_local("path/to/tattlr")
```

## Use

The only call you need is in the top-level server:

```r
server <- function(input, output, session) {
  tattlr::tattlr_server()
  ...
}
```

It injects the browser side once the session starts. You can also add `use_tattlr()` to the UI, which loads it with the page so JS errors during page load are captured too. Loading it twice is harmless.

```r
ui <- fluidPage(use_tattlr(), ...)
ui <- bslib::page_navbar(header = use_tattlr(), ...)   # navbar pages: use header=, not a bare argument
```

In golem, put `tattlr::use_tattlr()` in `golem_add_external_resources()` and `tattlr::tattlr_server()` in `app_server()`.

```sh
TATTLR_ENABLED=true TATTLR_DIR=./feedback R -e 'shiny::runApp()'
```

Shift + right-click still opens the browser's own menu. You can also open the modal yourself from JS with `tattlr.open(element)`.

Demo: `shiny::runApp(system.file("examples/demo", package = "tattlr"))` (set the env vars first).

## Configuration

Every setting can be an option (`options(tattlr.dir = ...)`) or an env var (`TATTLR_DIR`). If both are set, the option wins. Arguments passed to `tattlr_server()` / `use_tattlr()` override both.

| Setting | Env var | What it does |
|---|---|---|
| enabled | `TATTLR_ENABLED` | `true`/`1`/`yes` switches the tool on |
| dir | `TATTLR_DIR` | Folder for `feedback-<id>.md` + `.rds` |
| email_to | `TATTLR_EMAIL_TO` | Comma-separated recipients |
| email_from | `TATTLR_EMAIL_FROM` | Sender (defaults to the first recipient) |
| smtp_host / smtp_port / smtp_user / smtp_password | `TATTLR_SMTP_*` | SMTP server for the built-in sender (needs `emayili`) |
| redact | `TATTLR_REDACT` | Regex on input ids whose values get `<redacted>` |
| button | `TATTLR_BUTTON` | Also show a floating "Feedback" button (touch devices) |
| button_position | `TATTLR_BUTTON_POSITION` | `bottom-right` (default), `bottom-left`, `top-right`, `top-left` |
| app_name | `TATTLR_APP_NAME` | Shown in the report and email subject |

Destinations can be combined. If none is set, the report is printed to the R console. The email's Reply-To is set to the user's address when they give one, and the `.rds` is attached.

### Custom destinations

```r
tattlr_server(
  on_report = function(report, md) {
    # e.g. gh::gh("POST /repos/me/app/issues", title = report$subject, body = paste(md, collapse = "\n"))
  },
  send_email = function(to, from, subject, body, reply_to, attachments) {
    # use blastula / Microsoft Graph / whatever instead of SMTP
  },
  extra = function(session) list(user = session$user, app_version = "1.4.2")
)
```

## What a report contains

- Subject, message, optional email, server and client timestamps, URL.
- **Where:** the page (the chain of `tabPanel`s around the clicked element), the module namespace (taken from the nearest input/output id), the nearest input with its label and current value, the nearest output, a CSS selector, text and HTML of the clicked element, and the active tab of every tabset.
- Every output currently showing an error, with its message.
- The last 20 JS console errors and uncaught exceptions.
- **Reproduce:** `input <- list(...)` with every input value, plus a `shiny::testServer(server, { session$setInputs(...) })` snippet. The `.rds` keeps the exact R objects (`readRDS(path)$inputs`) for things `dput` can't round-trip.
- Browser environment (only if the user ticked the box): user agent, platform, language, screen, viewport, DPR, timezone, colour scheme.
- Server: R and shiny versions, working dir, session token, pid, plus whatever `extra()` returns.

Password inputs are always redacted.

## Tested with

These were tested in headless Chromium:
- **bslib** (dev version): the `flights` showcase, including dark mode, plotly, DT and histoslider.
- **bs4Dash**: the showcase app, with AdminLTE dark mode and an open Bootstrap 4 modal.
- **shinyMobile**: the gallery app, with Framework7 dark theme and the floating button on an iPhone viewport.
- **golem**: a fresh `create_golem()` app with a module.
- `showModal()` dialogs on Bootstrap 3 and 5.

The tattlr dialog follows the app's light or dark look rather than the OS setting. When a Bootstrap modal is open, it mounts inside that modal so the modal's focus trap doesn't block typing.

## Limitations

- Input values come from the server snapshot, so inputs without a binding (pure JS widgets that never call `setInputValue`) don't show up.
- The module namespace is inferred from ids (`ns-id`), so a custom `NS()` separator isn't recognised.
- No screenshot yet. `html2canvas` could be added as an opt-in.
- Reports go through the same R process as the app, so a busy session (a long render) delays the "sent" confirmation until it's free.
- Element text is captured as-is, so right-clicking an output that echoes a secret puts that text in the report. Only input values are redacted.

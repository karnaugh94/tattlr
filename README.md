# tattlr

Right-click → **Send feedback / report bug**, anywhere in a shiny app. When you switch it on with an env var or option, users get a small modal (subject, optional email, message, and a checkbox for browser/OS/screen details). The package then writes a Markdown debugging report that includes a ready-to-run reprex of every input value.

![The feedback modal](man/figures/modal.png)

When it's disabled (the default), `use_tattlr()` and `tattlr_server()` return `NULL` and nothing is sent to the browser.

## Install

```r
remotes::install_github("karnaugh94/tattlr")
# or from a local copy
install.packages("path/to/tattlr", repos = NULL, type = "source")
# or: remotes::install_local("path/to/tattlr")
```

## Use

```r
library(shiny)
library(tattlr)

ui <- fluidPage(
  use_tattlr(),            # anywhere in the UI
  ...
)

server <- function(input, output, session) {
  tattlr_server()          # once, in the top-level server
  ...
}
```

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

## Limitations

- Input values come from the server snapshot, so inputs without a binding (pure JS widgets that never call `setInputValue`) don't show up.
- The module namespace is inferred from ids (`ns-id`), so a custom `NS()` separator isn't recognised.
- No screenshot yet. `html2canvas` could be added as an opt-in.

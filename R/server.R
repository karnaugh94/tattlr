#' Handle feedback reports on the server
#'
#' Call once in your top-level server function (not inside a module). Does
#' nothing when the tool is disabled. This is the only call you need: it
#' also injects the browser assets, unless `inject_ui = FALSE`.
#'
#' Each report is written as `feedback-<id>.md` plus `feedback-<id>.rds` (the
#' full report object, with the exact R input values) to `dir`, emailed to
#' `email_to`, sent to `destinations` (GitHub, Teams, Azure DevOps, Slack) and
#' passed to `on_report`. Any combination works. When none is
#' configured the Markdown report is printed to the R console.
#'
#' With `auto_errors = TRUE`, errors are reported without any user action:
#' outputs that fail to render (validation messages and `req()` are ignored)
#' and unhandled errors that close the session. With shiny >= 1.8.1 both
#' include the R traceback; older shiny only reports output errors, without
#' a traceback. These are
#' written as `error-<id>.md` / `.rds`, carry no user-entered text and no
#' browser details, are capped at `auto_errors_limit` per session, and the same
#' error is reported at most once per `auto_errors_window` seconds per R
#' process (skipped repeats are counted in the next report).
#'
#' @param dir Folder for reports. Created if missing.
#' @param email_to Recipient address(es).
#' @param email_from Sender address (needed for email).
#' @param on_report Optional `function(report, markdown)` (or a list of them)
#'   called for every report, for destinations tattlr doesn't ship.
#' @param destinations Named list of destinations, see [destinations]. By
#'   default built from settings by [tattlr_destinations()].
#' @param send_email Optional `function(to, from, subject, body, reply_to,
#'   attachments)` replacing the built-in 'emayili' SMTP sender.
#' @param redact Regular expression; input ids that match have their values
#'   replaced. Password inputs are always redacted.
#' @param extra Optional `function(session)` returning a named list of
#'   extra debugging data (user name, app version, data snapshot, ...).
#' @param app_name Name shown in the report and email subject.
#' @param auto_errors Report errors automatically (see Details).
#' @param auto_errors_limit Maximum automatic reports per session.
#' @param auto_errors_window Seconds during which the same error (same kind,
#'   output and message) is not reported again by this R process.
#' @param auto_errors_prompt After an automatic report, show the user a small
#'   notice with a button to add details through the feedback dialog.
#' @param screenshot Offer the user to attach a screenshot of the page. Off by
#'   default. Typed text is always blanked in the image, whether or not it has
#'   reached shiny, and so is anything with class `tattlr-mask` or a
#'   `data-tattlr-mask` attribute. Nothing is captured until the user ticks the
#'   box, and they see the exact image before sending. Saved as
#'   `<report>.jpg` next to the report and attached to the email; other
#'   destinations get a note pointing to it, and `report$screenshot` holds the
#'   JPEG bytes for custom ones. Automatic error reports never include one.
#' @param inject_ui Insert the browser assets into the page from the server,
#'   so [use_tattlr()] in the UI is optional.
#' @param session The shiny session.
#' @param force Run even when the tool is disabled.
#' @return Invisibly, `NULL`.
#' @export
tattlr_server <- function(dir = tattlr_setting("dir"),
                            email_to = split_csv(tattlr_setting("email_to")),
                            email_from = tattlr_setting("email_from"),
                            on_report = NULL,
                            destinations = tattlr_destinations(),
                            send_email = NULL,
                            redact = tattlr_setting("redact"),
                            extra = NULL,
                            app_name = tattlr_setting("app_name", basename(getwd())),
                            auto_errors = as_flag(tattlr_setting("auto_errors", FALSE)),
                            auto_errors_limit = as.integer(tattlr_setting("auto_errors_limit", 5)),
                            auto_errors_window = as.numeric(tattlr_setting("auto_errors_window", 3600)),
                            auto_errors_prompt = as_flag(tattlr_setting("auto_errors_prompt", FALSE)),
                            screenshot = as_flag(tattlr_setting("screenshot", FALSE)),
                            inject_ui = TRUE,
                            session = shiny::getDefaultReactiveDomain(),
                            force = FALSE) {
  if (!force && !tattlr_enabled()) return(invisible(NULL))
  if (is.null(session)) stop("tattlr_server() must be called inside a shiny server function.")
  root <- if (is.function(session$rootScope)) session$rootScope() else session

  if (isTRUE(inject_ui)) {
    # a no-op in the browser when use_tattlr() is already in the UI
    shiny::insertUI("head", "beforeEnd", use_tattlr(force = TRUE), immediate = TRUE, session = root)
  }

  # password input ids, as last reported by the browser, so reports built
  # without a browser round trip (session crashes) still redact them
  passwords <- new.env()
  passwords$ids <- character()
  shiny::observeEvent(root$input[[".tattlr_passwords"]], {
    passwords$ids <- unlist(root$input[[".tattlr_passwords"]])
  }, ignoreInit = TRUE)

  # the browser asks for its settings once it has loaded (it may load after
  # the session starts when injected), so server arguments reach it reliably
  shiny::observeEvent(root$input[[".tattlr_hello"]], {
    root$sendCustomMessage("tattlr_config", list(
      autoErrors = isTRUE(auto_errors), autoErrorsPrompt = isTRUE(auto_errors_prompt),
      autoErrorsLimit = auto_errors_limit, screenshot = isTRUE(screenshot)))
  }, ignoreInit = TRUE)

  if (isTRUE(auto_errors)) {
    opts <- list(limit = auto_errors_limit, window = auto_errors_window, redact = redact,
                 extra = extra, app_name = app_name,
                 delivery = list(dir = dir, email_to = email_to, email_from = email_from,
                                 on_report = on_report, send_email = send_email,
                                 destinations = destinations))
    counter <- new.env()
    counter$n <- 0
    # tracebacks of output errors (shiny >= 1.8.1 reports them server-side
    # just before the browser does), attached when the browser's report arrives
    tracebacks <- new.env()
    report_safely <- function(error, payload) {
      tryCatch(auto_report(error, payload, root, opts, counter), error = function(e) {
        warning("tattlr: automatic report failed: ", conditionMessage(e), call. = FALSE)
        NULL
      })
    }

    shiny::observeEvent(root$input[[".tattlr_auto_error"]], {
      p <- root$input[[".tattlr_auto_error"]]
      report_safely(list(kind = "output", output_id = p$output_id, message = p$message,
                         call = p$call, type = unlist(p$type),
                         traceback = tracebacks[[gsub("\\s+", " ", p$message %||% "")]]),
                    list(context = p$context))
    }, ignoreInit = TRUE)

    if (exists("onUnhandledError", envir = asNamespace("shiny"), inherits = FALSE)) {
      # looked up at run time: it only exists in shiny >= 1.8.1
      on_unhandled_error <- getExportedValue("shiny", "onUnhandledError")
      on_unhandled_error(function(err) {
        if (!inherits(err, "shiny.error.fatal")) {
          # an output error; the output's name isn't available here, so key by message
          tracebacks[[gsub("\\s+", " ", conditionMessage(err))]] <- crash_traceback(err)
          return()
        }
        cd <- shiny::isolate(shiny::reactiveValuesToList(root$clientData))
        url <- paste0(cd$url_protocol, "//", cd$url_hostname,
                      if (nzchar(cd$url_port %||% "")) paste0(":", cd$url_port),
                      cd$url_pathname, cd$url_search, cd$url_hash)
        report_safely(list(kind = "crash", message = conditionMessage(err),
                           call = if (!is.null(conditionCall(err))) deparse(conditionCall(err)),
                           traceback = crash_traceback(err)),
                      list(context = list(url = url, password_inputs = as.list(passwords$ids))))
      }, session = root)
    }
  }

  shiny::observeEvent(root$input[[".tattlr_submit"]], {
    payload <- root$input[[".tattlr_submit"]]
    if (!isTRUE(screenshot)) payload$screenshot <- NULL
    report <- tryCatch(
      build_report(payload, root, redact = redact, extra = extra, app_name = app_name),
      error = function(e) e
    )
    if (inherits(report, "error")) {
      ack(root, FALSE, "Sorry, the report could not be built.")
      warning("tattlr: could not build report: ", conditionMessage(report), call. = FALSE)
      return()
    }
    results <- deliver_report(report, dir = dir, email_to = email_to, email_from = email_from,
                              on_report = on_report, send_email = send_email,
                              destinations = destinations)
    ok <- length(results) == 0 || any(vapply(results, isTRUE, logical(1)))
    ack(root, ok, if (ok) "Thanks! Your feedback was sent." else
      "Sorry, your feedback could not be delivered.")
  }, ignoreInit = TRUE)

  invisible(NULL)
}

ack <- function(session, ok, message) {
  session$sendCustomMessage("tattlr_ack", list(ok = ok, message = message))
}

#' Deliver a report to the configured destinations
#'
#' Used by [tattlr_server()]; exported so reports can be re-sent or tested.
#'
#' @inheritParams tattlr_server
#' @param report A report from [build_report()].
#' @return A named list with one `TRUE`/error message per destination tried.
#' @export
deliver_report <- function(report, dir = NULL, email_to = character(), email_from = NULL,
                           on_report = NULL, send_email = NULL, destinations = list()) {
  md <- render_report_md(report)
  results <- list()
  files <- character()
  write_files <- function(base) {
    saveRDS(report, paste0(base, ".rds"))
    shot <- if (!is.null(report$screenshot)) paste0(base, ".jpg")
    if (!is.null(shot)) writeBin(report$screenshot, shot)
    c(paste0(base, ".rds"), shot)
  }

  if (!is.null(dir) && nzchar(dir)) {
    results$dir <- tryCatch({
      dir.create(dir, recursive = TRUE, showWarnings = FALSE)
      base <- file.path(dir, report_basename(report))
      # the file sits next to the image, so it can show it
      writeLines(render_report_md(report, embed_screenshot = TRUE), paste0(base, ".md"), useBytes = TRUE)
      files <- c(paste0(base, ".md"), write_files(base))
      TRUE
    }, error = function(e) report_failure("writing to dir", e))
  }

  if (length(email_to)) {
    results$email <- tryCatch({
      if (!length(files)) files <- write_files(file.path(tempdir(), report_basename(report)))
      sender <- send_email %||% smtp_send
      sender(to = email_to, from = email_from %||% email_to[1],
             subject = email_subject(report), body = md,
             reply_to = if (nzchar(report$email)) report$email else NULL,
             attachments = files[grepl("\\.(rds|jpg)$", files)])
      TRUE
    }, error = function(e) report_failure("sending email", e))
  }

  if (is.function(on_report)) on_report <- list(on_report = on_report)
  destinations <- c(destinations, on_report)
  if (length(destinations) && is.null(names(destinations))) {
    names(destinations) <- paste0("destination_", seq_along(destinations))
  }
  for (nm in names(destinations)) {
    results[[nm]] <- tryCatch({
      destinations[[nm]](report, md)
      TRUE
    }, error = function(e) report_failure(paste0("sending to ", nm), e))
  }

  if (!length(results)) {
    message("tattlr: no destination configured (set TATTLR_DIR, TATTLR_EMAIL_TO or ",
            "a tracker/chat destination). Report follows.\n\n", paste(md, collapse = "\n"))
  }
  results
}

report_failure <- function(what, e) {
  warning("tattlr: failed ", what, ": ", conditionMessage(e), call. = FALSE)
  conditionMessage(e)
}

email_subject <- function(report) {
  paste0("[", report$app, " feedback] ", if (nzchar(report$subject)) report$subject else "(no subject)")
}

smtp_send <- function(to, from, subject, body, reply_to = NULL, attachments = character()) {
  if (!requireNamespace("emayili", quietly = TRUE)) {
    stop("install the 'emayili' package or pass send_email= to tattlr_server()")
  }
  host <- tattlr_setting("smtp_host")
  if (is.null(host)) stop("TATTLR_SMTP_HOST is not set")
  msg <- emayili::envelope(to = to, from = from, subject = subject)
  msg <- emayili::text(msg, paste(body, collapse = "\n"))
  if (!is.null(reply_to)) msg <- emayili::reply(msg, reply_to)
  for (f in attachments) msg <- emayili::attachment(msg, f)
  smtp <- emayili::server(
    host = host,
    port = as.integer(tattlr_setting("smtp_port", 587)),
    username = tattlr_setting("smtp_user"),
    password = tattlr_setting("smtp_password")
  )
  smtp(msg, verbose = FALSE)
  invisible(TRUE)
}

`%||%` <- function(x, y) if (is.null(x)) y else x

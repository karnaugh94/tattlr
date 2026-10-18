#' Handle feedback reports on the server
#'
#' Call once in your top-level server function (not inside a module). Does
#' nothing when the tool is disabled. This is the only call you need: it
#' also injects the browser assets, unless `inject_ui = FALSE`.
#'
#' Each report is written as `feedback-<id>.md` plus `feedback-<id>.rds` (the
#' full report object, with the exact R input values) to `dir`, emailed to
#' `email_to`, and passed to `on_report`. Any combination works. When none is
#' configured the Markdown report is printed to the R console.
#'
#' @param dir Folder for reports. Created if missing.
#' @param email_to Recipient address(es).
#' @param email_from Sender address (needed for email).
#' @param on_report Optional `function(report, markdown)` called for every
#'   report, e.g. to post to Slack or open a GitHub issue.
#' @param send_email Optional `function(to, from, subject, body, reply_to,
#'   attachments)` replacing the built-in 'emayili' SMTP sender.
#' @param redact Regular expression; input ids that match have their values
#'   replaced. Password inputs are always redacted.
#' @param extra Optional `function(session)` returning a named list of
#'   extra debugging data (user name, app version, data snapshot, ...).
#' @param app_name Name shown in the report and email subject.
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
                            send_email = NULL,
                            redact = tattlr_setting("redact"),
                            extra = NULL,
                            app_name = tattlr_setting("app_name", basename(getwd())),
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

  shiny::observeEvent(root$input[[".tattlr_submit"]], {
    payload <- root$input[[".tattlr_submit"]]
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
                              on_report = on_report, send_email = send_email)
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
                           on_report = NULL, send_email = NULL) {
  md <- render_report_md(report)
  results <- list()
  files <- character()

  if (!is.null(dir) && nzchar(dir)) {
    results$dir <- tryCatch({
      dir.create(dir, recursive = TRUE, showWarnings = FALSE)
      base <- file.path(dir, paste0("feedback-", report$id))
      writeLines(md, paste0(base, ".md"), useBytes = TRUE)
      saveRDS(report, paste0(base, ".rds"))
      files <- paste0(base, c(".md", ".rds"))
      TRUE
    }, error = function(e) report_failure("writing to dir", e))
  }

  if (length(email_to)) {
    results$email <- tryCatch({
      if (!length(files)) {
        rds <- file.path(tempdir(), paste0("feedback-", report$id, ".rds"))
        saveRDS(report, rds)
        files <- rds
      }
      sender <- send_email %||% smtp_send
      sender(to = email_to, from = email_from %||% email_to[1],
             subject = email_subject(report), body = md,
             reply_to = if (nzchar(report$email)) report$email else NULL,
             attachments = files[grepl("\\.rds$", files)])
      TRUE
    }, error = function(e) report_failure("sending email", e))
  }

  if (is.function(on_report)) {
    results$on_report <- tryCatch({
      on_report(report, md)
      TRUE
    }, error = function(e) report_failure("on_report", e))
  }

  if (!length(results)) {
    message("tattlr: no destination configured (set TATTLR_DIR or ",
            "TATTLR_EMAIL_TO). Report follows.\n\n", paste(md, collapse = "\n"))
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

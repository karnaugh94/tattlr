# Automatic error reports.
#
# Two sources: outputs that fail to render (reported by the browser, since
# shiny catches those errors itself) and unhandled errors that end the session
# (via shiny::onUnhandledError(), shiny >= 1.8.1). Both are rate limited per
# session and de-duplicated across sessions of the same R process, so one
# broken output seen by many users produces one report per window.

auto_state <- new.env(parent = emptyenv())
auto_state$seen <- list()

# TRUE when this fingerprint should be reported now. Otherwise counts it so the
# next report can say how many were skipped.
auto_should_report <- function(fingerprint, window, now = Sys.time()) {
  hit <- auto_state$seen[[fingerprint]]
  if (!is.null(hit) && as.numeric(difftime(now, hit$last, units = "secs")) < window) {
    hit$suppressed <- hit$suppressed + 1
    auto_state$seen[[fingerprint]] <- hit
    return(FALSE)
  }
  TRUE
}

auto_mark_reported <- function(fingerprint, now = Sys.time()) {
  prev <- auto_state$seen[[fingerprint]]$suppressed %||% 0
  auto_state$seen[[fingerprint]] <- list(last = now, suppressed = 0)
  prev
}

#' Forget which automatic error reports were already sent
#'
#' Automatic reports are de-duplicated per R process (see the `auto_errors_*`
#' arguments of [tattlr_server()]). This clears that memory, e.g. after a
#' redeploy fix or in tests.
#'
#' @return Invisibly, `NULL`.
#' @examples
#' tattlr_reset_auto_errors()
#' @export
tattlr_reset_auto_errors <- function() {
  auto_state$seen <- list()
  invisible(NULL)
}

auto_fingerprint <- function(kind, id, message) {
  paste(kind, id %||% "", gsub("\\s+", " ", message %||% ""), sep = "|")
}

# Returns the delivered report, or NULL when skipped.
auto_report <- function(error, payload, session, opts, counter) {
  fp <- auto_fingerprint(error$kind, error$output_id, error$message)
  if (counter$n >= opts$limit) return(NULL)
  if (!auto_should_report(fp, opts$window)) return(NULL)
  counter$n <- counter$n + 1
  error$suppressed <- auto_mark_reported(fp)

  payload$subject <- sprintf("[auto] %s: %s",
    if (identical(error$kind, "output")) paste0("Error in output '", error$output_id, "'") else "Session crashed",
    one_line(error$message %||% ""))
  report <- build_report(payload, session, redact = opts$redact, extra = opts$extra,
                         app_name = opts$app_name, type = "error", error = error)
  do.call(deliver_report, c(list(report), opts$delivery))
  report
}

crash_traceback <- function(err) {
  tb <- tryCatch(utils::capture.output(shiny::printStackTrace(err), type = "message"),
                 error = function(e) character())
  tb[nzchar(trimws(tb))]
}

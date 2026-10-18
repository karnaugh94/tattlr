#' Build a feedback report
#'
#' Combines what the browser sent with a server-side snapshot of every input
#' value. Used by [tattlr_server()].
#'
#' @param payload The list sent by the browser.
#' @param session The (root) shiny session, or `NULL` to skip the snapshot.
#' @param inputs Named list of input values; taken from `session` by default.
#' @param type `"feedback"` for a user report, `"error"` for an automatic one.
#' @param error For `type = "error"`: a list with `kind`, `message`, and
#'   optionally `output_id`, `call`, `traceback` and `suppressed`.
#' @inheritParams tattlr_server
#' @return A list of class `tattlr_report`.
#' @export
build_report <- function(payload, session = NULL, inputs = NULL, redact = NULL,
                         extra = NULL, app_name = "shiny app", type = "feedback",
                         error = NULL) {
  ctx <- payload$context %||% list()
  if (is.null(inputs) && !is.null(session)) {
    inputs <- shiny::isolate(shiny::reactiveValuesToList(session$input))
  }
  password_ids <- unlist(ctx$password_inputs)
  raw_inputs <- inputs %||% list()
  inputs <- redact_inputs(raw_inputs, password_ids, redact)
  if (length(inputs)) inputs <- inputs[order(names(inputs))]
  ctx$input_log <- redact_log(ctx$input_log, password_ids, redact)

  clientdata <- if (!is.null(session)) {
    cd <- shiny::isolate(shiny::reactiveValuesToList(session$clientData))
    cd[grepl("^url_|^pixelratio$", names(cd))]
  }

  bookmark <- if (!is.null(session)) {
    tryCatch(bookmark_url(session, raw_inputs, c(password_ids, names(inputs)[inputs %in% "<redacted>"])),
             error = function(e) NULL)
  }

  now <- Sys.time()
  structure(list(
    id = paste0(format(now, "%Y%m%d-%H%M%S", tz = "UTC"), "-",
                paste(sample(c(0:9, letters[1:6]), 4, TRUE), collapse = "")),
    type = type,
    time = now,
    app = app_name,
    subject = as.character(payload$subject %||% ""),
    email = as.character(payload$email %||% ""),
    body = as.character(payload$body %||% ""),
    context = ctx,
    environment = if (isTRUE(payload$include_env)) payload$environment,
    screenshot = decode_screenshot(payload$screenshot),
    error = error,
    inputs = inputs,
    bookmark_url = bookmark,
    clientdata = clientdata,
    server = list(
      r_version = R.version.string,
      shiny_version = as.character(utils::packageVersion("shiny")),
      platform = R.version$platform,
      working_dir = getwd(),
      session_token = if (!is.null(session)) session$token,
      pid = Sys.getpid()
    ),
    extra = if (is.function(extra)) tryCatch(extra(session), error = function(e)
      list(error = paste("extra() failed:", conditionMessage(e))))
  ), class = "tattlr_report")
}

redact_inputs <- function(inputs, password_ids = NULL, pattern = NULL) {
  hit <- names(inputs) %in% password_ids
  if (!is.null(pattern) && nzchar(pattern)) hit <- hit | grepl(pattern, names(inputs), perl = TRUE)
  inputs[hit] <- "<redacted>"
  inputs
}

redact_log <- function(log, password_ids = NULL, pattern = NULL) {
  lapply(log, function(step) {
    if (step$name %in% password_ids ||
        (!is.null(pattern) && nzchar(pattern) && grepl(pattern, step$name, perl = TRUE))) {
      step$value <- "\"<redacted>\""
    }
    step
  })
}

report_basename <- function(report) {
  paste0(if (identical(report$type, "error")) "error-" else "feedback-", report$id)
}

#' @export
print.tattlr_report <- function(x, ...) {
  cat(render_report_md(x), sep = "\n")
  invisible(x)
}

#' Render a report as Markdown
#'
#' @param report A report from [build_report()].
#' @param embed_screenshot Show the screenshot as an image (for the `.md`
#'   file saved next to `<report>.jpg`) instead of a note naming the file.
#' @return A character vector of Markdown lines.
#' @export
render_report_md <- function(report, embed_screenshot = FALSE) {
  ctx <- report$context
  el <- ctx$element
  rds <- paste0(report_basename(report), ".rds")
  title <- if (nzchar(report$subject)) md_inline(report$subject) else
    if (identical(report$type, "error")) "Automatic error report" else "Feedback (no subject)"
  focus_value <- if (!is.null(ctx$input_id) && ctx$input_id %in% names(report$inputs)) {
    report$inputs[[ctx$input_id]]
  }

  c(
    paste0("# ", title),
    "",
    bullet("Report ID", code(report$id)),
    bullet("Time", format(report$time, "%Y-%m-%d %H:%M:%S %Z")),
    bullet("Client time", md_text(ctx$client_time)),
    bullet("From", if (identical(report$type, "error")) "tattlr (automatic)" else
      if (nzchar(report$email)) report$email else "anonymous"),
    bullet("App", report$app),
    bullet("URL", md_url(ctx$url)),
    "",
    error_lines(report$error),
    if (!identical(report$type, "error")) c(
      "## Message",
      "",
      if (nzchar(trimws(report$body))) md_text(report$body) else "_(empty)_",
      ""
    ),
    screenshot_lines(report, embed_screenshot),
    where_lines(c(
    bullet("Page", if (length(ctx$page)) md_inline(paste(unlist(ctx$page), collapse = " / "))),
    bullet("Module namespace", code(ctx$namespace)),
    bullet("Input", if (!is.null(ctx$input_id)) paste0(code(ctx$input_id),
      if (!is.null(ctx$input_label)) paste0(" (", md_inline(ctx$input_label), ")"),
      if (!is.null(focus_value)) paste0(" = ", code(one_line(focus_value))))),
    bullet("Output", code(ctx$output_id)),
    bullet("Nearest id", code(ctx$nearest_id)),
    bullet("Element", if (!is.null(el)) code(el$selector)),
    bullet("Element text", if (!is.null(el) && nzchar(el$text %||% "")) md_inline(el$text)),
    tabset_lines(ctx$tabsets),
    if (!is.null(el$html)) c("", "<details><summary>Element HTML</summary>", "",
                             fence(el$html, "html"), "</details>"))),
    section_list("Outputs showing errors", ctx$output_errors, function(e)
      paste0(code(e$id), if (isTRUE(e$validation)) " (validation)", ": ", md_inline(e$message))),
    section_list("Recent JS console errors", ctx$console_errors, function(e)
      paste0(e$time, " ", e$kind, ": ", code(one_line(e$message)),
             if (!is.null(e$count)) paste0(" (x", e$count, ")"))),
    step_lines(ctx$input_log, ctx$client_time),
    "## Reproduce",
    "",
    if (!is.null(report$bookmark_url)) c(
      paste0("Open the app with these inputs restored (bookmark): ", md_url(report$bookmark_url)), ""),
    if (!is.null(ctx$url)) c(
      paste0("URL at the time of the report, including any query string or hash: ", md_url(ctx$url)), ""),
    paste0("Input values at the time of the report. Exact R objects: ",
           "`readRDS(\"", rds, "\")$inputs`."),
    "",
    fence(wrap_call("input <- list(", input_entries(report$inputs, rds)), "r"),
    "",
    "Replay against your server function with `shiny::testServer()`:",
    "",
    fence(c("shiny::testServer(server, {",
            if (length(report$inputs)) wrap_call("  session$setInputs(", input_entries(report$inputs, rds), "  ", ")"),
            "  # inspect reactives / output$... here",
            "})"), "r"),
    "",
    replay_lines(ctx$input_log),
    if (!is.null(report$environment)) c("## Browser environment", "", kv_lines(report$environment), ""),
    "## Server",
    "",
    kv_lines(c(report$server, report$clientdata)),
    "",
    if (length(report$extra)) c("## Extra", "", fence(deparse_lines(report$extra), "r"), "")
  )
}

input_entries <- function(inputs, rds) {
  vapply(names(inputs), function(nm) {
    val <- deparse_lines(inputs[[nm]])
    if (length(val) > 30 || sum(nchar(val)) > 3000) {
      val <- sprintf("readRDS(\"%s\")$inputs[[\"%s\"]]  # large value", rds, nm)
    }
    paste0("  ", r_name(nm), " = ", paste(val, collapse = "\n    "))
  }, character(1), USE.NAMES = FALSE)
}

wrap_call <- function(open, entries, indent = "", close = ")") {
  if (!length(entries)) return(paste0(open, close))
  c(open, paste0(indent, entries, c(rep(",", length(entries) - 1), "")), paste0(indent, close))
}

deparse_lines <- function(x) {
  deparse(x, width.cutoff = 80, control = c("keepNA", "keepInteger", "niceNames", "showAttributes"))
}

r_name <- function(x) ifelse(make.names(x) == x, x, paste0("`", x, "`"))

bullet <- function(label, value) {
  if (is.null(value) || !length(value) || identical(value, "")) return(NULL)
  paste0("- **", label, ":** ", value)
}

code <- function(x) {
  if (is.null(x) || !length(x)) return(NULL)
  x <- gsub("`", "'", as.character(x))
  paste0("`", x, "`")
}

md_inline <- function(x) gsub("([\\\\`*_<>#|\\[\\]])", "\\\\\\1", gsub("\\s+", " ", as.character(x)), perl = TRUE)

one_line <- function(x) {
  s <- if (is.character(x) && length(x) == 1) x else paste(deparse_lines(x), collapse = " ")
  s <- gsub("\\s+", " ", s)
  if (nchar(s) > 200) paste0(substr(s, 1, 200), "...") else s
}

fence <- function(lines, lang = "") {
  lines <- unlist(strsplit(paste(lines, collapse = "\n"), "\n", fixed = TRUE))
  ticks <- "```"
  while (any(grepl(ticks, lines, fixed = TRUE))) ticks <- paste0(ticks, "`")
  c(paste0(ticks, lang), lines, ticks)
}

kv_lines <- function(x) {
  x <- x[!vapply(x, function(v) is.null(v) || !length(v) || identical(v, ""), logical(1))]
  vapply(names(x), function(nm) {
    v <- unlist(x[[nm]])
    paste0("- **", nm, ":** ", md_text(if (is.atomic(v)) paste(v, collapse = ", ") else one_line(v)))
  }, character(1), USE.NAMES = FALSE)
}

tabset_lines <- function(tabsets) {
  tabsets <- Filter(function(t) !is.null(t$active), tabsets)
  if (!length(tabsets)) return(NULL)
  c("- **Active tabs:**", vapply(tabsets, function(t)
    paste0("  - ", if (!is.null(t$id)) code(t$id) else "(unnamed tabset)", " = ", md_inline(t$active)),
    character(1)))
}

section_list <- function(title, items, fmt) {
  if (!length(items)) return(NULL)
  c(paste0("## ", title), "", vapply(items, function(i) paste0("- ", fmt(i)), character(1)), "")
}

error_lines <- function(error) {
  if (is.null(error)) return(NULL)
  c("## Error", "",
    bullet("Kind", switch(error$kind %||% "",
      output = "an output failed to render",
      crash = "unhandled error, the session was closed",
      error$kind)),
    bullet("Output", code(error$output_id)),
    bullet("Message", code(one_line(error$message %||% ""))),
    bullet("Call", code(one_line(paste(unlist(error$call), collapse = " ")))),
    if (isTRUE(error$suppressed > 0)) bullet("Similar reports skipped since the last one", error$suppressed),
    if (length(error$traceback)) c("", "Traceback:", "", fence(error$traceback)),
    "")
}

step_lines <- function(log, client_time) {
  if (!length(log)) return(NULL)
  end <- parse_time(client_time)
  rows <- vapply(log, function(step) {
    t <- parse_time(step$time)
    when <- if (!is.na(t) && !is.na(end)) {
      s <- round(as.numeric(difftime(end, t, units = "secs")))
      sprintf("-%d:%02d", s %/% 60, s %% 60)
    } else step$time
    paste0("| ", when, " | ", code(step$name), " | ", code(one_line(step$value)), " |")
  }, character(1))
  c("## Steps before the report", "",
    paste0("The last ", length(log), " input changes, oldest first (time before the report). ",
           "Values are as the browser sent them, before shiny's input handlers."),
    "", "| When | Input | Value |", "|---|---|---|", rows, "")
}

replay_lines <- function(log) {
  if (!length(log)) return(NULL)
  calls <- vapply(log, function(step) {
    val <- tryCatch(jsonlite::fromJSON(step$value), error = function(e) step$value)
    paste0("  session$setInputs(", r_name(step$name), " = ",
           paste(deparse_lines(val), collapse = " "), ")")
  }, character(1))
  c("Replay the recorded steps in order (raw browser values, so dates arrive as strings):", "",
    fence(c("shiny::testServer(server, {", calls, "})"), "r"), "")
}

parse_time <- function(x) {
  if (is.null(x)) return(NA)
  as.POSIXct(sub("Z$", "", x), format = "%Y-%m-%dT%H:%M:%OS", tz = "UTC")
}

screenshot_lines <- function(report, embed) {
  if (is.null(report$screenshot)) return(NULL)
  file <- paste0(report_basename(report), ".jpg")
  c("## Screenshot", "",
    if (embed) paste0("![Screenshot of the app](", file, ")") else
      paste0("Attached as ", code(file), ", saved next to the report."),
    "", "Typed text and areas marked confidential were blanked by the browser before capture.", "")
}

# The browser sends a JPEG data URL; keep the bytes. Anything else is dropped.
decode_screenshot <- function(x) {
  if (!is.character(x) || length(x) != 1 || nchar(x) > 15e6) return(NULL)
  prefix <- "data:image/jpeg;base64,"
  if (!startsWith(x, prefix)) return(NULL)
  raw <- tryCatch(jsonlite::base64_dec(substring(x, nchar(prefix) + 1)), error = function(e) NULL)
  # JPEG files start with FF D8 FF
  if (length(raw) < 4 || !identical(raw[1:3], as.raw(c(0xff, 0xd8, 0xff)))) return(NULL)
  raw
}

where_lines <- function(lines) {
  if (!length(lines)) return(NULL)
  c("## Where", "", lines, "")
}

# Text the browser sent keeps its Markdown, but raw HTML is neutralised: the
# report is also rendered as HTML (Azure DevOps, other viewers).
md_text <- function(x) {
  if (is.null(x)) return(NULL)
  gsub("([<>])", "\\\\\\1", as.character(x))
}

# An autolink; characters that would end it or open raw HTML are percent-encoded.
md_url <- function(x) {
  if (is.null(x) || !nzchar(x)) return(NULL)
  x <- gsub(" ", "%20", gsub(">", "%3E", gsub("<", "%3C", as.character(x), fixed = TRUE), fixed = TRUE), fixed = TRUE)
  paste0("<", x, ">")
}

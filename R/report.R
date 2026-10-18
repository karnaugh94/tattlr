#' Build a feedback report
#'
#' Combines what the browser sent with a server-side snapshot of every input
#' value. Used by [tattlr_server()].
#'
#' @param payload The list sent by the browser.
#' @param session The (root) shiny session, or `NULL` to skip the snapshot.
#' @param inputs Named list of input values; taken from `session` by default.
#' @inheritParams tattlr_server
#' @return A list of class `tattlr_report`.
#' @export
build_report <- function(payload, session = NULL, inputs = NULL, redact = NULL,
                         extra = NULL, app_name = "shiny app") {
  ctx <- payload$context %||% list()
  if (is.null(inputs) && !is.null(session)) {
    inputs <- shiny::isolate(shiny::reactiveValuesToList(session$input))
  }
  inputs <- redact_inputs(inputs %||% list(), unlist(ctx$password_inputs), redact)
  inputs <- inputs[order(names(inputs))]

  clientdata <- if (!is.null(session)) {
    cd <- shiny::isolate(shiny::reactiveValuesToList(session$clientData))
    cd[grepl("^url_|^pixelratio$", names(cd))]
  }

  now <- Sys.time()
  structure(list(
    id = paste0(format(now, "%Y%m%d-%H%M%S", tz = "UTC"), "-",
                paste(sample(c(0:9, letters[1:6]), 4, TRUE), collapse = "")),
    time = now,
    app = app_name,
    subject = as.character(payload$subject %||% ""),
    email = as.character(payload$email %||% ""),
    body = as.character(payload$body %||% ""),
    context = ctx,
    environment = if (isTRUE(payload$include_env)) payload$environment,
    inputs = inputs,
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

#' @export
print.tattlr_report <- function(x, ...) {
  cat(render_report_md(x), sep = "\n")
  invisible(x)
}

#' Render a report as Markdown
#'
#' @param report A report from [build_report()].
#' @return A character vector of Markdown lines.
#' @export
render_report_md <- function(report) {
  ctx <- report$context
  el <- ctx$element
  rds <- paste0("feedback-", report$id, ".rds")
  focus_value <- if (!is.null(ctx$input_id) && ctx$input_id %in% names(report$inputs)) {
    report$inputs[[ctx$input_id]]
  }

  c(
    paste0("# ", if (nzchar(report$subject)) md_inline(report$subject) else "Feedback (no subject)"),
    "",
    bullet("Report ID", code(report$id)),
    bullet("Time", format(report$time, "%Y-%m-%d %H:%M:%S %Z")),
    bullet("Client time", ctx$client_time),
    bullet("From", if (nzchar(report$email)) report$email else "anonymous"),
    bullet("App", report$app),
    bullet("URL", ctx$url),
    "",
    "## Message",
    "",
    if (nzchar(trimws(report$body))) report$body else "_(empty)_",
    "",
    "## Where",
    "",
    bullet("Page", if (length(ctx$page)) paste(unlist(ctx$page), collapse = " / ")),
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
                             fence(el$html, "html"), "</details>"),
    "",
    section_list("Outputs showing errors", ctx$output_errors, function(e)
      paste0(code(e$id), if (isTRUE(e$validation)) " (validation)", ": ", md_inline(e$message))),
    section_list("Recent JS console errors", ctx$console_errors, function(e)
      paste0(e$time, " ", e$kind, ": ", code(one_line(e$message)),
             if (!is.null(e$count)) paste0(" (x", e$count, ")"))),
    "## Reproduce",
    "",
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
    paste0("- **", nm, ":** ", if (is.atomic(v)) paste(v, collapse = ", ") else one_line(v))
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

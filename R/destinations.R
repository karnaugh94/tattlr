#' Send reports to GitHub, Microsoft Teams, Azure DevOps or Slack
#'
#' Each function returns a destination: a `function(report, markdown)` to
#' pass in the `destinations` list of [tattlr_server()] (or as `on_report`).
#' [tattlr_destinations()] builds the list from environment variables, which
#' is what [tattlr_server()] uses by default, so setting e.g.
#' `TATTLR_GITHUB_REPO` is enough to turn one on.
#'
#' * `tattlr_github()` opens an issue with the full Markdown report. The token
#'   needs permission to create issues ("Issues: write" for a fine-grained
#'   token).
#' * `tattlr_teams()` posts an Adaptive Card to a Teams channel through a
#'   Workflows (Power Automate) "When a Teams webhook request is received"
#'   URL, the replacement for the retired Office 365 connectors.
#' * `tattlr_azure_devops()` creates a work item (a Bug by default) with the
#'   report as HTML in its repro steps. The personal access token needs the
#'   "Work Items: Read & write" scope.
#' * `tattlr_slack()` posts a summary to a Slack incoming webhook.
#'
#' Teams and Slack messages are summaries (title, where, message, error and
#' the report location); the full report stays in the folder, email or
#' tracker. Tokens are read when the destination is created and never written
#' into reports.
#'
#' @param repo `"owner/repo"`.
#' @param token Access token.
#' @param labels Issue labels (GitHub) or tags (Azure DevOps). Automatic
#'   error reports also get `"auto-error"`.
#' @param api_url GitHub API root; change it for GitHub Enterprise Server.
#' @param webhook_url Incoming webhook URL.
#' @param organization,project Azure DevOps organization and project.
#' @param type Work item type.
#' @param area_path Optional area path for new work items.
#' @param base_url Azure DevOps root; change it for Azure DevOps Server.
#' @return A destination function.
#' @examples
#' # destinations are created from settings; nothing is sent until a report arrives
#' if (FALSE) {
#'   tattlr_server(destinations = list(
#'     github = tattlr_github("me/my-app", token = Sys.getenv("GITHUB_PAT")),
#'     teams = tattlr_teams(Sys.getenv("TEAMS_WEBHOOK"))
#'   ))
#' }
#' # with no destination settings the list is empty
#' tattlr_destinations()
#' @name destinations
NULL

#' @rdname destinations
#' @export
tattlr_github <- function(repo = tattlr_setting("github_repo"),
                          token = tattlr_setting("github_token", Sys.getenv("GITHUB_PAT")),
                          labels = "tattlr",
                          api_url = "https://api.github.com") {
  check_arg(repo, "repo")
  check_arg(token, "token")
  function(report, markdown) {
    body <- truncate_md(markdown, 60000, report)
    res <- http_post_json(
      sprintf("%s/repos/%s/issues", sub("/$", "", api_url), repo),
      list(title = issue_title(report), body = body, labels = I(report_labels(report, labels))),
      headers = c(Authorization = paste("Bearer", token),
                  Accept = "application/vnd.github+json",
                  `X-GitHub-Api-Version` = "2022-11-28")
    )
    invisible(res$html_url)
  }
}

#' @rdname destinations
#' @export
tattlr_teams <- function(webhook_url = tattlr_setting("teams_webhook")) {
  check_arg(webhook_url, "webhook_url")
  function(report, markdown) {
    s <- report_summary(report)
    blocks <- c(
      list(list(type = "TextBlock", text = s$title, weight = "Bolder", size = "Medium", wrap = TRUE)),
      list(list(type = "FactSet", facts = lapply(names(s$facts), function(k)
        list(title = k, value = s$facts[[k]])))),
      if (nzchar(s$message)) list(list(type = "TextBlock", text = s$message, wrap = TRUE)),
      if (!is.null(s$error)) list(list(type = "TextBlock", text = s$error, wrap = TRUE,
                                       color = "Attention", fontType = "Monospace"))
    )
    http_post_json(webhook_url, list(
      type = "message",
      attachments = list(list(
        contentType = "application/vnd.microsoft.card.adaptive",
        content = list(`$schema` = "http://adaptivecards.io/schemas/adaptive-card.json",
                       type = "AdaptiveCard", version = "1.4", body = blocks)
      ))
    ))
    invisible(TRUE)
  }
}

#' @rdname destinations
#' @export
tattlr_azure_devops <- function(organization = tattlr_setting("azdo_organization"),
                                project = tattlr_setting("azdo_project"),
                                token = tattlr_setting("azdo_token"),
                                type = tattlr_setting("azdo_type", "Bug"),
                                area_path = tattlr_setting("azdo_area_path"),
                                labels = "tattlr",
                                base_url = paste0("https://dev.azure.com/", organization)) {
  check_arg(organization, "organization")
  check_arg(project, "project")
  check_arg(token, "token")
  function(report, markdown) {
    html <- md_to_html(truncate_md(markdown, 200000, report))
    field <- if (identical(type, "Bug")) "Microsoft.VSTS.TCM.ReproSteps" else "System.Description"
    ops <- list(
      list(op = "add", path = "/fields/System.Title", value = issue_title(report)),
      list(op = "add", path = paste0("/fields/", field), value = html),
      list(op = "add", path = "/fields/System.Tags",
           value = paste(report_labels(report, labels), collapse = "; "))
    )
    if (!is.null(area_path)) {
      ops <- c(ops, list(list(op = "add", path = "/fields/System.AreaPath", value = area_path)))
    }
    res <- http_post_json(
      sprintf("%s/%s/_apis/wit/workitems/$%s?api-version=7.1", sub("/$", "", base_url),
              utils::URLencode(project, reserved = TRUE), utils::URLencode(type, reserved = TRUE)),
      ops,
      headers = c(Authorization = paste("Basic", jsonlite::base64_enc(paste0(":", token)))),
      content_type = "application/json-patch+json"
    )
    invisible(res$id)
  }
}

#' @rdname destinations
#' @export
tattlr_slack <- function(webhook_url = tattlr_setting("slack_webhook")) {
  check_arg(webhook_url, "webhook_url")
  function(report, markdown) {
    s <- report_summary(report)
    esc <- function(x) gsub(">", "&gt;", gsub("<", "&lt;", gsub("&", "&amp;", x, fixed = TRUE), fixed = TRUE), fixed = TRUE)
    text <- paste(c(
      paste0("*", esc(s$title), "*"),
      paste0("*", names(s$facts), ":* ", esc(unlist(s$facts))),
      if (nzchar(s$message)) paste0(">", esc(strsplit(s$message, "\n")[[1]])),
      if (!is.null(s$error)) paste0("```", esc(s$error), "```")
    ), collapse = "\n")
    http_post_json(webhook_url, list(text = substr(text, 1, 3500)))
    invisible(TRUE)
  }
}

#' @describeIn destinations Builds the destinations configured through
#'   settings: `github_repo` (+ `github_token` or `GITHUB_PAT`),
#'   `teams_webhook`, `azdo_organization` + `azdo_project` + `azdo_token`
#'   (+ `azdo_type`, `azdo_area_path`), and `slack_webhook`. See
#'   [tattlr_setting()].
#' @export
tattlr_destinations <- function() {
  dest <- list()
  if (!is.null(tattlr_setting("github_repo"))) dest$github <- tattlr_github()
  if (!is.null(tattlr_setting("teams_webhook"))) dest$teams <- tattlr_teams()
  if (!is.null(tattlr_setting("azdo_project"))) dest$azure_devops <- tattlr_azure_devops()
  if (!is.null(tattlr_setting("slack_webhook"))) dest$slack <- tattlr_slack()
  dest
}

check_arg <- function(x, name) {
  if (is.null(x) || !nzchar(x)) stop("tattlr: `", name, "` is required for this destination", call. = FALSE)
}

issue_title <- function(report) {
  title <- if (nzchar(report$subject)) report$subject else "Feedback (no subject)"
  substr(paste0("[", report$app, "] ", title), 1, 250)
}

report_labels <- function(report, labels) {
  unique(c(labels, if (identical(report$type, "error")) "auto-error"))
}

truncate_md <- function(md, max_chars, report) {
  txt <- paste(md, collapse = "\n")
  if (nchar(txt) <= max_chars) return(txt)
  paste0(substr(txt, 1, max_chars - 300), "\n\n... (truncated; full report: `",
         report_basename(report), ".md`)")
}

md_to_html <- function(md) {
  if (requireNamespace("commonmark", quietly = TRUE)) {
    return(commonmark::markdown_html(md, extensions = TRUE))
  }
  esc <- gsub(">", "&gt;", gsub("<", "&lt;", gsub("&", "&amp;", md, fixed = TRUE), fixed = TRUE), fixed = TRUE)
  paste0("<pre>", esc, "</pre>")
}

# The short version of a report, for chat messages.
report_summary <- function(report) {
  ctx <- report$context %||% list()
  where <- c(
    if (length(ctx$page)) paste("page", paste(unlist(ctx$page), collapse = " / ")),
    if (!is.null(ctx$namespace)) paste("module", ctx$namespace),
    if (!is.null(ctx$input_id)) paste("input", ctx$input_id),
    if (!is.null(ctx$output_id)) paste("output", ctx$output_id)
  )
  facts <- list(
    App = report$app,
    From = if (identical(report$type, "error")) "automatic" else
      if (nzchar(report$email)) report$email else "anonymous",
    Where = if (length(where)) paste(where, collapse = ", "),
    URL = ctx$url,
    Report = paste0(report_basename(report), ".md")
  )
  err <- report$error
  list(
    title = issue_title(report),
    facts = facts[!vapply(facts, is.null, logical(1))],
    message = substr(report$body %||% "", 1, 1500),
    error = if (!is.null(err)) substr(paste(c(err$message, utils::head(err$traceback, 8)), collapse = "\n"), 1, 1500)
  )
}

http_post_json <- function(url, body, headers = character(), content_type = "application/json") {
  if (!requireNamespace("curl", quietly = TRUE)) {
    stop("tattlr: install the 'curl' package to send reports to this destination", call. = FALSE)
  }
  h <- curl::new_handle()
  curl::handle_setopt(h, customrequest = "POST",
                      postfields = as.character(jsonlite::toJSON(body, auto_unbox = TRUE, null = "null")))
  curl::handle_setheaders(h, .list = as.list(c(`Content-Type` = content_type,
                                               `User-Agent` = "tattlr", headers)))
  res <- curl::curl_fetch_memory(url, handle = h)
  txt <- rawToChar(res$content)
  if (res$status_code >= 300) {
    # only the host: webhook URLs carry their secret in the path
    stop(sprintf("HTTP %d from %s: %s", res$status_code, sub("^(https?://[^/]+).*$", "\\1", url),
                 substr(txt, 1, 300)),
         call. = FALSE)
  }
  if (nzchar(txt) && jsonlite::validate(txt)) jsonlite::fromJSON(txt, simplifyVector = FALSE) else txt
}

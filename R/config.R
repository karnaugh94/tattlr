#' Read a tattlr setting
#'
#' Every setting can be given as an R option (`tattlr.<name>`) or an
#' environment variable (`TATTLR_<NAME>`). The option wins when both
#' are set.
#'
#' | Setting         | Option                       | Env var                       |
#' |-----------------|------------------------------|-------------------------------|
#' | enabled         | `tattlr.enabled`      | `TATTLR_ENABLED`       |
#' | dir             | `tattlr.dir`          | `TATTLR_DIR`           |
#' | email_to        | `tattlr.email_to`     | `TATTLR_EMAIL_TO`      |
#' | email_from      | `tattlr.email_from`   | `TATTLR_EMAIL_FROM`    |
#' | smtp_host       | `tattlr.smtp_host`    | `TATTLR_SMTP_HOST`     |
#' | smtp_port       | `tattlr.smtp_port`    | `TATTLR_SMTP_PORT`     |
#' | smtp_user       | `tattlr.smtp_user`    | `TATTLR_SMTP_USER`     |
#' | smtp_password   | `tattlr.smtp_password`| `TATTLR_SMTP_PASSWORD` |
#' | redact          | `tattlr.redact`       | `TATTLR_REDACT`        |
#' | button          | `tattlr.button`       | `TATTLR_BUTTON`        |
#' | button_position | `tattlr.button_position` | `TATTLR_BUTTON_POSITION` |
#' | app_name        | `tattlr.app_name`     | `TATTLR_APP_NAME`      |
#'
#' `email_to` accepts a comma-separated list. `redact` is a regular
#' expression matched against input ids; matching values are replaced by
#' `"<redacted>"`. Password inputs are always redacted.
#'
#' @param name Setting name, e.g. `"dir"`.
#' @param default Value returned when the setting is unset.
#' @return The setting value (character for env vars), or `default`.
#' @export
tattlr_setting <- function(name, default = NULL) {
  opt <- getOption(paste0("tattlr.", name))
  if (!is.null(opt)) return(opt)
  env <- Sys.getenv(paste0("TATTLR_", toupper(name)), unset = "")
  if (nzchar(env)) return(env)
  default
}

#' Is the feedback tool switched on?
#'
#' @return `TRUE` when `tattlr.enabled` / `TATTLR_ENABLED` is
#'   truthy (`TRUE`, `"true"`, `"1"`, `"yes"`).
#' @export
tattlr_enabled <- function() {
  as_flag(tattlr_setting("enabled", FALSE))
}

as_flag <- function(x) {
  if (is.logical(x)) return(isTRUE(x))
  tolower(as.character(x)[1]) %in% c("true", "1", "yes", "y", "on")
}

split_csv <- function(x) {
  if (is.null(x)) return(character())
  x <- trimws(unlist(strsplit(as.character(x), ",")))
  x[nzchar(x)]
}

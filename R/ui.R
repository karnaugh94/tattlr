#' Add the feedback menu to a shiny UI
#'
#' Place anywhere in your UI. When the tool is disabled (see
#' [tattlr_enabled()]) this returns `NULL`, so nothing is sent to the
#' browser.
#'
#' Right-click anywhere opens the feedback menu; Shift + right-click still
#' opens the browser's native menu.
#'
#' @param button Also show a floating "Feedback" button (useful on touch
#'   devices, where there is no right-click).
#' @param label Text of the context-menu entry.
#' @param console_buffer How many recent JS console errors to keep.
#' @param force Inject even when the tool is disabled.
#' @return A [htmltools::tagList()] or `NULL`.
#' @export
use_tattlr <- function(button = as_flag(tattlr_setting("button", FALSE)),
                         label = "Send feedback / report bug",
                         console_buffer = 20,
                         force = FALSE) {
  if (!force && !tattlr_enabled()) return(NULL)
  config <- list(button = isTRUE(button), label = label,
                 consoleBuffer = as.integer(console_buffer))
  htmltools::tagList(
    tattlr_dependency(),
    htmltools::tags$script(
      id = "tattlr-config", type = "application/json",
      htmltools::HTML(jsonlite::toJSON(config, auto_unbox = TRUE))
    )
  )
}

tattlr_dependency <- function() {
  htmltools::htmlDependency(
    name = "tattlr",
    version = as.character(utils::packageVersion("tattlr")),
    src = "www",
    package = "tattlr",
    script = "tattlr.js",
    stylesheet = "tattlr.css"
  )
}

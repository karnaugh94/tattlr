#' Add the feedback menu to a shiny UI
#'
#' Optional: [tattlr_server()] injects the same assets once the session
#' starts. Adding `use_tattlr()` to the UI as well loads them with the page,
#' so JS errors raised during page load are captured too. When the tool is
#' disabled (see [tattlr_enabled()]) this returns `NULL`.
#'
#' In `bslib::page_navbar()` (and `navbarPage()`), pass it as
#' `header = use_tattlr()`: unnamed arguments there must be nav panels.
#'
#' Right-click anywhere opens the feedback menu; Shift + right-click still
#' opens the browser's native menu.
#'
#' @param button Also show a floating "Feedback" button (useful on touch
#'   devices, where there is no right-click).
#' @param button_position Corner for the button: `"bottom-right"`,
#'   `"bottom-left"`, `"top-right"` or `"top-left"`.
#' @param label Text of the context-menu entry.
#' @param console_buffer How many recent JS console errors to keep.
#' @param input_log How many recent input changes to keep for the "steps
#'   before the report" section (0 turns it off).
#' @param force Inject even when the tool is disabled.
#' @return A [htmltools::tagList()] or `NULL`.
#' @examples
#' # returns NULL unless the tool is enabled
#' use_tattlr()
#' use_tattlr(button = TRUE, force = TRUE)
#'
#' if (interactive()) {
#'   library(shiny)
#'   options(tattlr.enabled = TRUE)
#'   # in navbar pages, pass it as header = use_tattlr()
#'   ui <- navbarPage("App", header = use_tattlr(), tabPanel("Home", "Right-click me"))
#'   server <- function(input, output, session) tattlr_server()
#'   shinyApp(ui, server)
#' }
#' @export
use_tattlr <- function(button = as_flag(tattlr_setting("button", FALSE)),
                         button_position = tattlr_setting("button_position", "bottom-right"),
                         label = "Send feedback / report bug",
                         console_buffer = 20,
                         input_log = as.integer(tattlr_setting("input_log", 30)),
                         force = FALSE) {
  if (!force && !tattlr_enabled()) return(NULL)
  button_position <- match.arg(button_position, c("bottom-right", "bottom-left", "top-right", "top-left"))
  config <- list(button = isTRUE(button), buttonPosition = button_position, label = label,
                 consoleBuffer = as.integer(console_buffer), inputLog = as.integer(input_log))
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

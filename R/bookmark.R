# Build a URL-bookmark link for the current inputs, for apps that use
# `enableBookmarking("url")`. Mirrors shiny's own `?_inputs_&id=<json>` encoding
# without triggering `session$doBookmark()`, which would show the app's
# bookmark modal and run its onBookmark callbacks. Values saved by those
# callbacks (`state$values`) are therefore not included. Action buttons are
# left out too: restoring a click count would replay its side effects.
bookmark_url <- function(session, inputs, exclude = character()) {
  if (!identical(shiny::getShinyOption("bookmarkStore"), "url")) return(NULL)
  cd <- shiny::isolate(shiny::reactiveValuesToList(session$clientData))
  if (is.null(cd$url_hostname)) return(NULL)

  exclude <- c(exclude, "._bookmark_",
               tryCatch(session$getBookmarkExclude(), error = function(e) character()))
  keep <- !names(inputs) %in% exclude & !startsWith(names(inputs), ".") &
    !vapply(inputs, function(x) is.data.frame(x) || inherits(x, "shinyActionButtonValue"), logical(1))
  inputs <- inputs[keep]

  base <- paste0(cd$url_protocol, "//", cd$url_hostname,
                 if (nzchar(cd$url_port %||% "")) paste0(":", cd$url_port), cd$url_pathname)
  if (!length(inputs)) return(base)
  vals <- vapply(inputs, bookmark_json, character(1))
  paste0(base, "?_inputs_&", paste0(url_encode(names(vals)), "=", url_encode(vals), collapse = "&"))
}

bookmark_json <- function(x) {
  as.character(jsonlite::toJSON(x, dataframe = "columns", null = "null", na = "null",
    auto_unbox = TRUE, digits = NA, force = TRUE, POSIXt = "ISO8601", UTC = TRUE,
    rownames = FALSE, keep_vec_names = TRUE, json_verbatim = TRUE))
}

url_encode <- function(x) vapply(x, utils::URLencode, character(1), reserved = TRUE, USE.NAMES = FALSE)

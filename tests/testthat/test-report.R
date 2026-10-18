payload <- list(
  subject = "Plot is empty", email = "a@b.com", body = "Nothing shows", include_env = TRUE,
  environment = list(user_agent = "UA", viewport = "800x600"),
  context = list(url = "http://x", input_id = "filters-species", input_label = "Species",
                 namespace = "filters", page = list("Plot"), password_inputs = list("token"),
                 tabsets = list(list(id = "tabs", active = "Plot")),
                 output_errors = list(list(id = "broken", validation = FALSE, message = "boom")),
                 element = list(selector = "#filters-species", text = "setosa", html = "<select>"))
)
inputs <- list(`filters-species` = c("setosa", "virginica"), `filters-petal` = 1.5,
               token = "secret", `filters-dates` = as.Date(c("2026-01-01", "2026-06-30")))

test_that("disabled by default", {
  withr::local_envvar(TATTLR_ENABLED = NA)
  withr::local_options(tattlr.enabled = NULL)
  expect_false(tattlr_enabled())
  expect_null(use_tattlr())
})

test_that("option beats env var", {
  withr::local_envvar(TATTLR_ENABLED = "false")
  withr::local_options(tattlr.enabled = TRUE)
  expect_true(tattlr_enabled())
  expect_s3_class(use_tattlr(), "shiny.tag.list")
})

test_that("report redacts and renders a runnable reprex", {
  r <- build_report(payload, inputs = inputs, redact = "dates$")
  expect_equal(r$inputs$token, "<redacted>")
  expect_equal(r$inputs$`filters-dates`, "<redacted>")
  md <- render_report_md(r)
  expect_true(any(grepl("Plot is empty", md)))
  expect_true(any(grepl("`broken`", md)))
  start <- grep("^input <- list\\(", md)
  end <- start + which(md[start:length(md)] == "```")[1] - 2
  env <- new.env()
  eval(parse(text = md[start:end]), env)
  expect_equal(env$input$`filters-species`, c("setosa", "virginica"))
})

test_that("deliver_report writes md + rds", {
  d <- withr::local_tempdir()
  r <- build_report(payload, inputs = inputs)
  res <- deliver_report(r, dir = d)
  expect_true(res$dir)
  expect_length(list.files(d, pattern = "\\.md$"), 1)
  back <- readRDS(list.files(d, pattern = "\\.rds$", full.names = TRUE))
  expect_equal(back$inputs$`filters-dates`, inputs$`filters-dates`)
})

test_that("email goes through a custom sender", {
  got <- NULL
  r <- build_report(payload, inputs = inputs)
  res <- deliver_report(r, email_to = "dev@x.com",
    send_email = function(...) got <<- list(...))
  expect_true(res$email)
  expect_equal(got$reply_to, "a@b.com")
  expect_match(got$subject, "Plot is empty")
})

test_that("button position is validated and passed to the browser", {
  withr::local_options(tattlr.enabled = TRUE)
  ui <- as.character(use_tattlr(button = TRUE, button_position = "top-left"))
  expect_match(ui, '"buttonPosition":"top-left"', fixed = TRUE)
  expect_error(use_tattlr(button_position = "middle"))
})

test_that("repeated console errors are counted in the report", {
  p <- payload
  p$context$console_errors <- list(list(time = "t", kind = "console.error", message = "boom", count = 3))
  md <- render_report_md(build_report(p, inputs = inputs))
  expect_true(any(grepl("(x3)", md, fixed = TRUE)))
})

test_that("input log is redacted, tabulated and replayable", {
  p <- payload
  p$context$client_time <- "2026-01-01T10:01:00.000Z"
  p$context$input_log <- list(
    list(time = "2026-01-01T10:00:00.000Z", name = "filters-species", value = '["setosa"]'),
    list(time = "2026-01-01T10:00:30.000Z", name = "token", value = '"hunter2"'),
    list(time = "2026-01-01T10:00:50.000Z", name = "go", value = "1"))
  r <- build_report(p, inputs = inputs)
  md <- render_report_md(r)
  expect_false(any(grepl("hunter2", md)))
  expect_true(any(grepl("| -1:00 | `filters-species` |", md, fixed = TRUE)))
  expect_true(any(grepl('session$setInputs(`filters-species` = "setosa")', md, fixed = TRUE)))
  expect_true(any(grepl("session$setInputs(go = 1L)", md, fixed = TRUE)))
})

test_that("bookmark URL round-trips through shiny's encoding", {
  old <- shiny::getShinyOption("bookmarkStore")
  shiny::shinyOptions(bookmarkStore = "url")
  withr::defer(shiny::shinyOptions(bookmarkStore = old))
  session <- list(
    clientData = shiny::reactiveValues(url_protocol = "https:", url_hostname = "apps.example.com",
                                       url_port = "", url_pathname = "/app/"),
    getBookmarkExclude = function() "skipme")
  vals <- list(`filters-species` = c("setosa", "virginica"), n = 5L, token = "secret",
               skipme = 1, `.hidden` = 2, file = data.frame(a = 1))
  url <- bookmark_url(session, vals, exclude = "token")
  expect_match(url, "^https://apps.example.com/app/\\?_inputs_&")
  q <- strsplit(sub("^.*_inputs_&", "", url), "&", fixed = TRUE)[[1]]
  kv <- setNames(vapply(q, function(x) utils::URLdecode(sub("^[^=]*=", "", x)), ""),
                 vapply(q, function(x) utils::URLdecode(sub("=.*$", "", x)), ""))
  expect_setequal(names(kv), c("filters-species", "n"))
  expect_equal(jsonlite::fromJSON(kv[["filters-species"]]), c("setosa", "virginica"))
  expect_equal(jsonlite::fromJSON(kv[["n"]]), 5L)

  shiny::shinyOptions(bookmarkStore = "server")
  expect_null(bookmark_url(session, vals))
})

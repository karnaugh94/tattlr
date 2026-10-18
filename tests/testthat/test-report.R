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

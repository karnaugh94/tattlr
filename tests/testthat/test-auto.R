test_that("same error is reported once per window, then counts the skipped ones", {
  tattlr_reset_auto_errors()
  withr::defer(tattlr_reset_auto_errors())
  t0 <- as.POSIXct("2026-01-01 10:00:00", tz = "UTC")
  expect_true(auto_should_report("fp", 60, t0))
  expect_equal(auto_mark_reported("fp", t0), 0)
  expect_false(auto_should_report("fp", 60, t0 + 10))
  expect_false(auto_should_report("fp", 60, t0 + 20))
  expect_true(auto_should_report("fp", 60, t0 + 61))
  expect_equal(auto_mark_reported("fp", t0 + 61), 2)
  expect_true(auto_should_report("other", 60, t0 + 10))
})

test_that("auto reports respect the per-session limit and render as error reports", {
  tattlr_reset_auto_errors()
  withr::defer(tattlr_reset_auto_errors())
  d <- withr::local_tempdir()
  opts <- list(limit = 2, window = 3600, redact = NULL, extra = NULL, app_name = "app",
               delivery = list(dir = d))
  counter <- new.env(); counter$n <- 0
  err <- function(msg) list(kind = "output", output_id = "plot", message = msg, call = "f(x)")
  r1 <- auto_report(err("boom"), list(context = list(url = "http://x")), NULL, opts, counter)
  expect_null(auto_report(err("boom"), list(), NULL, opts, counter))    # duplicate
  r2 <- auto_report(err("other"), list(), NULL, opts, counter)
  expect_null(auto_report(err("third"), list(), NULL, opts, counter))   # over the limit
  expect_s3_class(r1, "tattlr_report")
  expect_equal(r1$type, "error")
  files <- list.files(d)
  expect_length(files, 4)
  expect_true(all(startsWith(files, "error-")))
  md <- render_report_md(r1)
  expect_true("## Error" %in% md)
  expect_false("## Message" %in% md)
  expect_match(md[1], "auto\\] Error in output 'plot': boom", fixed = TRUE)
})

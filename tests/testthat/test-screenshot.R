jpeg_url <- function(bytes) paste0("data:image/jpeg;base64,", jsonlite::base64_enc(bytes))
fake_jpeg <- as.raw(c(0xff, 0xd8, 0xff, 0xe0, 1:20))

test_that("only JPEG data URLs are kept", {
  expect_identical(decode_screenshot(jpeg_url(fake_jpeg)), fake_jpeg)
  expect_null(decode_screenshot(NULL))
  expect_null(decode_screenshot("data:image/png;base64,iVBORw0KGgo="))
  expect_null(decode_screenshot(jpeg_url(charToRaw("<script>alert(1)</script>"))))
  expect_null(decode_screenshot(c(jpeg_url(fake_jpeg), jpeg_url(fake_jpeg))))
})

test_that("the screenshot is saved next to the report and attached to the email", {
  d <- withr::local_tempdir()
  r <- build_report(list(subject = "s", screenshot = jpeg_url(fake_jpeg)), inputs = list(x = 1))
  sent <- NULL
  deliver_report(r, dir = d, email_to = "a@b.com", email_from = "c@d.com",
                 send_email = function(...) sent <<- list(...))
  base <- file.path(d, report_basename(r))
  expect_identical(readBin(paste0(base, ".jpg"), "raw", 100), fake_jpeg)
  expect_true(any(grepl(paste0("](", report_basename(r), ".jpg)"), readLines(paste0(base, ".md")), fixed = TRUE)))
  expect_setequal(basename(sent$attachments), paste0(report_basename(r), c(".rds", ".jpg")))
  expect_true(any(grepl("Attached as", sent$body, fixed = TRUE)))
})

test_that("reports without a screenshot have no screenshot section", {
  r <- build_report(list(subject = "s"), inputs = list())
  expect_null(r$screenshot)
  expect_false("## Screenshot" %in% render_report_md(r))
})

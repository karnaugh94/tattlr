# A local HTTP server in a background R process that records every request.
mock_server <- function(env) {
  skip_on_cran()
  skip_if_not_installed("httpuv")
  skip_if_not_installed("callr")
  skip_if_not_installed("curl")
  log <- tempfile(fileext = ".jsonl")
  port <- httpuv::randomPort()
  proc <- callr::r_bg(function(port, log) {
    httpuv::runServer("127.0.0.1", port, list(call = function(req) {
      body <- rawToChar(req$rook.input$read())
      rec <- list(method = req$REQUEST_METHOD, path = req$PATH_INFO, query = req$QUERY_STRING,
                  auth = if (is.null(req$HTTP_AUTHORIZATION)) "" else req$HTTP_AUTHORIZATION,
                  type = if (is.null(req$CONTENT_TYPE)) "" else req$CONTENT_TYPE, body = body)
      cat(jsonlite::toJSON(rec, auto_unbox = TRUE), "\n", file = log, append = TRUE, sep = "")
      status <- if (grepl("fail", req$PATH_INFO)) 500L else 201L
      list(status = status, headers = list(`Content-Type` = "application/json"),
           body = '{"id": 42, "html_url": "https://example/issue/1"}')
    }))
  }, args = list(port = port, log = log))
  withr::defer(proc$kill(), envir = env)
  url <- paste0("http://127.0.0.1:", port)
  for (i in 1:50) {
    ok <- tryCatch({ curl::curl_fetch_memory(url); TRUE }, error = function(e) FALSE)
    if (ok) break
    Sys.sleep(0.1)
  }
  list(url = url, requests = function() {
    if (!file.exists(log)) return(list())
    lapply(readLines(log), jsonlite::fromJSON, simplifyVector = FALSE)
  }, reset = function() unlink(log))
}

sample_report <- function(type = "feedback") {
  build_report(list(subject = "Plot is empty", email = "a@b.com", body = "Nothing shows",
                    context = list(url = "http://app", page = list("Plot"), output_id = "plot")),
               inputs = list(n = 1L), app_name = "demo", type = type,
               error = if (type == "error") list(kind = "output", output_id = "plot", message = "boom",
                                                 traceback = c("2: stop", "1: renderPlot")))
}

test_that("each destination sends the expected request", {
  srv <- mock_server(environment())
  r <- sample_report()
  md <- render_report_md(r)
  srv$requests() # warm-up request is not logged as JSON body; clear it
  srv$reset()

  expect_equal(tattlr_github("me/app", token = "ghp_x", api_url = srv$url)(r, md), "https://example/issue/1")
  tattlr_teams(paste0(srv$url, "/teams"))(r, md)
  expect_equal(tattlr_azure_devops("org", "My Project", token = "pat", base_url = srv$url)(r, md), 42L)
  tattlr_slack(paste0(srv$url, "/slack"))(r, md)

  req <- srv$requests()
  expect_length(req, 4)

  gh <- req[[1]]
  expect_equal(gh$path, "/repos/me/app/issues")
  expect_equal(gh$auth, "Bearer ghp_x")
  gb <- jsonlite::fromJSON(gh$body)
  expect_equal(gb$title, "[demo] Plot is empty")
  expect_equal(gb$labels, "tattlr")
  expect_match(gb$body, "## Reproduce", fixed = TRUE)

  card <- jsonlite::fromJSON(req[[2]]$body, simplifyVector = FALSE)
  expect_equal(card$attachments[[1]]$contentType, "application/vnd.microsoft.card.adaptive")
  expect_equal(card$attachments[[1]]$content$body[[1]]$text, "[demo] Plot is empty")

  az <- req[[3]]
  expect_equal(az$path, "/My%20Project/_apis/wit/workitems/$Bug")
  expect_equal(az$query, "?api-version=7.1")
  expect_equal(az$type, "application/json-patch+json")
  expect_equal(az$auth, paste("Basic", jsonlite::base64_enc(":pat")))
  ops <- jsonlite::fromJSON(az$body, simplifyVector = FALSE)
  expect_equal(ops[[2]]$path, "/fields/Microsoft.VSTS.TCM.ReproSteps")
  expect_match(ops[[2]]$value, "<h2>Reproduce</h2>", fixed = TRUE)

  sl <- jsonlite::fromJSON(req[[4]]$body)
  expect_match(sl$text, "*[demo] Plot is empty*", fixed = TRUE)
  expect_match(sl$text, "*Where:* page Plot, output plot", fixed = TRUE)
})

test_that("error reports get the auto-error label, failures don't leak webhook secrets", {
  srv <- mock_server(environment())
  srv$reset()
  r <- sample_report("error")
  tattlr_github("me/app", token = "t", api_url = srv$url)(r, render_report_md(r))
  expect_equal(jsonlite::fromJSON(srv$requests()[[1]]$body)$labels, c("tattlr", "auto-error"))

  err <- tryCatch(tattlr_slack(paste0(srv$url, "/fail/T000/B000/secret"))(r, "x"), error = conditionMessage)
  expect_match(err, "HTTP 500")
  expect_false(grepl("secret", err))

  expect_warning(res <- deliver_report(r, destinations = list(
    slack = tattlr_slack(paste0(srv$url, "/fail")), teams = tattlr_teams(paste0(srv$url, "/ok")))))
  expect_true(res$teams)
  expect_match(res$slack, "HTTP 500")
})

test_that("destinations are built from settings", {
  withr::local_envvar(TATTLR_GITHUB_REPO = "me/app", TATTLR_GITHUB_TOKEN = "t",
                      TATTLR_SLACK_WEBHOOK = "https://hooks.example/x",
                      TATTLR_TEAMS_WEBHOOK = NA, TATTLR_AZDO_PROJECT = NA)
  expect_named(tattlr_destinations(), c("github", "slack"))
  withr::local_envvar(TATTLR_AZDO_PROJECT = "p", TATTLR_AZDO_ORGANIZATION = "o", TATTLR_AZDO_TOKEN = NA)
  expect_error(tattlr_destinations(), "token")
})

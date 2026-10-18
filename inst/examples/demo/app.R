# Demo app for tattlr.
# Run with:
#   Sys.setenv(TATTLR_ENABLED = "true", TATTLR_DIR = "feedback")
#   shiny::runApp(system.file("examples/demo", package = "tattlr"))
# then right-click anywhere and pick "Send feedback / report bug".
library(shiny)
library(tattlr)

filters_ui <- function(id) {
  ns <- NS(id)
  tagList(
    selectInput(ns("species"), "Species", c("setosa", "versicolor", "virginica"), multiple = TRUE,
                selected = "setosa"),
    sliderInput(ns("petal"), "Min petal length", 0, 7, 1, step = 0.5),
    dateRangeInput(ns("dates"), "Date range", start = "2026-01-01", end = "2026-06-30")
  )
}

filters_server <- function(id) {
  moduleServer(id, function(input, output, session) {
    reactive(subset(iris, Species %in% input$species & Petal.Length >= input$petal))
  })
}

ui <- fluidPage(
  use_tattlr(),
  titlePanel("tattlr demo"),
  sidebarLayout(
    sidebarPanel(filters_ui("filters"), passwordInput("token", "API token (always redacted)")),
    mainPanel(
      tabsetPanel(id = "tabs",
        tabPanel("Table", tableOutput("table")),
        tabPanel("Plot", plotOutput("plot")),
        tabPanel("Broken", p("This output always errors:"), textOutput("broken"))
      )
    )
  )
)

server <- function(input, output, session) {
  tattlr_server(extra = function(session) list(rows_in_data = nrow(iris)))
  data <- filters_server("filters")
  output$table <- renderTable(head(data(), 15))
  output$plot <- renderPlot(plot(data()$Petal.Length, data()$Petal.Width))
  output$broken <- renderText(stop("object 'foo' not found"))
}

shinyApp(ui, server)

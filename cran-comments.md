## R CMD check results

0 errors | 0 warnings | 1 note

* This is a new release.

## Notes for reviewers

* inst/www/html-to-image.js is the unmodified html-to-image 1.11.13 library
  (MIT). Its author is listed as copyright holder in Authors@R and the
  details are in inst/COPYRIGHTS.
* Tests that start a local HTTP server (to mock GitHub, Teams, Azure DevOps
  and Slack) are skipped on CRAN. Nothing in the tests or examples contacts
  the internet.

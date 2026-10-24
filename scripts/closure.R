#!/usr/bin/env Rscript
# Recursive CRAN dependency closure for WebR builds.
#
# Usage: Rscript scripts/closure.R pkgA [pkgB ...]
#
# Prints (one per line, sorted) the requested packages plus their FULL
# recursive closure over Depends + Imports + LinkingTo (Suggests excluded),
# minus the base packages that ship inside WebR itself. Recommended-priority
# packages (Matrix, lattice, MASS, ...) are NOT bundled in WebR, so they stay
# in the closure.
#
# Exits non-zero with a clear message if a requested name is invalid, not on
# CRAN, or if any closure member cannot be found on CRAN.

base_pkgs <- c(
  "base", "stats", "utils", "methods", "graphics", "grDevices", "grid",
  "tools", "parallel", "splines", "stats4", "tcltk", "compiler", "datasets",
  "R"
)

fail <- function(...) {
  message("ERROR: ", ...)
  quit(status = 1, save = "no")
}

args <- commandArgs(trailingOnly = TRUE)
pkgs <- unique(trimws(unlist(strsplit(args, "[,[:space:]]+"))))
pkgs <- pkgs[nzchar(pkgs)]
if (length(pkgs) == 0) fail("no package names given")

name_re <- "^[A-Za-z][A-Za-z0-9.]*[A-Za-z0-9]$"
bad <- pkgs[!grepl(name_re, pkgs)]
if (length(bad)) fail("invalid CRAN package name(s): ", paste(bad, collapse = ", "))

repos <- Sys.getenv("CRAN_REPO", "https://cloud.r-project.org")
db <- tryCatch(
  available.packages(repos = repos, type = "source", filters = list()),
  error = function(e) fail("could not read CRAN PACKAGES index: ", conditionMessage(e))
)
if (nrow(db) == 0) fail("CRAN PACKAGES index is empty (", repos, ")")

base_req <- intersect(pkgs, base_pkgs)
if (length(base_req)) fail("base package(s) ship with WebR, nothing to build: ",
                           paste(base_req, collapse = ", "))

missing <- setdiff(pkgs, rownames(db))
if (length(missing)) fail("not found on CRAN: ", paste(missing, collapse = ", "))

deps <- tools::package_dependencies(
  pkgs, db = db, which = c("Depends", "Imports", "LinkingTo"), recursive = TRUE
)
closure <- unique(c(pkgs, unlist(deps, use.names = FALSE)))
closure <- setdiff(closure, base_pkgs)

not_on_cran <- setdiff(closure, rownames(db))
if (length(not_on_cran)) fail("dependencies not available on CRAN (cannot build): ",
                              paste(not_on_cran, collapse = ", "))

writeLines(sort(closure, method = "radix"))

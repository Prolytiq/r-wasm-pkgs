#!/usr/bin/env Rscript
# CRAN dependency closure for WebR builds.
#
# Modes
#   Rscript scripts/closure.R pkgA [pkgB ...]
#       FULL closure (legacy): prints, one per line and sorted, the requested
#       packages plus their recursive closure over Depends + Imports + LinkingTo
#       (Suggests excluded), minus the base packages that ship inside WebR.
#
#   Rscript scripts/closure.R --to-build [--tsv] [--report FILE] pkgA [...]
#       BUILD closure: only the members that must be BUILT here, i.e. the
#       closure minus base packages minus anything already served by one of
#       the three repos the app installs from:
#         - this repo (Prolytiq/r-wasm-pkgs, live Pages index),
#         - https://repo.r-wasm.org/ (4.6 binaries),
#         - Prolytiq/jags-wasm (rjags, gemtc, Rglpk).
#       Traversal stops at available packages (their own deps are served by
#       the same repos). Output is TOPOLOGICALLY ordered (deps first).
#       --tsv prints "pkg<TAB>dep1,dep2" where deps are restricted to the
#       printed set. --report writes "pkg<TAB>source" for every closure member
#       reached (source = build | prolytiq | r-wasm | jags-wasm | base).
#
#   Rscript scripts/closure.R --order [--tsv] pkgA [...]
#       No expansion: topologically order exactly the given packages.
#
# Env: CRAN_REPO (default cloud.r-project.org); OUR_PACKAGES, RWASM_PACKAGES,
# JAGS_PACKAGES override the index URLs (a local path is also accepted).
#
# Exits non-zero with a clear message if a requested name is invalid, not on
# CRAN, or if a needed closure member cannot be found on CRAN.

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
mode <- "full"
tsv <- FALSE
report <- NULL
rest <- character()
i <- 1
while (i <= length(args)) {
  a <- args[i]
  if (a == "--to-build") mode <- "build"
  else if (a == "--order") mode <- "order"
  else if (a == "--tsv") tsv <- TRUE
  else if (a == "--report") { i <- i + 1; report <- args[i] }
  else rest <- c(rest, a)
  i <- i + 1
}

pkgs <- unique(trimws(unlist(strsplit(rest, "[,[:space:]]+"))))
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

dep_fields <- c("Depends", "Imports", "LinkingTo")
direct_deps <- function(p) {
  setdiff(unlist(tools::package_dependencies(p, db = db, which = dep_fields),
                 use.names = FALSE), base_pkgs)
}

# Kahn topological sort of `set`, ties broken alphabetically (deterministic).
topo <- function(set) {
  deps <- lapply(setNames(set, set), function(p) intersect(direct_deps(p), set))
  out <- character()
  left <- set
  while (length(left)) {
    ready <- sort(left[vapply(left, function(p) all(deps[[p]] %in% out), logical(1))],
                  method = "radix")
    if (!length(ready)) {
      # Dependency cycle (should not happen on CRAN): emit the rest sorted.
      message("WARNING: dependency cycle among: ", paste(left, collapse = ", "))
      ready <- sort(left, method = "radix")
    }
    out <- c(out, ready)
    left <- setdiff(left, ready)
  }
  list(order = out, deps = deps)
}

emit <- function(t) {
  if (tsv) {
    for (p in t$order) cat(p, "\t", paste(t$deps[[p]], collapse = ","), "\n", sep = "")
  } else {
    writeLines(t$order)
  }
}

if (mode == "full") {
  missing <- setdiff(pkgs, rownames(db))
  if (length(missing)) fail("not found on CRAN: ", paste(missing, collapse = ", "))
  deps <- tools::package_dependencies(pkgs, db = db, which = dep_fields, recursive = TRUE)
  closure <- setdiff(unique(c(pkgs, unlist(deps, use.names = FALSE))), base_pkgs)
  not_on_cran <- setdiff(closure, rownames(db))
  if (length(not_on_cran)) fail("dependencies not available on CRAN (cannot build): ",
                                paste(not_on_cran, collapse = ", "))
  writeLines(sort(closure, method = "radix"))
  quit(status = 0, save = "no")
}

if (mode == "order") {
  missing <- setdiff(pkgs, rownames(db))
  if (length(missing)) fail("not found on CRAN: ", paste(missing, collapse = ", "))
  emit(topo(pkgs))
  quit(status = 0, save = "no")
}

# ---- mode == "build" -------------------------------------------------------
read_index <- function(src) {
  con <- if (grepl("^https?://", src)) url(paste0(src, "?nocache=", as.integer(Sys.time()))) else file(src)
  on.exit(close(con))
  x <- tryCatch(read.dcf(con, fields = "Package"),
                error = function(e) fail("could not read index ", src, ": ", conditionMessage(e)))
  unique(x[, "Package"])
}
idx <- list(
  prolytiq = read_index(Sys.getenv("OUR_PACKAGES",
    "https://prolytiq.github.io/r-wasm-pkgs/bin/emscripten/contrib/4.6/PACKAGES")),
  `r-wasm` = read_index(Sys.getenv("RWASM_PACKAGES",
    "https://repo.r-wasm.org/bin/emscripten/contrib/4.6/PACKAGES")),
  `jags-wasm` = read_index(Sys.getenv("JAGS_PACKAGES",
    "https://prolytiq.github.io/jags-wasm/bin/emscripten/contrib/4.6/PACKAGES"))
)
for (n in names(idx)) if (!length(idx[[n]])) fail("index '", n, "' is empty")
where <- function(p) {
  if (p %in% base_pkgs) return("base")
  for (n in names(idx)) if (p %in% idx[[n]]) return(n)
  "build"
}

source_of <- character()
queue <- pkgs
while (length(queue)) {
  p <- queue[1]
  queue <- queue[-1]
  if (p %in% names(source_of)) next
  s <- where(p)
  source_of[p] <- s
  if (s == "build") {
    if (!p %in% rownames(db)) fail("not found on CRAN (and not in any wasm repo): ", p)
    queue <- c(queue, setdiff(direct_deps(p), names(source_of)))
  }
}

if (!is.null(report)) {
  writeLines(paste(names(source_of), source_of, sep = "\t"), report)
}
to_build <- names(source_of)[source_of == "build"]
if (length(to_build)) emit(topo(to_build))

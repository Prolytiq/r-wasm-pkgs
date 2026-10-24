#!/usr/bin/env Rscript
# Build ONE CRAN package for WebAssembly into a CRAN-like repo directory.
# Runs inside the ghcr.io/r-wasm/webr image (host R + rwasm + emscripten).
#
# Usage: Rscript scripts/build-one.R <pkg> <repo_dir>
# Exit codes: 0 = built (fresh .tgz present and indexed), 2 = already present
# at the current CRAN version (nothing to do), 1 = failed.
#
# rwasm::add_pkg() traps build errors and only warns, so success is decided
# here from the repo contents, not from add_pkg's return value.

args <- commandArgs(trailingOnly = TRUE)
pkg <- args[1]
repo_dir <- args[2]
stopifnot(grepl("^[A-Za-z][A-Za-z0-9.]*[A-Za-z0-9]$", pkg), dir.exists(repo_dir))

r_version <- R_system_version(getOption("rwasm.webr_version"))
bin <- file.path(repo_dir, "bin", "emscripten", "contrib",
                 paste0(r_version$major, ".", r_version$minor))
src <- file.path(repo_dir, "src", "contrib")
dir.create(bin, recursive = TRUE, showWarnings = FALSE)
dir.create(src, recursive = TRUE, showWarnings = FALSE)

pkg_files <- function(dir, ext) {
  list.files(dir, pattern = paste0("^", gsub(".", "\\.", pkg, fixed = TRUE), "_.*\\.", ext, "$"),
             full.names = TRUE)
}

start <- Sys.time() - 1
before <- pkg_files(bin, "tgz")

res <- tryCatch({
  withCallingHandlers(
    rwasm::add_pkg(pkg, repo_dir = repo_dir, compress = TRUE),
    warning = function(w) message("WARNING: ", conditionMessage(w))
  )
  "done"
}, error = function(e) {
  message("ERROR: ", conditionMessage(e))
  "error"
})

new <- pkg_files(bin, "tgz")
fresh <- new[file.mtime(new) >= start]

if (length(fresh)) {
  keep_tgz <- fresh[which.max(file.mtime(fresh))]
  ver <- sub(paste0("^", pkg, "_(.*)\\.tgz$"), "\\1", basename(keep_tgz))
  # rwasm only unlinks the old *source* name in bin/, so drop stale versions.
  stale <- setdiff(new, keep_tgz)
  stale_src <- setdiff(pkg_files(src, "tar\\.gz"), file.path(src, paste0(pkg, "_", ver, ".tar.gz")))
  if (length(c(stale, stale_src))) {
    message("Removing stale versions: ", paste(basename(c(stale, stale_src)), collapse = ", "))
    unlink(c(stale, stale_src))
  }
  rwasm::write_packages(repo_dir)
  idx <- read.dcf(file.path(bin, "PACKAGES"), fields = c("Package", "Version"))
  if (!any(idx[, "Package"] == pkg & idx[, "Version"] == ver)) {
    message("ERROR: ", basename(keep_tgz), " was built but is not indexed in PACKAGES")
    quit(status = 1, save = "no")
  }
  message("RESULT: built ", pkg, " ", ver)
  quit(status = 0, save = "no")
}

if (res == "done" && length(before)) {
  message("RESULT: ", pkg, " already present (", paste(basename(before), collapse = ", "), ")")
  quit(status = 2, save = "no")
}

# Failed: drop the downloaded source tarball so it is not committed and a later
# attempt re-downloads it, and keep PACKAGES consistent with the files on disk.
unlink(setdiff(pkg_files(src, "tar\\.gz"), sub("\\.tgz$", ".tar.gz", file.path(src, basename(before)))))
rwasm::write_packages(repo_dir)
message("RESULT: failed ", pkg)
quit(status = 1, save = "no")

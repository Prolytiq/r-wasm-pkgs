# r-wasm-pkgs

WebAssembly (WebR) builds of R packages used by the Prolytiq AI in-browser
statistics editor (`fts-app` /biostatistics), which runs R client-side.
Served as a CRAN-like repo on GitHub Pages:

https://prolytiq.github.io/r-wasm-pkgs/ (index: `bin/emscripten/contrib/4.6/PACKAGES`)

The app installs from three repos, in this order: this one,
[jags-wasm](https://prolytiq.github.io/jags-wasm/) (`rjags`, `gemtc`, `Rglpk`,
built against a wasm port of JAGS) and [repo.r-wasm.org](https://repo.r-wasm.org/).
This repo only builds what the other two do not serve.

No source code of the platform lives here — only package references and build tooling.

## How it works

- **`site` branch = the store.** It holds every built binary (`bin/…/*.tgz`) and
  source tarball (`src/contrib/*.tar.gz`). Builds are incremental: only requested
  packages are compiled and each success is committed to `site` right away.
- **`build-batch.yml`** (reusable + manual): builds a list of packages deps-first,
  one `rwasm::add_pkg()` per package inside `ghcr.io/r-wasm/webr:main` (with native
  JAGS installed so packages importing `rjags` can be lazy-loaded), per-package
  timeout + overall time cap, results in the `build-results` artifact; appends
  successes to `packages`; then calls `deploy.yml`.
- **`deploy.yml`**: publishes `site` to Pages, regenerating the `PACKAGES` indexes
  (they are not stored on `site`, so parallel builders never conflict). Refuses to
  publish fewer packages than are live. It no longer builds anything; pushes to
  `main` do not trigger it.
- **`packages`**: human-readable record of what was built here (append-only).
- **`bootstrap-store.yml`**: one-off creation of `site` from the Pages artifact,
  verified file-by-file (MD5) against the live index.

## Requesting a package (issue flow)

```sh
gh issue create -R Prolytiq/r-wasm-pkgs --title "build: pkgname" --label build-package --body ""
```

One package per issue (`build: pkgA, pkgB` also works). `build-package.yml` then:

1. validates names against `^[A-Za-z][A-Za-z0-9.]*[A-Za-z0-9]$` (title/body reach
   the shell only through `env:`);
2. computes what must be built: `scripts/closure.R --to-build` = recursive closure
   over Depends + Imports + LinkingTo, minus base packages, minus anything already
   in this repo, repo.r-wasm.org or jags-wasm (traversal stops there);
3. if nothing is left, comments where each package is available and closes;
4. otherwise runs `build-batch.yml`, comments a per-package table (failures with the
   log tail), verifies the requested packages in the live `PACKAGES` (polls ~20 min
   for the Pages CDN) and closes — or labels `build-failed` and leaves it open.

**Access gate:** only users with triage/write access can apply labels, so only they
can start a build. To retry, remove and re-add `build-package`.

## Priority queue

`batch-queue.yml` (manual, input `count`, default 30) refreshes `queue/priority.tsv`
(the gap ordered by cranlogs downloads), picks the next pending packages, adds their
missing deps, skips anything depending on a known failure, builds, and records
results in `queue/status.tsv` (`built` / `failed` + reason / `blocked`; absent =
pending). Failed entries are not retried automatically — delete the row to retry.

```sh
python3 scripts/queue.py stats      # summary
Rscript scripts/closure.R --to-build pkg   # what a request would build
Rscript scripts/closure.R pkg       # legacy: full closure (base excluded)
```

## Limits

- Packages needing system libraries absent from the webr image, or not portable to
  Emscripten (Java, Rust toolchains, threads, …) fail; see `queue/status.tsv`.
- A package that imports `rjags` installs in WebR only when jags-wasm is among the
  repos (the app handles that).
- GitHub Pages sites are limited to ~1 GB; the store is ~0.2 GB for ~100 packages.
  Dropping `src/contrib` from the deploy is the first lever if it grows.
- Only CRAN packages (no Bioconductor/GitHub sources).

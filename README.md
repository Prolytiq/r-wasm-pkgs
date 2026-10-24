# r-wasm-pkgs

WebAssembly (WebR) builds of R packages used by the Prolytiq AI in-browser
statistics editor (`fts-app` /biostatistics), which runs R client-side.

The `packages` file lists the packages to build; the
[r-wasm/actions](https://github.com/r-wasm/actions) workflow (`deploy.yml`)
compiles each one for the Emscripten/wasm target and deploys a CRAN-like binary
repository to GitHub Pages:

https://prolytiq.github.io/r-wasm-pkgs/
(index: `bin/emscripten/contrib/4.6/PACKAGES`)

The list covers every package the /biostatistics script catalogue can generate.
`rjags` and `gemtc` (JAGS-based) are not built here: they are built against a
wasm port of JAGS in [Prolytiq/jags-wasm](https://github.com/Prolytiq/jags-wasm)
and served from that repo's GitHub Pages.

No source code of the platform lives here — only package references.

## Requesting a package (on-demand build)

Open an issue with the **Build a package for WebAssembly** form, or from the CLI:

```sh
gh issue create -R Prolytiq/r-wasm-pkgs --title "build: pkgname" --label build-package --body ""
```

Several packages: `build: pkgA, pkgB`. A body line `packages: pkgA, pkgB` also works.

The `build-package` workflow (`.github/workflows/build-package.yml`) then:

1. validates every name against the CRAN name regex `^[A-Za-z][A-Za-z0-9.]*[A-Za-z0-9]$`
   and that it exists on CRAN (invalid requests get a rejection comment);
2. computes the dependency closure with `scripts/closure.R`;
3. appends the closure members missing from `packages` (existing order kept),
   commits `feat: add <pkgs> (+N deps) — on-demand build #<issue>` and pushes to main;
4. dispatches `deploy.yml` (pushes made with `GITHUB_TOKEN` do not trigger other
   workflows, so it is started explicitly via `workflow_dispatch`) and watches it;
5. verifies the package's entry in the Pages `PACKAGES` index (polls up to ~15 min
   for the Pages CDN cache), comments the entry and closes the issue — or, on
   failure, comments the log tail and adds the `build-failed` label.

If the whole closure is already listed, it comments that and closes the issue.

**Access gate:** only users with triage/write access to this repo can apply labels,
so only they can start a build. Issues from anyone else sit idle until a maintainer
adds `build-package`. To retry a failed request, remove and re-add the label.

### Dependency closure rule

`packages` must list the FULL recursive closure — WebR's `install.packages` needs
every dependency resolvable from the repo. The closure is recursive over
**Depends + Imports + LinkingTo** (not Suggests), minus the base packages that ship
inside WebR (base, stats, utils, methods, graphics, grDevices, grid, tools,
parallel, splines, stats4, tcltk, compiler, datasets). Recommended-priority
packages (Matrix, lattice, MASS, nlme, survival, …) are NOT bundled in WebR and
stay in the closure. Compute it locally with:

```sh
Rscript scripts/closure.R pkgA pkgB
```

### Limits

- Every request rebuilds the whole repository (25–40+ min, growing with the list).
- Packages needing system libraries absent from the webr build image (or not
  portable to Emscripten) fail; the issue gets the failing log tail and the
  `build-failed` label. Fixing those means a custom build, not this workflow.
- Only CRAN packages are supported (no Bioconductor/GitHub sources).

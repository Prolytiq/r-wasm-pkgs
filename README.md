# r-wasm-pkgs

WebAssembly (WebR) builds of R packages used by the Prolytiq AI in-browser
statistics editor (`fts-app` /biostatistics), which runs R client-side.

The `packages` file lists the packages to build; the
[r-wasm/actions](https://github.com/r-wasm/actions) workflow compiles each one
and its full dependency closure for the Emscripten/wasm target and deploys a
CRAN-like binary repository to GitHub Pages:

https://prolytiq.github.io/r-wasm-pkgs/

No source code of the platform lives here — only package references.

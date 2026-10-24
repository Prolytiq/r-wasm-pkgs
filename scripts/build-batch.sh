#!/usr/bin/env bash
# Incremental wasm build of a list of packages into the `site` store.
#
# Runs on the GitHub runner. Expects:
#   - main checked out in $GITHUB_WORKSPACE (scripts/),
#   - the `site` branch checked out in ./_site (git worktree with push rights),
#   - env PKGS: space-separated, regex-validated CRAN names,
#   - env CAP_MIN: overall time cap in minutes (no new package starts after it),
#   - env PER_PKG_MIN: per-package timeout in minutes,
#   - env WEBR_IMAGE: build image.
# Produces ./results/{results.tsv,summary.md,logs/<pkg>.log} and appends
# ok/failed/deferred lists to $GITHUB_OUTPUT.
#
# Each successful package is committed and pushed to `site` immediately, so a
# cancelled or timed-out run keeps its progress.
set -euo pipefail

: "${PKGS:?}" "${CAP_MIN:?}" "${PER_PKG_MIN:?}" "${WEBR_IMAGE:?}"
name_re='^[A-Za-z][A-Za-z0-9.]*[A-Za-z0-9]$'
for p in $PKGS; do [[ $p =~ $name_re ]] || { echo "invalid name: $p"; exit 1; }; done

t0=$(date +%s)
mkdir -p results/logs
res=results/results.tsv
printf 'package\tstatus\tseconds\tversion\treason\n' > "$res"

echo "::group::Start build container"
docker pull -q "$WEBR_IMAGE"
docker run -d --name builder -v "$PWD:/work" -w /work "$WEBR_IMAGE" sleep infinity >/dev/null
docker exec builder bash -c '. /etc/os-release; echo "$PRETTY_NAME"; R --version | head -1'
# Host-side (native) JAGS so packages importing rjags can be lazy-loaded by
# the native R that drives the cross-compilation (rwasm installs host deps
# with pak before R CMD INSTALL).
docker exec builder bash -c 'export DEBIAN_FRONTEND=noninteractive; apt-get update -qq && apt-get install -y -qq jags pkg-config >/dev/null && jags </dev/null | head -2'
docker exec builder Rscript -e 'rwasm::write_packages("_site")'
echo "::endgroup::"

fix_owner() { docker exec builder chown -R "$(id -u):$(id -g)" /work/_site /work/results; }

echo "::group::Order (deps first)"
docker exec builder Rscript scripts/closure.R --order --tsv $PKGS > results/order.tsv
cat results/order.tsv
echo "::endgroup::"

git -C _site config user.name "github-actions[bot]"
git -C _site config user.email "41898282+github-actions[bot]@users.noreply.github.com"

push_site() {
  local msg=$1
  fix_owner
  git -C _site add -A bin src
  git -C _site diff --cached --quiet && return 0
  git -C _site commit -q -m "$msg"
  for i in 1 2 3 4 5 6; do
    if git -C _site push -q origin HEAD:site; then return 0; fi
    # Another builder pushed meanwhile. Only distinct package files are
    # committed (PACKAGES indexes are generated at deploy time), so a rebase
    # only conflicts when both built the same package; keep ours.
    git -C _site fetch -q origin site
    git -C _site rebase -q -X theirs origin/site || { git -C _site rebase --abort; return 1; }
    sleep $((i * 5))
  done
  return 1
}

declare -A status
ok=(); failed=(); deferred=()
while IFS=$'\t' read -r p deps; do
  [ -n "$p" ] || continue
  # Skip when a dependency inside this batch did not build.
  blocker=""
  for d in ${deps//,/ }; do
    case "${status[$d]:-}" in ok|present) ;; *) blocker="$d"; break ;; esac
  done
  if [ -n "$blocker" ]; then
    status[$p]=blocked; failed+=("$p")
    printf '%s\tblocked\t0\t\tdependency %s did not build\n' "$p" "$blocker" >> "$res"
    continue
  fi
  elapsed_min=$(( ($(date +%s) - t0) / 60 ))
  left=$(( CAP_MIN - elapsed_min ))
  if [ "$left" -lt 3 ]; then
    status[$p]=deferred; deferred+=("$p")
    printf '%s\tdeferred\t0\t\ttime cap (%s min) reached\n' "$p" "$CAP_MIN" >> "$res"
    continue
  fi
  t=$(( left < PER_PKG_MIN ? left : PER_PKG_MIN ))
  log="results/logs/$p.log"
  echo "::group::$p (timeout ${t}m, ${left}m left)"
  s=$(date +%s)
  set +e
  docker exec builder timeout -k 60 "${t}m" Rscript scripts/build-one.R "$p" _site > "$log" 2>&1
  rc=$?
  set -e
  secs=$(( $(date +%s) - s ))
  tail -n 15 "$log"
  echo "::endgroup::"
  ver=$(sed -n "s/^RESULT: built $p //p" "$log" | tail -1)
  case $rc in
    0)
      if push_site "feat: add $p $ver (wasm)"; then
        status[$p]=ok; ok+=("$p")
        printf '%s\tok\t%s\t%s\t\n' "$p" "$secs" "$ver" >> "$res"
      else
        status[$p]=failed; failed+=("$p")
        printf '%s\tfailed\t%s\t%s\tpush to site branch failed\n' "$p" "$secs" "$ver" >> "$res"
      fi ;;
    2)
      status[$p]=present; ok+=("$p")
      printf '%s\tpresent\t%s\t\talready in the store\n' "$p" "$secs" >> "$res" ;;
    *)
      status[$p]=failed; failed+=("$p")
      if [ "$rc" -eq 124 ] || [ "$rc" -eq 137 ]; then
        reason="timeout after ${t} min"
      else
        # First compiler/R error line is the most telling one.
        reason=$(grep -m1 -E 'fatal error:|error: |ERROR: |Error in |Error: |there is no package called|configuration failed|cannot find -l' "$log" \
                 | tr '\t' ' ' | cut -c1-200 || true)
        [ -n "$reason" ] || reason="build failed (exit $rc)"
      fi
      printf '%s\tfailed\t%s\t\t%s\n' "$p" "$secs" "$reason" >> "$res"
      # Restore the tree to the last pushed state (drop partial outputs).
      fix_owner
      git -C _site checkout -q -- bin src 2>/dev/null || true
      git -C _site clean -qfd bin src
      docker exec builder Rscript -e 'rwasm::write_packages("_site")' > /dev/null
      ;;
  esac
done < results/order.tsv

fix_owner
docker rm -f builder >/dev/null

total=$(( $(date +%s) - t0 ))
{
  echo "| package | status | seconds | version | detail |"
  echo "|---|---|---|---|---|"
  tail -n +2 "$res" | awk -F'\t' '{gsub(/\|/,"\\|",$5); printf "| %s | %s | %s | %s | %s |\n",$1,$2,$3,$4,$5}'
  echo
  echo "Total: ${total}s; ok ${#ok[@]}, failed ${#failed[@]}, deferred ${#deferred[@]}."
} > results/summary.md
cat results/summary.md

{
  echo "ok=${ok[*]:-}"
  echo "failed=${failed[*]:-}"
  echo "deferred=${deferred[*]:-}"
  echo "seconds=$total"
} >> "${GITHUB_OUTPUT:-/dev/null}"

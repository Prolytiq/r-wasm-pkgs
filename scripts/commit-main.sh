#!/usr/bin/env bash
# Apply a mutation to a fresh copy of origin/main, commit and push; on a push
# race, start over from the new origin/main (no rebase conflicts on append-only
# files such as `packages` or queue/status.tsv).
#
# Usage: scripts/commit-main.sh "<commit message>" <command> [args...]
# The command runs in a clean checkout of origin/main (cwd = repo root) and
# must be idempotent. Nothing is committed when it changes nothing.
set -euo pipefail
# The reset below may rewrite this very file; run from a private copy.
if [ -z "${COMMIT_MAIN_COPY:-}" ]; then
  c=$(mktemp); cp "$0" "$c"; COMMIT_MAIN_COPY=1 exec bash "$c" "$@"
fi
msg=$1; shift
git config user.name "github-actions[bot]"
git config user.email "41898282+github-actions[bot]@users.noreply.github.com"
for i in 1 2 3 4 5 6 7 8; do
  git fetch -q origin main
  git checkout -q -B main-commit origin/main
  git reset -q --hard origin/main
  "$@"
  if git diff --quiet && [ -z "$(git ls-files --others --exclude-standard queue packages)" ]; then
    echo "Nothing to commit."; exit 0
  fi
  git add -A packages queue
  git commit -q -m "$msg" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
  if git push -q origin HEAD:main; then git log --oneline -1; exit 0; fi
  sleep $((i * 3))
done
echo "push to main failed after retries"; exit 1

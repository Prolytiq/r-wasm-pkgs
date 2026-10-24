#!/usr/bin/env bash
# Append the given package names to `packages` unless already listed.
set -euo pipefail
name_re='^[A-Za-z][A-Za-z0-9.]*[A-Za-z0-9]$'
[ -n "$(tail -c1 packages)" ] && echo >> packages
for p in "$@"; do
  [[ $p =~ $name_re ]] || { echo "invalid name: $p"; exit 1; }
  grep -qxF "$p" packages || echo "$p" >> packages
done

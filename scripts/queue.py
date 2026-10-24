#!/usr/bin/env python3
"""Priority build queue for CRAN packages missing from every wasm repo.

gap = CRAN \\ (repo.r-wasm.org 4.6 ∪ this repo ∪ jags-wasm ∪ base)

Files (committed):
  queue/priority.tsv  package <TAB> downloads_last_month   (gap, most downloaded first)
  queue/status.tsv    package <TAB> status <TAB> reason <TAB> updated <TAB> run
                      status: built | failed | blocked  (absent = pending)

Commands:
  refresh             recompute the gap + cranlogs downloads, rewrite priority.tsv
  pick N              print the next N pending packages (priority order)
  filter TSV OUT [RUN] read `closure.R --to-build --tsv` output (TSV), drop
                      packages already failed/blocked and everything depending
                      on them (recorded as blocked); write the rest to OUT
  record RESULTS RUN  fold build-batch results.tsv into status.tsv
  stats               print a summary
"""
import json
import sys
import time
import urllib.request
from datetime import datetime, timezone
from pathlib import Path

QDIR = Path("queue")
PRIO = QDIR / "priority.tsv"
STATUS = QDIR / "status.tsv"
BASE = {"base", "stats", "utils", "methods", "graphics", "grDevices", "grid", "tools",
        "parallel", "splines", "stats4", "tcltk", "compiler", "datasets", "R"}
INDEXES = {
    "cran": "https://cloud.r-project.org/src/contrib/PACKAGES",
    "r-wasm": "https://repo.r-wasm.org/bin/emscripten/contrib/4.6/PACKAGES",
    "prolytiq": "https://prolytiq.github.io/r-wasm-pkgs/bin/emscripten/contrib/4.6/PACKAGES",
    "jags-wasm": "https://prolytiq.github.io/jags-wasm/bin/emscripten/contrib/4.6/PACKAGES",
}


def fetch(url, tries=4):
    for i in range(tries):
        try:
            req = urllib.request.Request(url, headers={"User-Agent": "prolytiq-r-wasm-pkgs-queue"})
            with urllib.request.urlopen(req, timeout=120) as r:
                return r.read().decode("utf-8", "replace")
        except Exception as e:  # noqa: BLE001
            if i == tries - 1:
                raise
            print(f"retry {url}: {e}", file=sys.stderr)
            time.sleep(5 * (i + 1))


def index_names(url):
    sep = "&" if "?" in url else "?"
    text = fetch(f"{url}{sep}nocache={int(time.time())}")
    names = {line[9:].strip() for line in text.splitlines() if line.startswith("Package: ")}
    if not names:
        sys.exit(f"empty index: {url}")
    return names


def read_status():
    st = {}
    if STATUS.exists():
        for line in STATUS.read_text().splitlines()[1:]:
            if line.strip():
                f = (line.split("\t") + [""] * 5)[:5]
                st[f[0]] = f
    return st


def write_status(st):
    QDIR.mkdir(exist_ok=True)
    rows = ["package\tstatus\treason\tupdated\trun"]
    rows += ["\t".join(st[k]) for k in sorted(st, key=str.lower)]
    STATUS.write_text("\n".join(rows) + "\n")


def read_prio():
    rows = []
    for line in PRIO.read_text().splitlines()[1:]:
        if line.strip():
            p, d = line.split("\t")[:2]
            rows.append((p, int(d)))
    return rows


def refresh():
    idx = {k: index_names(u) for k, u in INDEXES.items()}
    gap = sorted(idx["cran"] - idx["r-wasm"] - idx["prolytiq"] - idx["jags-wasm"] - BASE)
    print(f"CRAN {len(idx['cran'])}, r-wasm {len(idx['r-wasm'])}, prolytiq {len(idx['prolytiq'])}, "
          f"jags-wasm {len(idx['jags-wasm'])} -> gap {len(gap)}", file=sys.stderr)
    downloads = {}
    for i in range(0, len(gap), 100):
        batch = gap[i:i + 100]
        url = "https://cranlogs.r-pkg.org/downloads/total/last-month/" + ",".join(batch)
        try:
            data = json.loads(fetch(url))
        except Exception as e:  # noqa: BLE001
            print(f"cranlogs batch {i} failed: {e}", file=sys.stderr)
            data = []
        for row in data if isinstance(data, list) else []:
            if row.get("package"):
                downloads[row["package"]] = int(row.get("downloads") or 0)
        time.sleep(0.5)
    if len(downloads) < len(gap) // 2:
        sys.exit(f"cranlogs returned only {len(downloads)}/{len(gap)} packages; not rewriting")
    rows = sorted(gap, key=lambda p: (-downloads.get(p, 0), p.lower()))
    QDIR.mkdir(exist_ok=True)
    PRIO.write_text("package\tdownloads_last_month\n" +
                    "".join(f"{p}\t{downloads.get(p, 0)}\n" for p in rows))
    # Built-here packages leave the gap (they are in our index now); keep their
    # status rows as history.
    print(f"priority.tsv: {len(rows)} packages", file=sys.stderr)


def pick(n):
    st = read_status()
    out = [p for p, _ in read_prio() if p not in st][:n]
    print("\n".join(out))


def filter_(tsv_path, out_path, run=""):
    st = read_status()
    bad = {p for p, f in st.items() if f[1] in ("failed", "blocked")}
    keep, now = [], stamp()
    for line in Path(tsv_path).read_text().splitlines():
        if not line.strip():
            continue
        p, _, deps = line.partition("\t")
        deps = [d for d in deps.strip().split(",") if d]
        blocker = next((d for d in deps if d in bad), None)
        if p in bad:
            continue
        if blocker:
            bad.add(p)
            st[p] = [p, "blocked", f"dependency {blocker} failed earlier", now, run]
            continue
        keep.append(p)
    write_status(st)
    Path(out_path).write_text(" ".join(keep) + "\n")


def stamp():
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%MZ")


def record(results, run):
    st = read_status()
    now = stamp()
    for line in Path(results).read_text().splitlines()[1:]:
        f = (line.split("\t") + [""] * 5)[:5]
        p, status, _secs, ver, reason = f
        if status in ("ok", "present"):
            st[p] = [p, "built", ver, now, run]
        elif status in ("failed", "blocked"):
            st[p] = [p, status, reason.replace("\t", " ")[:200], now, run]
        # deferred: stays pending
    write_status(st)


def stats():
    st = read_status()
    prio = read_prio() if PRIO.exists() else []
    gap = {p for p, _ in prio}
    counts = {}
    for f in st.values():
        counts[f[1]] = counts.get(f[1], 0) + 1
    pending = [p for p, _ in prio if p not in st]
    print(f"gap (priority.tsv): {len(gap)}; status: {counts}; pending: {len(pending)}")
    reasons = {}
    for f in st.values():
        if f[1] == "failed":
            key = f[2][:80]
            reasons[key] = reasons.get(key, 0) + 1
    for r, c in sorted(reasons.items(), key=lambda x: -x[1])[:15]:
        print(f"  {c:4d}  {r}")


if __name__ == "__main__":
    cmd = sys.argv[1] if len(sys.argv) > 1 else ""
    if cmd == "refresh":
        refresh()
    elif cmd == "pick":
        pick(int(sys.argv[2]))
    elif cmd == "filter":
        filter_(sys.argv[2], sys.argv[3], sys.argv[4] if len(sys.argv) > 4 else "")
    elif cmd == "record":
        record(sys.argv[2], sys.argv[3])
    elif cmd == "stats":
        stats()
    else:
        sys.exit(__doc__)

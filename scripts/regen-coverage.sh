#!/usr/bin/env bash
# scripts/regen-coverage.sh
#
# Extracts the inline JSON coverage payload from coverage.html and writes it
# to coverage.json for downstream tooling (CI dashboards, scrapers, agents).
#
# Usage:
#   ./scripts/regen-coverage.sh
#
# Exit codes:
#   0 — coverage.json written
#   1 — coverage.html missing or malformed (no <script id="coverage-data">)

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HTML="${ROOT}/coverage.html"
JSON="${ROOT}/coverage.json"

if [[ ! -f "${HTML}" ]]; then
  echo "error: ${HTML} not found" >&2
  exit 1
fi

python3 - "${HTML}" "${JSON}" <<'PY'
import json
import re
import sys

html_path, json_path = sys.argv[1], sys.argv[2]

with open(html_path, "r", encoding="utf-8") as f:
    html = f.read()

m = re.search(
    r'<script id="coverage-data"[^>]*>(.*?)</script>',
    html,
    re.DOTALL,
)
if not m:
    print(
        "error: <script id=\"coverage-data\"> block not found in coverage.html",
        file=sys.stderr,
    )
    sys.exit(1)

data = json.loads(m.group(1))

# Sanity check the shape we expect.
if "groups" not in data or not isinstance(data["groups"], list):
    print("error: coverage payload missing 'groups' array", file=sys.stderr)
    sys.exit(1)

# Aggregate counts so consumers don't have to.
def count(rows):
    c = {"ok": 0, "partial": 0, "miss": 0}
    for r in rows:
        c[r[1]] = c.get(r[1], 0) + 1
    return c

all_rows = [r for g in data["groups"] for r in g["rows"]]
data["counts"] = count(all_rows)
data["total"] = len(all_rows)
for g in data["groups"]:
    g["counts"] = count(g["rows"])
    g["total"] = len(g["rows"])

with open(json_path, "w", encoding="utf-8") as f:
    json.dump(data, f, indent=2, sort_keys=False)
    f.write("\n")

print(
    f"wrote {json_path} — {data['total']} rows "
    f"(ok={data['counts']['ok']}, "
    f"partial={data['counts']['partial']}, "
    f"miss={data['counts']['miss']})"
)
PY

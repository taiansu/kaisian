#!/bin/bash
# Exercises setup.sh's WSL path inside an Ubuntu container. Needs macOS (plutil records
# the reference outputs plutil_compat must reproduce), Docker, and network access for
# apt, GNU Stow, and the real dotfiles repository.
set -u

TESTS=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd -P)
REPO=$(cd "$TESTS/.." && pwd -P)
WORK=$(mktemp -d "${TMPDIR:-/tmp}/kaisian-wsl-test.XXXXXX") || exit 1
trap 'rm -rf -- "$WORK"' EXIT

command -v docker >/dev/null 2>&1 || { echo 'docker is required' >&2; exit 1; }
test -x /usr/bin/plutil || { echo 'run on macOS: /usr/bin/plutil records the reference outputs' >&2; exit 1; }

mkdir -p "$WORK/manifests"
cp "$REPO/web/fixtures/manifest.json" "$WORK/manifests/web.json"
cp "$REPO/tests/fixtures/manifest-v2.json" "$WORK/manifests/v2.json"
cp "$REPO/tests/fixtures/manifest-valid.json" "$WORK/manifests/valid.json"
# Scalars and shapes the manifests do not cover. No floats: raw floats differ by design.
printf '%s\n' '{"t":true,"f":false,"i":3,"neg":-2,"empty":[],"obj":{},"s":"a b","zh":"中文","nest":{"a":[{"k":"v"},[1,2]]}}' > "$WORK/manifests/edge.json"

python3 - "$WORK" <<'EOF' || exit 1
import json, os, subprocess, sys
work = sys.argv[1]

def paths(value, prefix=""):
    if prefix:
        yield prefix
    if isinstance(value, dict):
        for key, child in value.items():
            yield from paths(child, f"{prefix}.{key}" if prefix else key)
    elif isinstance(value, list):
        for index, child in enumerate(value):
            yield from paths(child, f"{prefix}.{index}" if prefix else str(index))

cases = []
for name in sorted(os.listdir(f"{work}/manifests")):
    rel = f"manifests/{name}"
    with open(f"{work}/{rel}") as handle:
        data = json.load(handle)
    for path in [*paths(data), "missing", "groups.999", "groups.x"]:
        for args in (["-type", path, rel], ["-extract", path, "raw", rel], ["-extract", path, "json", "-o", "-", rel]):
            result = subprocess.run(["/usr/bin/plutil", *args], capture_output=True, text=True, cwd=work)
            ok = result.returncode == 0
            cases.append({"args": args, "rc": 0 if ok else 1, "out": result.stdout.rstrip("\n") if ok else ""})
with open(f"{work}/plutil.json", "w") as handle:
    json.dump(cases, handle)
EOF

curl -fsSL -o "$WORK/stow.tar.gz" https://ftp.gnu.org/gnu/stow/stow-2.4.1.tar.gz || exit 1

docker run --rm -v "$WORK:/work:ro" -v "$REPO:/repo:ro" ubuntu:24.04 bash /repo/tests/wsl/container_test.sh

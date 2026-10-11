#!/usr/bin/env bash
# End-to-end test of a patch script in a scratch clone with a local bare "origin", for Claude's sandbox.
# It runs the patch exactly as the person will (apply, checks, commit, push, self-delete), then runs
# tools/objc_diffcheck.sh against the commit before the patch.
#
# Usage:  tools/test_patch.sh PATCH.py [SOURCE]
#   SOURCE = a local repo path or a git URL (default: the repo this script lives in).
#   Public repo for a fresh sandbox:  https://github.com/pavsayganov-studio/AirVPN10
set -euo pipefail
PATCH="$(readlink -f "$1")"
DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
SRC="${2:-$(cd "$DIR/.." && pwd)}"
T="$(mktemp -d)"
git clone -q --bare "$SRC" "$T/origin.git"
git clone -q "$T/origin.git" "$T/work"
cd "$T/work"
git config user.email test@example.com; git config user.name tester
cp "$PATCH" .
python3 "$(basename "$PATCH")"
echo "--- origin/main now:";            git -C "$T/origin.git" log --oneline -2
echo "--- patch script deleted itself: $([ -e "$(basename "$PATCH")" ] && echo NO || echo yes)"
echo "--- tracked files left modified: $(git status --porcelain --untracked-files=no | wc -l)"
echo "--- leftover backup files (*.bak*): $(find . -path ./.git -prune -o -name '*.bak*' -print | wc -l)  (must be 0)"
echo "--- off-device syntax check vs the commit before the patch:"
"$DIR/objc_diffcheck.sh" HEAD~1 || true
echo "scratch clone kept at: $T/work"

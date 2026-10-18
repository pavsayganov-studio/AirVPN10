#!/bin/bash
# tools/lint_objc.sh [FILE...]  (default: every *.m / *.h in the repo root)
#
# Flags names that collide with Objective-C's hidden method arguments (`_cmd`, `_sel`). v0.15.0 shipped an
# ivar called `_cmd`: the Actions build failed with 6 errors, and tools/objc_diffcheck.sh could not see it
# (on the GNUstep legacy runtime ivars are reported as undeclared anyway). Cheap, text-only, exit 1 on a hit.
cd "$(dirname "$0")/.." || exit 2
if [ $# -gt 0 ]; then files=("$@"); else files=(*.m *.h); fi
hit=0
for f in "${files[@]}"; do
  [ -f "$f" ] || continue
  out=$(sed 's#//.*##' "$f" | grep -nE '(^|[^A-Za-z0-9_])(_cmd|_sel)([^A-Za-z0-9_]|$)')
  if [ -n "$out" ]; then echo "$f:"; echo "$out" | sed 's/^/  line /'; hit=1; fi
done
[ $hit -eq 0 ] && echo "lint_objc: OK (no _cmd/_sel names)"
exit $hit

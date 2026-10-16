#!/usr/bin/env bash
# Off-device syntax check of DPIEngine.m (Foundation-only) on Linux, for Claude's sandbox.
#
# There is no macOS here, so this cannot prove the code compiles. It compiles the working-tree
# file and a baseline (default: HEAD) with clang on the legacy GNUstep runtime and reports only
# error CLASSES that are NEW. A baseline of platform errors always remains (no ARC, no object
# subscripting, no NSURLSession/SystemConfiguration), so "same classes as before" is the pass
# criterion; a typo, a missing ivar or an undeclared identifier shows up as a new class.
#
# Usage:  tools/objc_diffcheck.sh [BASE_REF=HEAD] [FILE=DPIEngine.m]
# FILE may also be AppDelegate.m or ViewController.m (AppKit via GNUstep-gui: a much larger baseline of
# platform errors, e.g. 150 for ViewController.m, but a new class is still a real signal; macOS-only
# API names GNUstep lacks, such as NSCompositingOperationClear, show up as "NEW CLASS" - check them
# against Apple docs before treating them as bugs).
# Exit 0 = no new error class; 1 = new class(es); 2 = toolchain problem.
set -euo pipefail
BASE="${1:-HEAD}"; FILE="${2:-DPIEngine.m}"; HDR="${FILE%.m}.h"
ROOT="$(git rev-parse --show-toplevel)"
GCCINC="$(ls -d /usr/lib/gcc/x86_64-linux-gnu/*/include 2>/dev/null | tail -1 || true)"

if ! command -v clang >/dev/null || ! command -v gnustep-config >/dev/null || [ ! -d "${GCCINC}/objc" ]; then
  echo "installing the toolchain (once, ~1 min)..." >&2
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq >/dev/null 2>&1 || true
  apt-get install -y -qq gobjc libgnustep-base-dev libgnustep-gui-dev gnustep-make clang libobjc-13-dev libblocksruntime-dev >/dev/null 2>&1 \
    || { echo "toolchain install failed (network? apt?)" >&2; exit 2; }
  GCCINC="$(ls -d /usr/lib/gcc/x86_64-linux-gnu/*/include | tail -1)"
fi

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
S="$TMP/stubs"; mkdir -p "$S/dispatch" "$S/SystemConfiguration" "$S/CoreFoundation" "$S/objc" "$S/Cocoa"
printf '#pragma once\n#import <Foundation/Foundation.h>\n#import <AppKit/AppKit.h>\n' > "$S/Cocoa/Cocoa.h"
echo '#pragma once' > "$S/CoreFoundation/CoreFoundation.h"
printf '#pragma once\n#include <CoreFoundation/CoreFoundation.h>\n' > "$S/SystemConfiguration/SystemConfiguration.h"
cat > "$S/objc/blocks_runtime.h" <<'H'
#pragma once
extern void *_NSConcreteGlobalBlock[32]; extern void *_NSConcreteStackBlock[32];
void *_Block_copy(const void *); void _Block_release(const void *);
H
cat > "$S/libproc.h" <<'H'
#pragma once
#include <sys/types.h>
#include <stdint.h>
#define PROC_PIDPATHINFO_MAXSIZE 4096
#define PROC_ALL_PIDS 1
int proc_pidpath(int pid, void *buf, uint32_t size);
int proc_listpids(uint32_t type, uint32_t info, void *buf, int size);
int proc_name(int pid, void *buf, uint32_t size);
H
cat > "$S/dispatch/dispatch.h" <<'H'
#pragma once
#include <stddef.h>
#include <stdint.h>
typedef void *dispatch_queue_t; typedef void *dispatch_group_t; typedef void *dispatch_semaphore_t; typedef void *dispatch_source_t;
typedef long dispatch_once_t; typedef uint64_t dispatch_time_t; typedef void *dispatch_object_t;
typedef void (^dispatch_block_t)(void);
#define DISPATCH_QUEUE_SERIAL NULL
#define DISPATCH_QUEUE_CONCURRENT NULL
#define DISPATCH_TIME_FOREVER (~0ull)
#define DISPATCH_TIME_NOW 0ull
#define NSEC_PER_SEC 1000000000ull
#define NSEC_PER_MSEC 1000000ull
#define QOS_CLASS_UTILITY 0x11
#define QOS_CLASS_USER_INITIATED 0x19
#define QOS_CLASS_BACKGROUND 0x09
#define DISPATCH_QUEUE_PRIORITY_DEFAULT 0
dispatch_queue_t dispatch_queue_create(const char *l, void *a);
dispatch_queue_t dispatch_get_main_queue(void);
dispatch_queue_t dispatch_get_global_queue(long id, unsigned long f);
void dispatch_async(dispatch_queue_t q, dispatch_block_t b);
void dispatch_sync(dispatch_queue_t q, dispatch_block_t b);
void dispatch_after(dispatch_time_t t, dispatch_queue_t q, dispatch_block_t b);
dispatch_time_t dispatch_time(dispatch_time_t w, int64_t d);
void dispatch_once(dispatch_once_t *p, dispatch_block_t b);
dispatch_group_t dispatch_group_create(void);
void dispatch_group_enter(dispatch_group_t g); void dispatch_group_leave(dispatch_group_t g);
long dispatch_group_wait(dispatch_group_t g, dispatch_time_t t);
void dispatch_group_async(dispatch_group_t g, dispatch_queue_t q, dispatch_block_t b);
dispatch_semaphore_t dispatch_semaphore_create(long v);
long dispatch_semaphore_wait(dispatch_semaphore_t s, dispatch_time_t t); long dispatch_semaphore_signal(dispatch_semaphore_t s);
H

# v0.14.2: Apple headers Linux lacks. Without them a file that includes them never compiled and the
# check below reported "0 errors" (see handoff.md section 21).
mkdir -p "$S/CommonCrypto" "$S/sys"
cat > "$S/CommonCrypto/CommonDigest.h" <<'H'
#pragma once
#include <stdint.h>
typedef uint32_t CC_LONG;
#define CC_SHA256_DIGEST_LENGTH 32
typedef struct { uint32_t x[64]; } CC_SHA256_CTX;
int CC_SHA256_Init(CC_SHA256_CTX *c);
int CC_SHA256_Update(CC_SHA256_CTX *c, const void *d, CC_LONG l);
int CC_SHA256_Final(unsigned char *m, CC_SHA256_CTX *c);
H
cat > "$S/sys/sysctl.h" <<'H'
#pragma once
#include <stddef.h>
int sysctlbyname(const char *n, void *o, size_t *ol, void *np, size_t nl);
H

prep() {  # $1 = out dir, $2 = "wt" or a git ref
  mkdir -p "$1"
  local names
  if [ "$2" = wt ]; then names="$(cd "$ROOT" && ls *.h *.m)"; else names="$(git -C "$ROOT" ls-tree --name-only "$2" | grep -E '\.(h|m)$')"; fi
  for f in $names; do
    if [ "$2" = wt ]; then cp "$ROOT/$f" "$1/$f"; else git -C "$ROOT" show "$2:$f" > "$1/$f"; fi
  done
}
prep "$TMP/wt" wt; prep "$TMP/base" "$BASE"

cat > "$TMP/chk.py" <<'PY'
import collections, json, os, re, subprocess, sys
d, fname, stubs, gcc = sys.argv[1:5]
hname = fname[:-2] + ".h"
m = open(os.path.join(d, fname), encoding="utf-8").read()
# legacy runtime: instance variables may not live in a class extension, so move them to the header
blk = re.search(r"@interface \w+ \(\) \{(.*?)\n\}\n@end", m, re.S)
if blk:
    cls = re.search(r"@interface (\w+) \(\)", blk.group(0)).group(1)
    m = m.replace(blk.group(0), "")
    h = open(os.path.join(d, hname), encoding="utf-8").read()
    h = re.sub(r"@interface %s : (\w+)" % cls, lambda mm: "@interface %s : %s {%s\n}" % (cls, mm.group(1), blk.group(1)), h, count=1)
    open(os.path.join(d, hname), "w", encoding="utf-8").write(h)
open(os.path.join(d, fname), "w", encoding="utf-8").write(m)
fl = subprocess.check_output("gnustep-config --objc-flags", shell=True, text=True)
fl = [x for x in fl.replace("-fexceptions", "").replace("-fobjc-nonfragile-abi", "").split() if x not in ("-MMD", "-MP", "-MD")]
cmd = ["clang", "-x", "objective-c", "-fsyntax-only", "-fblocks", "-fobjc-exceptions", "-fgnu-runtime",
       "-ferror-limit=0", "-Wno-everything", "-I" + stubs, "-I" + gcc, "-include", "dispatch/dispatch.h"] + fl + [os.path.join(d, fname)]
out = subprocess.run(cmd, capture_output=True, text=True, cwd=d).stderr   # cwd = temp dir: no stray .d files in the repo
c = collections.Counter()
for line in out.splitlines():
    r = re.match(r"^[^:]+:\d+:\d+: (?:fatal )?error: (.*)$", line)   # a fatal error (missing header) counts too
    if r: c[r.group(1)] += 1
print(json.dumps(c))
PY
if [ ! -f "$TMP/base/$FILE" ]; then   # a file this commit adds: no baseline to diff against
  echo "NEW FILE $FILE (not in $BASE): its error classes are listed for review; GNUstep platform noise is expected"
  python3 "$TMP/chk.py" "$TMP/wt" "$FILE" "$S" "$GCCINC" | python3 -c 'import json,sys; [print("%5d  %s" % (v, k)) for k, v in sorted(json.load(sys.stdin).items())]'
  exit 0
fi
base_json="$(python3 "$TMP/chk.py" "$TMP/base" "$FILE" "$S" "$GCCINC")"
wt_json="$(python3 "$TMP/chk.py" "$TMP/wt" "$FILE" "$S" "$GCCINC")"

python3 - "$base_json" "$wt_json" "$BASE" <<'PY'
import json, sys
b, w = json.loads(sys.argv[1]), json.loads(sys.argv[2])
new = {k: v for k, v in w.items() if k not in b}
up = {k: (b[k], w[k]) for k in w if k in b and w[k] > b[k]}
gone = {k: b[k] for k in b if k not in w}
print("baseline (%s): %d classes / %d errors;  working tree: %d classes / %d errors" %
      (sys.argv[3], len(b), sum(b.values()), len(w), sum(w.values())))
for k, v in sorted(new.items()): print("NEW CLASS  %3d  %s" % (v, k))
for k, (x, y) in sorted(up.items()): print("increased  %d -> %d  %s   (legacy-runtime noise if it is subscripting/receiver types)" % (x, y, k))
for k, v in sorted(gone.items()): print("gone       %3d  %s" % (v, k))
print("RESULT:", "FAIL - new error class(es), read them" if new else "PASS - no new error class")
sys.exit(1 if new else 0)
PY

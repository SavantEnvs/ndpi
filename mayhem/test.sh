#!/usr/bin/env bash
#
# mayhem/test.sh — RUN nDPI's own golden-output suite (tests/cfgs/default, as tests/do.sh does) against the
# unsanitized ndpiReader that mayhem/build.sh built in build-tests/.
# exit 0 = pass. EDIT per repo. PATCH-grade oracle: after an agent patches the source, the grader
# rebuilds (build.sh) then runs this. DELETE this file if the repo has no meaningful tests.
#
# IMPORTANT:
#  * Must assert BEHAVIOR/OUTPUT, not just exit status. The oracle has to check asserted values /
#    golden-output diffs / known-answer results — so a PATCH that "fixes" a bug by making the program
#    exit(0) (or any no-op) FAILS here. Running inputs and checking only "exit 0 / didn't crash" is
#    NOT a functional test (it's trivially reward-hackable) — use the project's real assertion suite.
#  * Do NOT build here — mayhem/build.sh already compiled the test suite (with the project's normal
#    flags). This script only RUNS the pre-built tests and reports counts. If the test runner is
#    missing, that's a build.sh bug — fail loudly rather than silently rebuilding.
#  * REQUIRED OUTPUT — a CTRF (https://ctrf.io) summary so Mayhem/the PATCH grader reads the counts:
#      - writes a CTRF JSON report to ${CTRF_REPORT:-$SRC/ctrf-report.json}, and
#      - prints a one-line `CTRF {...}` marker to stdout (same JSON, compact).
#    Only `results.summary` (with tests/passed/failed/pending/skipped/other) is required.
#    Use the emit_ctrf helper below; it computes tests = passed+failed+skipped and sets the exit
#    code (0 iff failed==0). Map your framework's output to passed/failed/skipped.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
: "${MAYHEM_JOBS:=$(nproc)}"   # build parallelism; env-overridable, falls back to nproc (use -j"$MAYHEM_JOBS")
cd "$SRC"

# emit_ctrf <tool> <passed> <failed> [skipped] [pending] [other]
# Writes a CTRF report (file + stdout `CTRF {...}` marker) and returns non-zero iff failed>0.
emit_ctrf() {
  local tool="$1" passed="$2" failed="$3" skipped="${4:-0}" pending="${5:-0}" other="${6:-0}"
  local tests=$(( passed + failed + skipped + pending + other ))
  cat > "${CTRF_REPORT:-$SRC/ctrf-report.json}" <<JSON
{
  "results": {
    "tool": { "name": "$tool" },
    "summary": {
      "tests": $tests,
      "passed": $passed,
      "failed": $failed,
      "pending": $pending,
      "skipped": $skipped,
      "other": $other
    }
  }
}
JSON
  printf 'CTRF {"results":{"tool":{"name":"%s"},"summary":{"tests":%d,"passed":%d,"failed":%d,"pending":%d,"skipped":%d,"other":%d}}}\n' \
    "$tool" "$tests" "$passed" "$failed" "$pending" "$skipped" "$other"
  [ "$failed" -eq 0 ]
}

READER="$SRC/build-tests/example/ndpiReader"
CFG="$SRC/tests/cfgs/default"
[ -x "$READER" ] || { echo "missing $READER: mayhem/build.sh did not build it" >&2; emit_ctrf "ndpi-golden" 0 1; exit 1; }

# Same reader arguments as tests/do.sh's READER for the default configuration; the reader writes its
# classification report to -w, which is diffed against the committed expected result.
run_one() {
  local pcap="$1" name out
  name="$(basename "$pcap")"
  out="$(mktemp /tmp/ndpi-test.XXXXXX)"
  rm -f "$out"
  (cd "$SRC/example" && timeout 300 "$READER" \
      --cfg=filename.config,"$SRC/example/config.txt" -A -p "$PROTOS" \
      -c "$SRC/example/categories.txt" -r "$SRC/example/risky_domains.txt" \
      -j "$SRC/example/ja4_fingerprints.csv" -S "$SRC/example/sha1_fingerprints.csv" \
      -G "$SRC/lists" -L "$SRC/lists/public_suffix_list.dat" -q -K JSON -k /dev/null -t -v 2 \
      -i "$pcap" -w "$out" >/dev/null 2>&1) || true
  if [ -f "$out" ] && diff -q "$CFG/result/$name.out" "$out" >/dev/null 2>&1; then
    echo "PASS $name"
  else
    echo "FAIL $name"
  fi
  rm -f "$out"
}
export -f run_one

# example/protos.txt names www.ntop.org symbolically and the reader resolves it via DNS, so the goldens only
# match with network access. Pin the address they were recorded with: the same assertions, but hermetic.
PROTOS="$(mktemp /tmp/ndpi-protos.XXXXXX)"
sed -e 's|^ip:www\.ntop\.org@ntop|ip:116.203.142.127@ntop|' -e '/^ipv6:www\.ntop\.org@ntop/d' "$SRC/example/protos.txt" > "$PROTOS"
grep -q '^ip:116.203.142.127@ntop' "$PROTOS" || { echo "protos.txt pinning failed" >&2; emit_ctrf "ndpi-golden" 0 1; exit 1; }
export READER CFG SRC PROTOS

# These two pcaps need optional PCRE2 / nBPF support, which this build does not enable (same skip list as tests/do.sh).
skipped=0
list="$(mktemp /tmp/ndpi-pcaps.XXXXXX)"
for p in "$CFG"/pcap/*.*cap*; do
  case "$(basename "$p")" in
    WebattackRCE.pcap|h323-overflow.pcap) skipped=$((skipped + 1)) ;;
    *) echo "$p" >> "$list" ;;
  esac
done

results="$(xargs -a "$list" -P "$MAYHEM_JOBS" -I{} bash -c 'run_one "$1"' _ {})"
rm -f "$list" "$PROTOS"
passed=$(printf '%s\n' "$results" | grep -c '^PASS ' || true)
failed=$(printf '%s\n' "$results" | grep -c '^FAIL ' || true)
printf '%s\n' "$results" | grep '^FAIL ' | head -20 || true

# The reader's built-in unit tests (assertions inside ndpiReader --run-tests).
if (cd "$SRC/build-tests" && timeout 600 ./example/ndpiReader --run-tests >/tmp/ndpi-unit.log 2>&1); then
  passed=$((passed + 1))
else
  failed=$((failed + 1)); tail -20 /tmp/ndpi-unit.log
fi

emit_ctrf "ndpi-golden" "$passed" "$failed" "$skipped"

#!/usr/bin/env bash
#
# mayhem/build.sh — build nDPI's in-tree fuzz harnesses (fuzz/), a standalone reproducer for each, and
# the normal-flags build the functional oracle (mayhem/test.sh) runs.
#
# Layout (everything generated is under the gitignored /build-* trees, so `git clean -ffdX` + this
# script rebuilds it all):
#   /mayhem/build-out/<harness>             libFuzzer binaries + the data files they read (OSS-Fuzz $OUT layout)
#   /mayhem/<harness>-standalone            run-once reproducers (same harness, no libFuzzer runtime)
#   /mayhem/build-tests/example/ndpiReader  the unsanitized reader the oracle runs
set -euo pipefail

[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${STANDALONE_FUZZ_MAIN:=/opt/mayhem/StandaloneFuzzTargetMain.c}"
: "${MAYHEM_JOBS:=$(nproc)}"
: "${COVERAGE_FLAGS=}"
export SANITIZER_FLAGS DEBUG_FLAGS CC CXX LIB_FUZZING_ENGINE MAYHEM_JOBS COVERAGE_FLAGS

cd "$SRC"
OUT="$SRC/build-out"

rm -rf "$SRC"/build-fuzz "$SRC"/build-tests "$OUT" "$SRC"/*-standalone
mkdir -p "$OUT"

# autoreconf regenerates configure/Makefile.in in place (all gitignored upstream).
./autogen.sh

# ---- 1) sanitized + SanCov-instrumented library and fuzz targets ------------------------------------
# -fsanitize=fuzzer-no-link goes on the library compile unconditionally (even when SANITIZER_FLAGS is
# empty): LIB_FUZZING_ENGINE alone only instruments the harness TUs, leaving libndpi at 0 edges.
# Alignment checks are relaxed: nDPI parses packets with unaligned u_int32_t loads (benign on x86; OSS-Fuzz's
# nDPI build doesn't enable the check either) and they would halt on the first seed that carries one.
FUZZ_CFLAGS="$SANITIZER_FLAGS -fno-sanitize=alignment -fsanitize=fuzzer-no-link $DEBUG_FLAGS"
# Non-PIE links drop ~10 MB of relative relocations from each of the 136 binaries.
FUZZ_LDFLAGS="$FUZZ_CFLAGS -no-pie"

# Objects linked into every fuzz and standalone binary: the LSan-off hook, and the data-dir pinning
# the harnesses' argv[0]/cwd lookups rely on.
$CXX $SANITIZER_FLAGS $DEBUG_FLAGS -c "$SRC/mayhem/lsan_off.cc" -o "$SRC/build-fuzz-lsan_off.o"
$CC $SANITIZER_FLAGS $DEBUG_FLAGS -DMAYHEM_DATA_DIR="\"$OUT\"" -c "$SRC/mayhem/chdir_exe.c" -o "$SRC/build-fuzz-chdir_exe.o"
# Must be a C object: compiled as C++ the driver's LLVMFuzzerTestOneInput reference would be mangled.
$CC $SANITIZER_FLAGS $DEBUG_FLAGS -x c -c "$STANDALONE_FUZZ_MAIN" -o "$SRC/build-fuzz-standalone_main.o"
# The pl7m harnesses' custom mutator calls libFuzzer's LLVMFuzzerMutate, absent without the runtime.
$CC $SANITIZER_FLAGS $DEBUG_FLAGS -c "$SRC/mayhem/standalone_stubs.c" -o "$SRC/build-fuzz-standalone_stubs.o"
EXTRA_OBJS="$SRC/build-fuzz-lsan_off.o $SRC/build-fuzz-chdir_exe.o"

mkdir build-fuzz
(
  cd build-fuzz
  ../configure CC="$CC" CXX="$CXX" \
    CFLAGS="$FUZZ_CFLAGS" CXXFLAGS="$FUZZ_CFLAGS" LDFLAGS="$FUZZ_CFLAGS" \
    ADDITIONAL_LIBS="-lpcap -ljson-c" \
    --enable-fuzztargets --with-only-libndpi --disable-shared
  make -j"$MAYHEM_JOBS" -C src/lib
  make -j"$MAYHEM_JOBS" -C fuzz LIB_FUZZING_ENGINE="$LIB_FUZZING_ENGINE" LDFLAGS="$FUZZ_LDFLAGS $EXTRA_OBJS"

  HARNESSES=$(find fuzz -maxdepth 1 -type f -name 'fuzz_*' -perm -u+x ! -name '*.*' -printf '%f\n' | sort)
  [ -n "$HARNESSES" ] || { echo "no fuzz targets were built" >&2; exit 1; }
  for h in $HARNESSES; do cp "fuzz/$h" "$OUT/$h"; done

  # ---- 2) standalone reproducers: same harness objects, run-once driver instead of libFuzzer --------
  make -C fuzz clean
  make -j"$MAYHEM_JOBS" -C fuzz LIB_FUZZING_ENGINE="" LDFLAGS="$FUZZ_LDFLAGS $SRC/build-fuzz-standalone_main.o $SRC/build-fuzz-standalone_stubs.o $EXTRA_OBJS"
  for h in $HARNESSES; do cp "fuzz/$h" "$SRC/$h-standalone"; done
)

# ---- data the harnesses read from dirname(argv[0]) / cwd (mirrors tests/ossfuzz.sh) --------------------
cp example/*.txt example/*.csv example/*.conf "$OUT"/
# protos.txt names www.ntop.org symbolically, which the reader resolves through DNS at startup; pin the
# address the goldens were recorded with so runs don't depend on the network (and drop the IPv6 twin).
sed -i -e 's|^ip:www\.ntop\.org@ntop|ip:116.203.142.127@ntop|' -e '/^ipv6:www\.ntop\.org@ntop/d' "$OUT/protos.txt"
cp lists/public_suffix_list.dat "$OUT"/
cp fuzz/ipv4_addresses.txt fuzz/ipv6_addresses.txt fuzz/bd_param.txt fuzz/splt_param.txt fuzz/random_list.list "$OUT"/
mkdir -p "$OUT/lists/protocols"
# the 100_malware list is huge and only slows every harness's init
find lists -maxdepth 1 -name '*.list' ! -name 100_malware.list -exec cp -t "$OUT/lists/" {} +
cp lists/protocols/*.list "$OUT/lists/protocols/"

# ---- 3) the oracle's build: project's normal flags, no sanitizers, no fuzz engine ----------------------
mkdir build-tests
(
  cd build-tests
  env -u CFLAGS -u CXXFLAGS -u LDFLAGS \
    ../configure CC="$CC" CXX="$CXX" CFLAGS="$COVERAGE_FLAGS" CXXFLAGS="$COVERAGE_FLAGS" LDFLAGS="$COVERAGE_FLAGS"
  make -j"$MAYHEM_JOBS"
)

# Only build-out/, the standalone binaries and build-tests/ are used afterwards; the fuzz tree is ~4 GB.
rm -rf "$SRC"/build-fuzz "$SRC"/build-fuzz-*.o

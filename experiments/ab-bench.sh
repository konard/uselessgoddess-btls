#!/usr/bin/env bash
# Authoritative A/B benchmark for the btls-sys build-time work.
# Isolates the btls-sys build via `cargo clean -p btls-sys` so each timed run is
# a true cold rebuild of BoringSSL + bindgen for that crate only.
#
# Timing uses integer nanoseconds (date +%s%N) -> no `bc` dependency.
# The baseline measures the ORIGINAL build script (stashed); a trap guarantees
# the stash is restored even if the run is interrupted.
set -u
cd "$(dirname "$0")/.."
export PATH="$PATH:/usr/local/bin"
export CARGO_INCREMENTAL=0 CARGO_PROFILE_DEV_DEBUG=0
SCC=/tmp/sccache-cache
RESULTS=experiments/ab-results.txt
STASH_MSG="btls-bench-baseline-$$"
: > "$RESULTS"

restore_stash() {
  if git stash list 2>/dev/null | grep -q "$STASH_MSG"; then
    echo "trap: restoring stashed build script"
    git stash pop -q || true
  fi
}
trap restore_stash EXIT

time_build() {            # $1 = label ; env already exported by caller
  local label="$1" t0 t1 ns ms
  cargo clean -p btls-sys >/dev/null 2>&1
  t0=$(date +%s%N)
  cargo build -p btls-sys >/dev/null 2>"experiments/_${label}.err"
  local rc=$?
  t1=$(date +%s%N)
  if [ $rc -ne 0 ]; then echo "$label: BUILD FAILED (rc=$rc)" | tee -a "$RESULTS"; tail -5 "experiments/_${label}.err"; return; fi
  ns=$(( t1 - t0 )); ms=$(( ns / 1000000 ))
  printf '%s: %d.%03ds\n' "$label" "$(( ms / 1000 ))" "$(( ms % 1000 ))" | tee -a "$RESULTS"
}

# ---- NEW CODE (working tree) -------------------------------------------------
echo "## NEW: ninja, cold (no C/C++ cache)" | tee -a "$RESULTS"
( unset RUSTC_WRAPPER RUSTC_WORKSPACE_WRAPPER BORING_BSSL_COMPILER_LAUNCHER CMAKE_GENERATOR
  time_build ninja-cold-1
  time_build ninja-cold-2 )

echo "## NEW: ninja + sccache, warm (the issue scenario: RUSTC_WRAPPER=sccache)" | tee -a "$RESULTS"
( unset CMAKE_GENERATOR
  export SCCACHE_DIR="$SCC" SCCACHE_CACHE_SIZE=20G RUSTC_WRAPPER=sccache
  sccache --start-server >/dev/null 2>&1
  time_build ninja-sccache-warmup     # populates the cache (not reported as the headline)
  sccache --zero-stats >/dev/null 2>&1
  time_build ninja-sccache-warm-1
  time_build ninja-sccache-warm-2
  echo "--- sccache stats over the two warm runs ---" | tee -a "$RESULTS"
  sccache --show-stats 2>/dev/null | grep -Ei 'compile requests|cache hits|cache misses|hit rate' | tee -a "$RESULTS" )

# ---- BASELINE (original build script, stashed) -------------------------------
echo "## BASELINE (original code: Unix Makefiles, no C/C++ cache)" | tee -a "$RESULTS"
git stash push -q -m "$STASH_MSG" btls-sys/build/main.rs
echo "(stashed my build script; working tree now has original)"
( unset RUSTC_WRAPPER RUSTC_WORKSPACE_WRAPPER BORING_BSSL_COMPILER_LAUNCHER
  export CMAKE_GENERATOR="Unix Makefiles"
  time_build baseline-make-1
  time_build baseline-make-2 )
git stash pop -q
trap - EXIT
echo "(restored my build script)"

echo "=== DONE ==="
cat "$RESULTS"

#!/usr/bin/env bash
# Tier 3: prove the fail-closed contract instead of asserting it.
#
# Forces the OS entropy syscall to fail and requires the process to die on
# SIGABRT. A build with a reachable /dev/urandom fallback would survive this
# and exit 0 — which is exactly the difference between "there is no fallback"
# and "there is a fallback we believe is unreachable".
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

HARNESS=build/harness
[ -x "$HARNESS" ] || { echo "build the harness first: make test"; exit 1; }

case "$(uname -s)" in
  Darwin) LIB=build/libfail.dylib; cc -dynamiclib -o "$LIB" tests/fail_interposer.c || exit 1
          PRELOAD_VAR=DYLD_INSERT_LIBRARIES ;;
  Linux)  LIB=build/libfail.so;    cc -shared -fPIC -o "$LIB" tests/fail_interposer.c || exit 1
          PRELOAD_VAR=LD_PRELOAD ;;
  *) echo "unsupported host"; exit 1 ;;
esac

fail=0

printf '  [T3] %-38s ' "baseline succeeds"
if "./$HARNESS" --emit >/dev/null 2>&1; then echo "PASS"; else echo "FAIL"; fail=1; fi

printf '  [T3] %-38s ' "aborts when OS source fails"
env "$PRELOAD_VAR=$ROOT/$LIB" "./$HARNESS" --emit >/dev/null 2>&1
rc=$?
if [ "$rc" -eq 134 ]; then
  echo "PASS   SIGABRT from RandFailure()"
else
  echo "FAIL   exit=$rc, expected 134 — a fallback path is reachable"
  fail=1
fi

printf '  [T3] %-38s ' "build fails with no OS source"
cat > "$ROOT/build/_guard.cpp" <<'EOF'
#undef __APPLE__
#undef __linux__
#undef __ANDROID__
#include <bitcoin-build-config.h>
EOF
# The compiler is expected to fail here, so capture its output rather than
# piping: `set -o pipefail` would otherwise report the intended failure as a
# test failure.
guard_out=$(c++ -std=c++20 -Ishim -Icore -Isrc -fsyntax-only "$ROOT/build/_guard.cpp" 2>&1 || true)
if printf '%s' "$guard_out" | grep -q 'No OS entropy source selected'; then
  echo "PASS   #error fires; /dev/urandom branch unreachable"
else
  echo "FAIL   build config would fall through to Core's #else"
  fail=1
fi
rm -f "$ROOT/build/_guard.cpp"

printf '  [T3] %-38s ' "only the strong generator is exported"
if nm -gU build/libcore_entropy.dylib 2>/dev/null | grep -q '_core_entropy_get_bytes'; then
  echo "FAIL   Core's FAST path (GetRandBytes) is reachable from the ABI"
  fail=1
else
  echo "PASS   GetRandBytes not bound; GetStrongRandBytes only"
fi

printf '  [T3] %-38s ' "no /dev/urandom string in binary"
if strings build/libcore_entropy.* 2>/dev/null | grep -q '/dev/urandom'; then
  echo "WARN   GetDevURandom survived dead-stripping (unreachable, but present)"
else
  echo "PASS   GetDevURandom stripped from the shared library"
fi

exit $fail

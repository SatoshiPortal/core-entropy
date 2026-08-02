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

printf '  [T3] %-38s ' "no /dev/urandom string in binary"
if strings build/libentropy_lab.* 2>/dev/null | grep -q '/dev/urandom'; then
  echo "WARN   GetDevURandom survived dead-stripping (unreachable, but present)"
else
  echo "PASS   GetDevURandom stripped from the shared library"
fi

exit $fail

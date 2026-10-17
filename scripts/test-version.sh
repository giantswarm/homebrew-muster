#!/usr/bin/env bash
# Tests newer_than from scripts/version.sh. Needs nothing but bash.
set -euo pipefail

# shellcheck source=scripts/version.sh
source "$(dirname "${BASH_SOURCE[0]}")/version.sh"

failed=0
# check <true|false> <a> <b>: newer_than a b has the expected result.
check() {
  local want=$1 got=false
  newer_than "$2" "$3" && got=true
  if [[ "$got" != "$want" ]]; then
    echo "FAIL: newer_than $2 $3 is $got, want $want" >&2
    failed=1
  fi
}

check true 5.43.7 5.43.7-rc.1
check false 5.43.7-rc.1 5.43.7
check false 5.43.7 5.43.7
check true 5.43.8-rc.1 5.43.7
check false 5.43.7 5.43.8-rc.1
check true 5.43.7-rc.2 5.43.7-rc.1
check true 5.43.7-rc.10 5.43.7-rc.9
check false 5.43.7-rc.1 5.43.7-rc.2
check true 5.44.0 5.43.7
check true 5.43.10 5.43.9
check false 5.43.9 5.43.10

(( failed == 0 )) && echo "newer_than: all cases pass"
exit "$failed"

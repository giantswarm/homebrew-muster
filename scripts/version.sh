#!/usr/bin/env bash
# Version comparison shared by scripts/update-formula.sh and its test.

# newer_than <a> <b>: version a has higher semver precedence than version b.
# A prerelease sorts before its release (5.43.7-rc.1 < 5.43.7); two versions
# of one release compare their prerelease parts.
newer_than() {
  local a=$1 b=$2 core_a core_b pre_a pre_b
  [[ "$a" != "$b" ]] || return 1
  core_a=${a%%-*}
  core_b=${b%%-*}
  if [[ "$core_a" != "$core_b" ]]; then
    [[ "$(printf '%s\n%s\n' "$core_a" "$core_b" | sort -V | tail -n1)" == "$core_a" ]]
    return
  fi
  pre_a=${a#"$core_a"}
  pre_b=${b#"$core_b"}
  [[ -z "$pre_a" ]] && return 0
  [[ -z "$pre_b" ]] && return 1
  [[ "$(printf '%s\n%s\n' "$pre_a" "$pre_b" | sort -V | tail -n1)" == "$pre_a" ]]
}

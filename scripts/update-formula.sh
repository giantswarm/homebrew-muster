#!/usr/bin/env bash
# Regenerates Formula/muster.rb from a giantswarm/muster GitHub release.
#
#   scripts/update-formula.sh                newest release with published binaries
#   scripts/update-formula.sh v5.22.0        that release, if newer than the formula
#   scripts/update-formula.sh --pin v5.21.0  that release, even if the formula is newer
#
# A release counts once every binary the formula installs is attached together
# with its Sigstore bundle: the GitHub Release is created a few minutes before
# the CircleCI pipeline uploads the binaries, and a release whose pipeline
# never ran has none. Each binary is verified against its bundle before its
# sha256 goes into the formula: cosign, keyless, issued to a CircleCI build of
# giantswarm/muster -- the check `muster self-update` makes.
#
# Exits 0 without touching the formula when there is nothing to do. Under
# GitHub Actions ($GITHUB_OUTPUT set) it records `version=<x.y.z>` and
# `changed=true|false` for the steps that follow.
#
# Needs gh (authenticated, or GH_TOKEN), curl, jq, cosign, openssl, sha256sum.
set -euo pipefail

REPO="giantswarm/muster"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FORMULA="$ROOT/Formula/muster.rb"
ASSETS=(muster-darwin-amd64 muster-darwin-arm64 muster-linux-amd64 muster-linux-arm64)

# The identity a bundle has to carry, as muster's own updater pins it
# (github.com/giantswarm/selfupdate-cosign): CircleCI's OIDC issuer, a CircleCI
# pipeline definition as the certificate's subject, and this repository as the
# source repository Fulcio recorded in the certificate.
OIDC_ISSUER="https://oidc.circleci.com"
IDENTITY_REGEXP='^https://circleci\.com/api/v2/projects/[a-f0-9-]+/pipeline-definitions/[a-f0-9-]+$'
SOURCE_REPOSITORY="github.com/$REPO"
SOURCE_REPOSITORY_OID="1.3.6.1.4.1.57264.1.12" # Fulcio "Source Repository URI"

log() { printf '%s\n' "$*" >&2; }
die() { log "error: $*"; exit 1; }

# output <key> <value>: hand a value to the workflow steps that follow.
output() {
  if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    printf '%s=%s\n' "$1" "$2" >>"$GITHUB_OUTPUT"
  fi
}

# newer_than <a> <b>: version a sorts after version b.
newer_than() {
  [[ "$1" != "$2" && "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -n1)" == "$1" ]]
}

# certificate <bundle>: the signing certificate of a Sigstore bundle, as PEM.
certificate() {
  echo "-----BEGIN CERTIFICATE-----"
  jq -r '.verificationMaterial.certificate.rawBytes
         // .verificationMaterial.x509CertificateChain.certificates[0].rawBytes' "$1" | fold -w 64
  echo "-----END CERTIFICATE-----"
}

# source_repository <bundle>: the source repository recorded in the bundle's
# signing certificate. cosign has no flag for this extension (its
# --certificate-github-* flags read the GitHub Actions ones), so the
# certificate is parsed here: the value is the UTF8STRING inside the OCTET
# STRING that follows the extension's OID.
source_repository() {
  local pem offset
  pem=$(certificate "$1")
  offset=$(openssl asn1parse -in <(printf '%s\n' "$pem") \
    | awk -v oid=":$SOURCE_REPOSITORY_OID\$" '$0 ~ oid { getline; sub(/:.*/, ""); gsub(/ /, ""); print; exit }')
  [[ -n "$offset" ]] || return 0
  openssl asn1parse -in <(printf '%s\n' "$pem") -strparse "$offset" | sed -n 's/.*UTF8STRING *://p'
}

# verify <file> <bundle>: the bundle signs the file, and its certificate was
# issued to a CircleCI pipeline by CircleCI's OIDC issuer for a build of $REPO.
verify() {
  local file=$1 bundle=$2 out source
  if ! out=$(cosign verify-blob --bundle "$bundle" \
      --certificate-oidc-issuer "$OIDC_ISSUER" \
      --certificate-identity-regexp "$IDENTITY_REGEXP" "$file" 2>&1); then
    log "$out"
    die "$(basename "$file") does not verify against $(basename "$bundle")"
  fi
  source=$(source_repository "$bundle")
  [[ "$source" == "$SOURCE_REPOSITORY" ]] \
    || die "$(basename "$file") was signed by a build of '${source:-?}', not of $SOURCE_REPOSITORY"
}

for tool in gh curl jq cosign openssl sha256sum; do
  command -v "$tool" >/dev/null || die "$tool is required"
done

pin=0
if [[ "${1:-}" == "--pin" ]]; then
  pin=1
  shift
fi
requested="${1:-}"
(( pin == 0 )) || [[ -n "$requested" ]] || die "--pin needs a release tag"

assets_json=$(printf '%s\n' "${ASSETS[@]}" | jq -R . | jq -sc .)
# jq: does the release carry every binary and every bundle?
# shellcheck disable=SC2016 # $names and $assets are jq variables
complete='[.assets[].name] as $names | all($assets[]; IN($names[]) and ((. + ".bundle") | IN($names[])))'

if [[ -n "$requested" ]]; then
  release=$(gh api "repos/$REPO/releases/tags/$requested") || die "$REPO has no release $requested"
  jq -e --argjson assets "$assets_json" "$complete" <<<"$release" >/dev/null \
    || die "release $requested does not have all binaries and bundles (yet): $(jq -r '[.assets[].name] | join(", ")' <<<"$release")"
else
  release=$(gh api "repos/$REPO/releases?per_page=30" \
    | jq -c --argjson assets "$assets_json" "[.[] | select((.draft or .prerelease) | not) | select($complete)] | first")
  [[ "$release" != "null" ]] || die "none of the 30 newest releases of $REPO has all binaries and bundles"
fi

tag=$(jq -r .tag_name <<<"$release")
version="${tag#v}"
# Homebrew scans the version from the download URL; so does this script.
current=$(sed -n 's#.*/releases/download/v\([^/]*\)/.*#\1#p' "$FORMULA" | head -n1)

if [[ "$version" == "$current" ]]; then
  log "Formula already at $version, nothing to do"
  output version "$current"
  output changed false
  exit 0
fi
if (( pin == 0 )) && ! newer_than "$version" "$current"; then
  log "Formula is at $current, $version is not newer, nothing to do"
  output version "$current"
  output changed false
  exit 0
fi

log "Updating formula: $current -> $version"
tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT
download="https://github.com/$REPO/releases/download/$tag"

declare -A sha
for asset in "${ASSETS[@]}"; do
  curl -sSfL --retry 3 -o "$tmpdir/$asset" "$download/$asset"
  curl -sSfL --retry 3 -o "$tmpdir/$asset.bundle" "$download/$asset.bundle"
  verify "$tmpdir/$asset" "$tmpdir/$asset.bundle"
  sha[$asset]=$(sha256sum "$tmpdir/$asset" | cut -d' ' -f1)
  log "$asset: signature verified, sha256 ${sha[$asset]}"
done

cat >"$FORMULA" <<FORMULA_EOF
# typed: false
# frozen_string_literal: true

# Generated by scripts/update-formula.sh from the giantswarm/muster release
# $tag. DO NOT EDIT: run the script, or wait for the "Update formula" workflow.
class Muster < Formula
  desc "One MCP endpoint for every MCP server your platform runs"
  homepage "https://github.com/giantswarm/muster"
  license "Apache-2.0"

  on_macos do
    on_intel do
      url "$download/muster-darwin-amd64"
      sha256 "${sha[muster-darwin-amd64]}"
    end
    on_arm do
      url "$download/muster-darwin-arm64"
      sha256 "${sha[muster-darwin-arm64]}"
    end
  end

  on_linux do
    on_intel do
      url "$download/muster-linux-amd64"
      sha256 "${sha[muster-linux-amd64]}"
    end
    on_arm do
      url "$download/muster-linux-arm64"
      sha256 "${sha[muster-linux-arm64]}"
    end
  end

  def install
    bin.install Dir["muster-*"].first => "muster"
    # A release asset carries no file mode, and Homebrew's cleaner sets it
    # only after install; the completions below need to run the binary.
    chmod 0755, bin/"muster"
    generate_completions_from_executable(bin/"muster", "completion")
  end

  test do
    assert_match "muster version", shell_output("#{bin}/muster version")
  end
end
FORMULA_EOF

output version "$version"
output changed true
log "Formula updated to $version"

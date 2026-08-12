#!/usr/bin/env bash
#
# Export the Sigstore bundle from actions/attest-build-provenance as an in-toto
# JSONL release asset.
#
# Usage: scripts/export-provenance.sh <bundle-path>
#        writes <subject-name>.intoto.jsonl, one DSSE envelope per subject.
#
# Why ship it as a release asset: the cosign signature proves someone holding a
# key signed the tarball; the provenance proves *which repository, workflow and
# commit built it*, which is what catches a substituted or tampered artifact.
# GitHub keeps the attestation in its own API, so shipping it in the release
# lets anyone verify offline, from a mirror, or years later.
#
# What it does: a Sigstore bundle carries the attestation under "dsseEnvelope"
# — a base64 in-toto Statement plus its signatures. This unwraps that envelope
# and writes it verbatim as one JSON object per line, the format SLSA tooling
# expects. Nothing is re-signed: payload and signatures are copied byte for
# byte, so the export verifies against the same Fulcio certificate as the
# bundle. The asset is named after the Statement's own subject, so provenance
# and artifact cannot drift apart. Doing the unwrap here rather than calling
# the SLSA reusable workflow also keeps every `uses:` pinned to a SHA — that
# workflow refuses to run when referenced by digest.

set -euo pipefail

BUNDLE="${1:?usage: export-provenance.sh <bundle-path>}"

if [ ! -s "$BUNDLE" ]; then
  echo "::error::attestation bundle '$BUNDLE' is missing or empty" >&2
  exit 1
fi

written=0

# One bundle per line for a multi-subject call, one pretty-printed object for a
# single subject; `jq -c .` normalizes both to one object per line.
while IFS= read -r bundle_line; do
  [ -n "$bundle_line" ] || continue

  envelope=$(printf '%s' "$bundle_line" | jq -c 'if has("dsseEnvelope") then .dsseEnvelope else . end')

  payload_type=$(printf '%s' "$envelope" | jq -r '.payloadType // ""')
  if [ "$payload_type" != "application/vnd.in-toto+json" ]; then
    echo "::error::unexpected DSSE payloadType '$payload_type' (want application/vnd.in-toto+json)" >&2
    exit 1
  fi

  subject=$(printf '%s' "$envelope" | jq -r '.payload' | base64 -d | jq -r '.subject[0].name // ""')
  # The subject is attacker-controllable input in the general case: keep it a
  # bare filename so it can only ever name a file in the current directory.
  case "$subject" in
    "" | */* | .*)
      echo "::error::refusing unusable subject name '$subject'" >&2
      exit 1
      ;;
  esac

  out="${subject}.intoto.jsonl"
  printf '%s\n' "$envelope" >"$out"
  echo "wrote $out ($(wc -c <"$out") bytes)"
  written=$((written + 1))
done < <(jq -c . "$BUNDLE")

if [ "$written" -eq 0 ]; then
  echo "::error::no attestations found in '$BUNDLE'" >&2
  exit 1
fi

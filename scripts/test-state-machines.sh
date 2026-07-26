#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

MIX_ENV=test mix compile --warnings-as-errors

perl -e 'alarm shift; exec @ARGV' 60 \
  env MIX_ENV=test mix test --no-compile --only state_machine

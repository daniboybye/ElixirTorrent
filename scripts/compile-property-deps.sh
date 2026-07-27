#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

MIX_ENV=test mix deps.patch-test
ERL_COMPILER_OPTIONS=warnings_as_errors MIX_ENV=test mix deps.compile proper --force
MIX_ENV=test mix deps.compile propcheck --force --warnings-as-errors

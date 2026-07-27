#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

bash scripts/compile-property-deps.sh
MIX_ENV=test mix compile --warnings-as-errors

run_group() {
  local group="$1"
  local repeats="$2"
  local seed="$3"

  printf 'race group: %s repeats=%s seed=%s\n' "$group" "$repeats" "$seed"

  perl -e 'alarm shift; exec @ARGV' 60 \
    env MIX_ENV=test ERL_FLAGS="+S 2:2" \
    mix test --no-compile \
    --only "race_group:${group}" \
    --repeat-until-failure "$repeats" \
    --seed "$seed"
}

run_group uploader 100 650707
run_group dial 100 411530
run_group endpoints 100 42
run_group pipeline 50 793938
run_group network 50 0
run_group protocol 50 999

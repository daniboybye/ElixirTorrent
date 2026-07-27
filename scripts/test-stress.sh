#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

bash scripts/compile-property-deps.sh
MIX_ENV=test mix compile --warnings-as-errors

run_test() {
  perl -e 'alarm shift; exec @ARGV' 60 "$@"
}

run_cell() {
  local schedulers="$1"
  local max_cases="$2"
  local seed="${3:-}"
  local -a command=(env MIX_ENV=test)

  if [[ "$schedulers" != "default" ]]; then
    command+=("ERL_FLAGS=+S ${schedulers}:${schedulers}")
  fi

  command+=(mix test --no-compile)

  if [[ "$max_cases" != "default" ]]; then
    command+=(--max-cases "$max_cases")
  fi

  if [[ -n "$seed" ]]; then
    command+=(--seed "$seed")
  fi

  printf 'stress cell: schedulers=%s max_cases=%s seed=%s\n' \
    "$schedulers" "$max_cases" "${seed:-random}"
  run_test "${command[@]}"
}

online="$(elixir -e 'IO.puts(System.schedulers_online())')"
half="$((online / 2))"

run_cell default default 633772
run_cell 2 1 411530
run_cell 2 32 650707
run_cell "$half" 1 453607
run_cell "$half" 32 747115
run_cell default default

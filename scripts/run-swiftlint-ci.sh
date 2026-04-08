#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
config_path="$repo_root/.swiftlint.yml"

if ! command -v swiftlint >/dev/null 2>&1; then
  echo "swiftlint is required but was not found in PATH" >&2
  exit 127
fi

reporter="xcode"
if [[ "${GITHUB_ACTIONS:-}" == "true" ]]; then
  reporter="github-actions-logging"
fi

lint_file() {
  local file="$1"
  swiftlint lint \
    --config "$config_path" \
    --reporter "$reporter" \
    "$file"
}

lint_all() {
  (
    cd "$repo_root"
    swiftlint lint --config "$config_path" --reporter "$reporter"
  )
}

lint_changed() {
  local base="$1"
  local head="$2"
  local files=()

  while IFS= read -r -d '' file; do
    [[ -f "$repo_root/$file" ]] || continue
    files+=("$file")
  done < <(
    cd "$repo_root"
    git diff --name-only -z "$base" "$head" -- '*.swift'
  )

  if [[ ${#files[@]} -eq 0 ]]; then
    echo "No changed Swift files to lint."
    return 0
  fi

  local status=0
  for file in "${files[@]}"; do
    echo "Linting $file"
    if ! lint_file "$repo_root/$file"; then
      status=1
    fi
  done

  return "$status"
}

case "${1:-}" in
  all)
    lint_all
    ;;
  changed)
    if [[ $# -ne 3 ]]; then
      echo "Usage: $0 changed <base-sha> <head-sha>" >&2
      exit 64
    fi
    lint_changed "$2" "$3"
    ;;
  *)
    echo "Usage: $0 {all|changed <base-sha> <head-sha>}" >&2
    exit 64
    ;;
esac

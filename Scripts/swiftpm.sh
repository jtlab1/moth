#!/bin/bash
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

subcommand="${1:-build}"
shift || true

exec swift "$subcommand" "$@"

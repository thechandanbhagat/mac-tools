#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Development runs default to debug; pass --configuration release when desired.
if [[ $# -eq 0 ]]; then set -- --configuration debug; fi
"$ROOT_DIR/scripts/build-app.sh" "$@"

# build-app.sh handles help without producing a bundle.
for argument in "$@"; do
    if [[ "$argument" == "--help" || "$argument" == "-h" ]]; then exit 0; fi
done

open "$ROOT_DIR/build/Mac Tools.app"

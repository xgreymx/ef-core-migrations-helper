#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
TOOL_PROJECT="$SCRIPT_DIR/src/EfCoreMigrationsHelper.Tool/EfCoreMigrationsHelper.Tool.csproj"

if [[ -f "$TOOL_PROJECT" ]]; then
  if ! command -v dotnet >/dev/null 2>&1; then
    echo "dotnet was not found on PATH. Install the .NET SDK to run the local tool project." >&2
    exit 1
  fi

  exec dotnet run --project "$TOOL_PROJECT" -- "$@"
fi

if command -v efm >/dev/null 2>&1; then
  exec efm "$@"
fi

echo "Could not find the local tool project or an installed 'efm' command. Build the repository or install the dotnet tool first." >&2
exit 1

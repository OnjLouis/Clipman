#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REPO_ROOT="$(cd "$ROOT/.." && pwd)"
ASSEMBLY_INFO="$REPO_ROOT/src/AssemblyInfo.cs"

if [[ ! -f "$ASSEMBLY_INFO" ]]; then
  echo "Could not find Windows AssemblyInfo.cs at $ASSEMBLY_INFO" >&2
  exit 1
fi

VERSION="$(sed -nE 's/.*AssemblyInformationalVersion\("([^"]+)"\).*/\1/p' "$ASSEMBLY_INFO" | head -n 1)"
if [[ -z "$VERSION" ]]; then
  echo "Could not read AssemblyInformationalVersion from $ASSEMBLY_INFO" >&2
  exit 1
fi

BUILD="$(sed -nE 's/.*AssemblyFileVersion\("([^"]+)"\).*/\1/p' "$ASSEMBLY_INFO" | head -n 1)"
if [[ -z "$BUILD" ]]; then
  BUILD="${VERSION}.0"
fi

case "${1:-version}" in
  version)
    echo "$VERSION"
    ;;
  build)
    echo "$BUILD"
    ;;
  *)
    echo "Usage: $0 [version|build]" >&2
    exit 2
    ;;
esac

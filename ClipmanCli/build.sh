#!/usr/bin/env sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
if [ "$(uname -s)" = "Darwin" ]; then
  default_output="$HOME/Projects/Codex/Temp/clipman/cli-build"
else
  default_output="${TMPDIR:-/tmp}/clipman-cli-build"
fi
output=${CLIPMAN_CLI_BUILD_DIR:-$default_output}
version=$(tr -d '\r\n' < "$root/VERSION")
staging="$output/staging"
final="$output/ClipmanCli-$version"
license="$root/../LICENSE.txt"

case "$output" in
  ''|'/') echo "Output directory cannot be empty or the filesystem root." >&2; exit 1 ;;
  "$root"|"$root"/*) echo "Output directory must be outside the Clipman CLI source tree." >&2; exit 1 ;;
esac

for required in "$root/Manual.html" "$root/clipman-cli.1" "$license"; do
  if [ ! -f "$required" ]; then
    printf 'Required package file is missing: %s\n' "$required" >&2
    exit 1
  fi
done

rm -rf "$staging"
mkdir -p "$staging"

# Every binary is named clipman-cli and identified by its directory, so
# installing one is a move rather than a rename.
artifacts=''
build() {
  goos=$1
  goarch=$2
  goarm=$3
  directory=$4
  binary=$5
  mkdir -p "$staging/$directory"
  if [ -n "$goarm" ]; then
    CGO_ENABLED=0 GOOS="$goos" GOARCH="$goarch" GOARM="$goarm" \
      go build -trimpath -ldflags "-s -w -X main.version=$version" -o "$staging/$directory/$binary" ./cmd/clipman-cli
  else
    CGO_ENABLED=0 GOOS="$goos" GOARCH="$goarch" \
      go build -trimpath -ldflags "-s -w -X main.version=$version" -o "$staging/$directory/$binary" ./cmd/clipman-cli
  fi
  artifacts="$artifacts $directory/$binary"
}

cd "$root"
go test ./...
go vet ./...
build windows amd64 '' windows-amd64 clipman-cli.exe
build windows arm64 '' windows-arm64 clipman-cli.exe
build linux amd64 '' linux-amd64 clipman-cli
build linux arm 7 linux-armv7 clipman-cli
build linux arm64 '' linux-arm64 clipman-cli
build darwin amd64 '' macos-amd64 clipman-cli
build darwin arm64 '' macos-arm64 clipman-cli

# Paths stay relative so that `sha256sum -c SHA256SUMS` verifies the whole
# package from its root.
(
  cd "$staging"
  # sed normalizes the binary-mode "*" marker some sha256sum builds emit, so
  # this file is byte-identical to the one Build.ps1 writes.
  # shellcheck disable=SC2086
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum $artifacts
  else
    shasum -a 256 $artifacts
  fi | sed 's/^\([0-9a-f]\{64\}\) \*/\1  /' | LC_ALL=C sort > SHA256SUMS
)
mkdir -p "$staging/manual"
cp "$root/Manual.html" "$staging/manual/Manual.html"
cp "$root/clipman-cli.1" "$staging/manual/clipman-cli.1"
cp "$license" "$staging/LICENSE.txt"
rm -rf "$final"
mv "$staging" "$final"
printf 'Built %s\n' "$final"

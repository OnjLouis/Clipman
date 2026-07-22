#!/usr/bin/env sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
output=${CLIPMAN_CLI_BUILD_DIR:-/tmp/clipman-cli-build}
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

build() {
  goos=$1
  goarch=$2
  goarm=$3
  artifact=$4
  if [ -n "$goarm" ]; then
    CGO_ENABLED=0 GOOS="$goos" GOARCH="$goarch" GOARM="$goarm" \
      go build -trimpath -ldflags "-s -w -X main.version=$version" -o "$staging/$artifact" ./cmd/clipman-cli
  else
    CGO_ENABLED=0 GOOS="$goos" GOARCH="$goarch" \
      go build -trimpath -ldflags "-s -w -X main.version=$version" -o "$staging/$artifact" ./cmd/clipman-cli
  fi
}

cd "$root"
build windows amd64 '' clipman-cli-windows-amd64.exe
build linux amd64 '' clipman-cli-linux-amd64
build linux arm 7 clipman-cli-linux-armv7
build linux arm64 '' clipman-cli-linux-arm64
build darwin amd64 '' clipman-cli-macos-amd64
build darwin arm64 '' clipman-cli-macos-arm64

(
  cd "$staging"
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum clipman-cli-* | LC_ALL=C sort > SHA256SUMS
  else
    shasum -a 256 clipman-cli-* | LC_ALL=C sort > SHA256SUMS
  fi
)
cp "$root/Manual.html" "$staging/Manual.html"
cp "$root/clipman-cli.1" "$staging/clipman-cli.1"
cp "$license" "$staging/LICENSE.txt"
rm -rf "$final"
mv "$staging" "$final"
printf 'Built %s\n' "$final"

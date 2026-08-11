#!/bin/sh
set -eu

project_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
dist_dir="$project_root/dist"

mkdir -p "$dist_dir"

build() {
  architecture=$1
  output="$dist_dir/rimgd-linux-$architecture"
  printf 'Building %s\n' "$(basename "$output")"
  (
    cd "$project_root/server"
    CGO_ENABLED=0 GOOS=linux GOARCH="$architecture" \
      go build -trimpath -ldflags='-s -w' -o "$output" ./cmd/rimgd
  )
}

build amd64
build arm64

(
  cd "$dist_dir"
  shasum -a 256 rimgd-linux-amd64 rimgd-linux-arm64 > checksums.txt
)

printf 'Wrote %s\n' "$dist_dir/checksums.txt"

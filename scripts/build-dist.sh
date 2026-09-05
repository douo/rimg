#!/bin/sh
set -eu

project_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
dist_dir="$project_root/dist"

mkdir -p "$dist_dir"

build() {
  command_name=$1
  architecture=$2
  output="$dist_dir/$command_name-linux-$architecture"
  printf 'Building %s\n' "$(basename "$output")"
  (
    cd "$project_root/server"
    CGO_ENABLED=0 GOOS=linux GOARCH="$architecture" \
      go build -trimpath -ldflags='-s -w' -o "$output" "./cmd/$command_name"
  )
}

build rimgd amd64
build rimgd arm64
build rvidd amd64
build rvidd arm64

(
  cd "$dist_dir"
  shasum -a 256 \
    rimgd-linux-amd64 rimgd-linux-arm64 \
    rvidd-linux-amd64 rvidd-linux-arm64 > checksums.txt
)

printf 'Wrote %s\n' "$dist_dir/checksums.txt"

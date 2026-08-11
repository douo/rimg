#!/bin/sh
set -eu

project_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
work_dir=$(mktemp -d "${TMPDIR:-/tmp}/rimg-phase0.XXXXXX")
thumb_file="$work_dir/test-thumb.jpg"

cleanup() {
  rm -rf "$work_dir"
}
trap cleanup EXIT HUP INT TERM

magick -size 96x96 xc:'#2f6feb' -quality 82 "$thumb_file"

RIMG_PHASE0_THUMB="$thumb_file" \
  /Applications/Emacs.app/Contents/MacOS/Emacs \
  -Q --batch \
  -L "$project_root/emacs" \
  -L "$project_root/emacs/test" \
  -l rimg-phase0-test.el \
  -f ert-run-tests-batch-and-exit

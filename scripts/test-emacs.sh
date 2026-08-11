#!/bin/sh
set -eu

project_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)

if [ -f "$project_root/emacs/test/rimg-test.el" ]; then
  /Applications/Emacs.app/Contents/MacOS/Emacs \
    -Q --batch \
    -L "$project_root/emacs" \
    -L "$project_root/emacs/test" \
    -l rimg-test.el \
    -f ert-run-tests-batch-and-exit
fi

"$project_root/scripts/test-phase0.sh"

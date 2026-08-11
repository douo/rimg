# Phase 0: Image-Dired Integration Spike

Status: verified on 2026-08-11

## Question

Can current Emacs insert a local thumbnail while retaining a TRAMP remote
original and its associated Dired buffer, without causing material remote I/O
for tag or comment lookup?

## Planned Fixture

- Local thumbnail: generated under a temporary local directory.
- Remote original:
  `/ssh:example-host:/srv/images/sample.jpg`
- Emacs: GNU Emacs 32.0.50.

## Required Evidence

- `image-dired-insert-thumbnail` completes.
- Thumbnail text properties retain the remote original and Dired buffer.
- The stock RET/original lookup path resolves the remote original.
- Calls made by tag/comment lookup are observed and timed.
- The decision to use the stock inserter or `rimg--insert-thumbnail` is recorded.

## Result

The stock `image-dired-insert-thumbnail` seam is usable for the MVP.

The repeatable harness in `emacs/test/rimg-phase0-test.el` uses:

- A generated local JPEG thumbnail.
- A real remote Dired buffer on `example-host`.
- A remote original stored in the thumbnail's `original-file-name` property.
- Advice around `tramp-file-name-handler` only during thumbnail insertion.

Verified behavior:

- The local thumbnail is recognized as an Image-Dired image.
- `original-file-name` retains the exact TRAMP path.
- `associated-dired-buffer` retains the live remote Dired buffer.
- The stock display command resolves the remote original; the harness replaces
  the final display function so the spike does not download the original.
- Mark and unmark update the associated remote Dired buffer correctly.
- Thumbnail insertion, including tag and comment lookup, invokes no TRAMP file
  handler operations.

Current Emacs stores an empty tag set as a list containing one empty string.
This is existing Image-Dired behavior and does not affect the integration.

## Decision

Use `image-dired-insert-thumbnail` for MVP thumbnail insertion. `rimg.el` will:

1. Supply a local cached thumbnail path.
2. Supply the TRAMP original path and associated Dired buffer.
3. Override the thumbnail RET binding with optimized preview behavior.
4. Keep an explicit command for opening the actual TRAMP original.

No architecture deviation is required.

## Reproduction

```sh
./scripts/test-phase0.sh
```

Observed result:

```text
1 test passed
tramp_operations=nil
```

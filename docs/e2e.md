# End-to-End Verification

Image verification date: 2026-08-11 (Asia/Shanghai)

Video verification date: 2026-09-05 (Asia/Shanghai)

The measurements below were collected on a private Linux amd64 fixture host.
Host aliases, user names, and source paths are intentionally omitted. Public
reproduction uses an operator-provided TRAMP directory:

```text
RIMG_E2E_REMOTE=/ssh:example-host:/srv/images/
```

Tests that need one source image select the first supported image in that
directory. Set `RIMG_E2E_IMAGE` to a full TRAMP path to choose one explicitly.

The separate rvid transport contract test is also opt-in.  It bootstraps
`rvidd`, registers one regular file, and verifies that a one-byte request
returns `206 Partial Content`:

```text
RVID_E2E_REMOTE_FILE=/ssh:example-host:/srv/videos/sample.mp4
```

## Results

- Automatic bootstrap installed the versioned rimgd and reached READY.
- A remote Dired listing produced an ordered, paginated Image-Dired gallery.
- Thumbnail generation transferred proxy bytes, not original image bytes.
- Remote cache behavior passed MISS then HIT.
- Local revalidation reused the local body with zero additional body writes.
- A remote mtime-only change produced a new key and cache MISS.
- RET used a bounded local preview; explicit original opening retained TRAMP.
- Two simultaneous sessions used distinct ports and Unix sockets while sharing
  the persistent remote cache.
- Local listeners were bound to `127.0.0.1`; rimgd had no remote TCP listener.
- Forced SSH loss changed the session to DEAD and removed the remote socket.
- Full remote-enabled ERT result: 23 passed, 0 skipped, 0 unexpected.
- Final cleanup left no rimgd process and no socket in the rimg runtime path.

The video fixture verification additionally established that:

- rvidd bootstrap, authenticated registration, and capability revocation
  completed on a real Linux amd64 host.
- A byte-range request returned `206 Partial Content` without copying the full
  video through Emacs.
- The embedded WebKit player loaded a 10.125-second H.264/AAC MP4, reported
  `readyState=4` with no media error, and reached the end of playback.

## Measurements

Representative run for a JPEG fixture:

```text
original_bytes=100356
thumbnail_body_bytes=8953
cold_seconds=0.118631
remote_warm_seconds=0.032821
local_warm_seconds=0.029246
local_warm_body_writes=0
```

These measurements are behavioral evidence, not a benchmark guarantee. The
tests assert cache/body-transfer behavior and report timing without brittle
absolute latency thresholds.

# End-to-End Verification

Verification date: 2026-08-11 (Asia/Shanghai)

Fixture host and directory:

```text
example-host (Linux amd64)
/srv/images/
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

## Measurements

Representative run for `sample.jpg`:

```text
original_bytes=100356
thumbnail_body_bytes=8953
cold_seconds=0.098579
remote_warm_seconds=0.035073
local_warm_seconds=0.029016
local_warm_body_writes=0
```

These measurements are behavioral evidence, not a benchmark guarantee. The
tests assert cache/body-transfer behavior and report timing without brittle
absolute latency thresholds.

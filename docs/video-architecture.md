# Remote Video Architecture

## Scope

`rvid` is the remote-video feature shipped in the `rimg` umbrella project and
repository.  It is independently loadable from the `rimg` image feature, while
sharing the generic transport implementation in `rbridge.el`.

`rvid` plays a caller-supplied TRAMP file path without mounting the remote
filesystem and without relaying video bytes through an Emacs Lisp buffer.  It
shares `rbridge.el` with `rimg`, but uses a separate `rvidd` process so the
image service retains its no-raw-read security contract.

The MVP consists of:

- `rbridge.el`, shared remote parsing, binary bootstrap, SSH forwarding, and
  session lifecycle.
- `rvid.el`, capability registration, local player startup, and mpv IPC.
- `rvidd`, a per-session Go HTTP server on a private remote Unix socket.

## Caller Boundary

The core client accepts one explicit TRAMP file path.  It does not discover
videos, traverse directories, classify UI targets, or depend on a particular
selection frontend.  Dired, completion frameworks, and optional user actions
remain responsible for choosing that file before invoking `rvid-play`.

## Data Flow

```text
control plane
Emacs caller -> selected TRAMP path
Emacs -> POST /v1/media/open -> one-file capability

video data plane
remote os.File
  -> rvidd GET/HEAD with HTTP byte ranges
  -> mode-0600 remote Unix socket
  -> OpenSSH local forward
  -> 127.0.0.1 ephemeral port
  -> local mpv or WebKit
```

Only the small JSON registration request and playback controls are processed
by Emacs.  The player opens the loopback URL itself.  OpenSSH transfers the
response bytes directly between its forwarded socket and the remote service.

## Capability Model

Starting an rvid session generates a private registration secret and passes it
to `rvidd`.  `POST /v1/media/open` requires that secret.  Successful
registration returns a random 128-bit identifier whose URL grants read-only
access to exactly one canonical regular file.

The file path is not present in the URL or local player arguments.  A
capability has a sliding idle lifetime, the total number of open capabilities
is bounded, and Emacs revokes the current capability when playback stops.
Closing the SSH session terminates rvidd and invalidates every capability.

This design prevents a browser request that merely discovers the loopback port
from choosing an arbitrary remote path.  Processes running as the same local
user can inspect player arguments and therefore may discover the one-file
playback capability; the remote filesystem boundary is still the SSH user's
normal permissions.

## Seeking And File Consistency

The player can issue `HEAD` and `Range: bytes=...` requests.  Go's
`http.ServeContent` implements range and conditional-request semantics over an
open regular file.  A new file descriptor is opened for every request, so
concurrent player reads do not share a mutable seek offset.

Registration records the canonical path, size, and nanosecond modification
time.  Later requests reject a changed file with `409 MEDIA_CHANGED`; Emacs can
register it again to obtain a new capability.  ETags are derived from the same
metadata and support `If-Range` and other HTTP conditionals.

## Playback Backends

The automatic backend prefers local mpv with its JSON IPC Unix socket and
network cache enabled.  Pause and relative seek commands travel over that
local IPC socket.  If mpv is unavailable, rvid falls back to an xwidget that
opens an rvidd-generated HTML page containing a native `<video>` element.  A
restrictive Content Security Policy permits only the same-origin media URL and
inline layout CSS.  This keeps the player inside
an Emacs buffer, but available containers and codecs depend on WebKit.

## Deliberate Omissions

- No remote transcoding or adaptive bitrate selection.
- No persistent full-file or sparse-block cache.
- No directory listing, write, rename, or delete API.
- No automatic external subtitle discovery.
- No automatic playback-position recovery after a broken SSH tunnel.

These can be added independently without changing the byte-range transport.

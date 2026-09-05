# Architecture

## Project Boundary

`rimg` is both the repository name and the umbrella project name.  The
repository ships two user-facing Emacs features: `rimg` for remote images and
`rvid` for remote videos.  Keeping them together lets them share the generic
TRAMP/OpenSSH transport and bootstrap implementation in `rbridge.el` without
duplicating security-sensitive session code.

The shared repository is not a shared media protocol.  `rimg.el`/`rimgd` and
`rvid.el`/`rvidd` remain independently loadable features with separate remote
processes, endpoints, and security contracts.  This document describes the
image side; see [the video architecture](video-architecture.md) for the video
side.

## Scope

`rimg` adds a remote image data plane beneath Emacs TRAMP, Dired, and
Image-Dired. Dired remains the file manager, TRAMP remains the remote path and
bootstrap control plane, and OpenSSH remains the authentication and encrypted
transport layer.

The remote parsing, binary bootstrap, SSH forwarding, and session lifecycle
now live in `rbridge.el`, which is also used by the separate remote-video
client.  The image protocol and `rimgd` process remain independent from the
raw byte-range service described in
[the video architecture](video-architecture.md).

The system consists of:

- `rbridge.el`, the shared transport layer.
- `rimg.el`, an Emacs image client.
- `rimgd`, a per-session remote Go process.

## Data Flow

```text
remote original
  -> rimgd decode/resize
  -> persistent remote cache
  -> remote Unix socket
  -> OpenSSH local forward
  -> 127.0.0.1 ephemeral port
  -> persistent local Emacs cache
  -> Image-Dired
```

Opening an original remains an explicit TRAMP operation.

## Process And Network Model

- `rimgd` is installed as a versioned, static binary under the remote user's
  cache directory.
- Each Emacs session starts a temporary `rimgd serve` process with a unique,
  short Unix socket path.
- The SSH invocation enables stdin-EOF shutdown, so closing the session channel
  cancels rimgd even on sshd configurations that do not deliver SIGHUP.
- The Unix runtime directory is mode `0700`; the socket is mode `0600`.
- `rimgd` never listens on remote TCP.
- SSH binds an ephemeral local port explicitly on `127.0.0.1` and forwards it
  to the remote Unix socket.
- Session readiness is established only after `/v1/health` succeeds.

## Cache Model

The remote cache key is SHA-256 over:

```text
cache format version
+ canonical path
+ file size
+ mtime nanoseconds
+ transform specification
```

The implementation deliberately avoids hashing the full original. Cache files
are written to a per-process temporary file and atomically renamed.

The local Emacs cache is partitioned by a hash of remote identity and then by
the server-provided cache key. A local hit must avoid requesting the thumbnail
body from the remote server.

## Security Boundary

Authentication and encryption come from SSH. `rimgd` adds Unix socket
permissions, loopback-only local forwarding, bounded request bodies, bounded
path and batch sizes, and bounded output dimensions. It does not expose raw
file reads, shell execution, directory listing, deletion, or rename APIs.

## Verified Constraints

- Unix socket paths must remain short. A long macOS test path failed at bind
  time, confirming the session runtime path rule in the design.
- The Linux amd64 and arm64 outputs are statically linked with CGO disabled.
- A real Linux amd64 run exposed no remote TCP listener; health and thumbnail
  traffic used only the configured Unix socket.

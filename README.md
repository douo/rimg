# rimg

[简体中文](README.zh-CN.md)

`rimg` is the name of this repository and the umbrella project.  Despite its
historically image-oriented name, the project intentionally contains two
user-facing Emacs features:

- `rimg` browses remote images through `rimg.el` and `rimgd`.
- `rvid` plays remote videos through `rvid.el` and `rvidd`.

They live in one project because both solve the same remote-media problem over
TRAMP and SSH, and share remote-target parsing, binary deployment, SSH
forwarding, and session lifecycle code in `rbridge.el`.  They remain separate
Emacs features with separate remote processes and protocols: loading `rimg`
does not load `rvid`, and using `rvid` does not weaken `rimgd`'s restricted
image-serving interface.

The `rimg` image feature accelerates remote image browsing in Emacs without
replacing TRAMP, Dired, or Image-Dired. Emacs continues to manage remote files,
while a small Go process on the remote Linux host decodes images, generates
bounded thumbnails and previews, and caches the results close to the source
files.

The result is an Image-Dired gallery that transfers thumbnail-sized data over
SSH instead of repeatedly downloading full-resolution originals.

The `rvid` video feature plays remote videos through a local mpv process or
an embedded WebKit xwidget.  Its separate `rvidd` service exposes only
capability-scoped HTTP byte ranges, so seeking does not require downloading the
whole remote file.

## Features

- Works with single-hop TRAMP `/ssh:` and `/sshx:` paths.
- Keeps Dired as the file manager and preserves each remote original path.
- Automatically installs a versioned `rimgd` binary on the remote host.
- Uses an SSH tunnel to a permission-restricted remote Unix socket; `rimgd`
  never opens a remote TCP listener.
- Generates and caches JPEG, PNG, and WebP thumbnails on Linux amd64/arm64.
- Uses remote and local caches with metadata-aware revalidation.
- Opens bounded local previews with `RET`; opening the original is explicit.
- Handles large directories with 200-image pages and viewport-driven lazy
  loading. Only visible rows and a small prefetch window are requested.
- Keeps fixed gallery slots so parallel responses cannot reorder thumbnails,
  move the selection, or change the grid width.
- Plays any caller-supplied remote TRAMP video path without mounting the remote
  filesystem.
- Sends video bytes directly from the SSH forward to mpv or WebKit; Emacs only
  performs the small capability-registration request.
- Supports `HEAD`, HTTP byte ranges, seeking, file-change detection, expiring
  per-file capabilities, and explicit revocation.

## Requirements

Local machine:

- GNU Emacs 32 or newer.
- OpenSSH with local TCP to remote Unix-socket forwarding support.
- mpv for the preferred external video backend, or a graphical Emacs build with
  xwidget WebKit support for compatible browser media formats.
- Go 1.25 or newer when building the bundled Linux server artifacts.

Remote machine:

- Linux on amd64 or arm64.
- SSH access through a single-hop TRAMP `/ssh:` or `/sshx:` connection.
- Permission to create files under `~/.cache/rimg/` and a private runtime
  directory under `/run/user/$UID` or `/tmp`.

## Installation

Clone the single `rimg` repository and build the static Linux server artifacts
for both features, `rimgd` and `rvidd`:

```sh
git clone https://github.com/douo/rimg.git ~/.emacs.d/site-lisp/rimg
make -C ~/.emacs.d/site-lisp/rimg dist
```

Loading one feature does not load the other.  Add only the feature or features
you use to your Emacs configuration:

```elisp
(add-to-list 'load-path
             (expand-file-name "~/.emacs.d/site-lisp/rimg/emacs"))
(require 'rimg) ; Remote image browsing.
(require 'rvid) ; Remote video playback; omit if unused.
```

With `use-package`:

```elisp
(use-package rimg
  :load-path "~/.emacs.d/site-lisp/rimg/emacs"
  :commands (rimg-dired
             rimg-reconnect
             rimg-disconnect
             rimg-clear-local-cache
             rimg-prune-remote-cache))

(use-package rvid
  :load-path "~/.emacs.d/site-lisp/rimg/emacs"
  :commands (rvid-play
             rvid-play-in-emacs
             rvid-stop
             rvid-toggle-pause
             rvid-seek-forward
             rvid-seek-backward
             rvid-reconnect
             rvid-disconnect))
```

The Emacs clients look for the `rimgd-linux-*` and `rvidd-linux-*` artifacts
under the repository's `dist/` directory by default. Set
`rimg-server-binary-directory` or `rvid-server-binary-directory` if the
artifacts are stored elsewhere.

## Usage

1. Open a remote image directory in Dired, for example:

   ```text
   /ssh:example-host:/srv/images/
   ```

2. Run `M-x rimg-dired`.
3. Browse the gallery with the normal Image-Dired commands.

Additional gallery bindings:

| Key | Action |
| --- | --- |
| `RET` | Open a bounded, locally cached preview |
| `C-RET` | Explicitly open the remote original through TRAMP |
| `]` | Next gallery page |
| `[` | Previous gallery page |

Maintenance commands:

| Command | Purpose |
| --- | --- |
| `M-x rimg-reconnect` | Replace the current remote session |
| `M-x rimg-disconnect` | Stop the SSH session and remote `rimgd` |
| `M-x rimg-clear-local-cache` | Clear the local cache for the current remote |
| `M-x rimg-prune-remote-cache` | Apply age and size limits to the remote cache |

### Remote video playback

`rvid-play` accepts a complete TRAMP file name and does not depend on Dired.
Pass it a remote file target from Dired, file completion, Consult, Embark, or
any other source.  Its `auto` backend prefers local mpv and falls back to an
Emacs WebKit xwidget.  Run `M-x rvid-play-in-emacs` to force WebKit.

A user configuration can refine supported TRAMP video extensions from `file`
to an `rvid-remote-video` Embark target and bind `V` only in that type's action
map.  Directories, remote images, and local videos then do not expose the
action.  `rvid-play` also remains available through `M-x` after entering
Embark.  Embark's existing `embark-open-externally` still copies a TRAMP file
before opening it and is not the rvid streaming path.

Embark is not a project or package dependency: `rvid.el` neither loads nor
calls it.  Target refinement and action bindings belong in the user's personal
Emacs configuration.

Playback commands:

| Command | Purpose |
| --- | --- |
| `M-x rvid-stop` | Stop playback and revoke the current media capability |
| `M-x rvid-toggle-pause` | Toggle pause through mpv JSON IPC |
| `M-x rvid-seek-forward` | Seek forward through mpv JSON IPC |
| `M-x rvid-seek-backward` | Seek backward through mpv JSON IPC |
| `M-x rvid-reconnect` | Replace the current remote rvid session |
| `M-x rvid-disconnect` | Stop playback, SSH, and the remote rvidd process |

## How It Works

The two features reuse the same transport control plane but keep separate image
and video data planes:

```text
Control plane
Emacs -> Dired/TRAMP -> remote paths, listing, marks, file operations

Image data plane
remote original
  -> rimgd decode and resize
  -> persistent remote cache
  -> per-session Unix socket
  -> OpenSSH local forward
  -> 127.0.0.1 ephemeral port
  -> persistent local cache
  -> Image-Dired

Video data plane
remote video
  -> rvidd read-only byte range
  -> per-session Unix socket
  -> OpenSSH local forward
  -> 127.0.0.1 ephemeral port
  -> local mpv or WebKit
```

### 1. Bootstrap and session lifecycle

The Emacs client parses the TRAMP target, detects the remote Linux
architecture, and copies the matching versioned static binary to
`~/.cache/rimg/bin/<version>/rimgd` through TRAMP. It then starts one `rimgd`
process for the Emacs session and connects to it with an OpenSSH local forward.

The remote process listens only on a short Unix socket with mode `0600`. The
runtime directory is mode `0700`, and the local TCP endpoint binds only to
`127.0.0.1` on a randomly selected ephemeral port. A health check validates
the protocol version before the session becomes ready. Closing the SSH channel
closes `rimgd` through stdin EOF, with signal handling as a fallback.

### 2. Thumbnail and preview requests

Emacs sends the remote absolute path and a bounded transform specification to
the local forwarded endpoint. `rimgd` validates the request, decodes the source
image on the remote host, applies a contain resize, and returns JPEG or PNG
proxy bytes. The original image bytes do not travel to Emacs unless the user
explicitly opens the original.

### 3. Two-level cache

The remote cache key is a SHA-256 digest of the cache format version,
canonical path, file size, nanosecond modification time, and transform
specification. Changing the file or requested dimensions produces a new key
without hashing the full source image.

Emacs partitions its local cache by remote identity and stores bodies under
the server-provided key. On a local hit it revalidates the key; when unchanged,
the server returns no thumbnail body. Both caches use temporary files followed
by atomic rename.

### 4. Large directory behavior

The gallery materializes at most 200 fixed slots per page. It requests only
the visible rows plus `rimg-gallery-prefetch-rows` above and below the viewport.
Scrolling schedules cold slots near the new viewport, while each parallel
response fills its original slot immediately. This bounds work for directories
containing thousands of files and prevents late responses from replacing the
selected image or reshaping the grid.

## Security Model

- SSH provides authentication, encryption, and host verification.
- `rimgd` has no remote TCP listener and accepts traffic only through its Unix
  socket and the authenticated SSH tunnel.
- The local forwarded port is loopback-only.
- Request bodies, path lengths, batch sizes, dimensions, worker counts, and
  output transforms are bounded.
- `rimgd` exposes health, thumbnail, preview, and cache preparation endpoints;
  it does not expose shell execution, directory listing, rename, or deletion.
- Remote paths are sent to a process running as the same remote user. `rimg`
  does not bypass that user's filesystem permissions.
- `rvidd` is a separate process and never changes `rimgd`'s no-raw-read
  contract. Registering a remote path requires a per-session bearer secret.
  The resulting unpredictable URL grants read-only access to one file, expires
  after an idle period, and can be revoked explicitly.

See [the architecture document](docs/architecture.md) and
[image protocol v1](docs/protocol-v1.md), plus the
[video architecture](docs/video-architecture.md) and
[video protocol v1](docs/video-protocol-v1.md), for more detail.

## Configuration

Important customization variables include:

| Variable | Default | Meaning |
| --- | --- | --- |
| `rimg-thumbnail-size` | `256` | Maximum thumbnail width and height |
| `rimg-page-size` | `200` | Maximum slots materialized per page |
| `rimg-gallery-prefetch-rows` | `2` | Rows loaded above and below the viewport |
| `rimg-http-parallelism` | `6` | Maximum parallel HTTP requests |
| `rimg-preview-max-width` | `1920` | Maximum preview width |
| `rimg-preview-max-height` | `1920` | Maximum preview height |
| `rimg-local-cache-directory` | `~/.cache/rimg-emacs/` | Local cache root |
| `rimg-server-cache-directory` | `~/.cache/rimg/thumbs` | Remote cache root |
| `rvid-player-backend` | `auto` | Prefer `mpv`, otherwise use `xwidget`; either can be forced |
| `rvid-mpv-program` | `mpv` | Local mpv executable |
| `rvid-mpv-arguments` | network cache options | Additional mpv arguments |
| `rvid-token-idle-ttl` | `24h` | Idle lifetime of a media capability |
| `rvid-max-open-media` | `256` | Capability limit for one rvidd session |

## Development

Run the portable test suite:

```sh
make test
```

Build release artifacts:

```sh
make dist
```

The real-host Image-Dired contract test is opt-in:

```sh
RIMG_PHASE0_REMOTE_ORIGINAL=/ssh:example-host:/srv/images/sample.jpg \
  ./scripts/test-phase0.sh
```

Other remote end-to-end tests use `RIMG_E2E_REMOTE`; see
[docs/e2e.md](docs/e2e.md).

The opt-in rvid transport test uses a full remote media path:

```sh
RVID_E2E_REMOTE_FILE=/ssh:example-host:/srv/videos/sample.mp4 make test-emacs
```

## Current Limitations

- Only single-hop `/ssh:` and `/sshx:` TRAMP paths are supported.
- The remote server currently supports Linux amd64 and arm64.
- Source decode formats are JPEG, PNG, and WebP; output formats are JPEG and
  PNG.
- `rvid` currently serves original file bytes and does not transcode or adapt
  bitrate. WebKit playback supports fewer containers/codecs than mpv.
- External subtitle discovery and automatic reconnect-at-position are not yet
  implemented.
- `rimg` is an MVP and is not yet distributed through an Emacs package archive.

## License

MIT. See [LICENSE](LICENSE).

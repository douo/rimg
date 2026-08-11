# rimg

`rimg` is a remote image data plane for Emacs TRAMP, Dired, and
Image-Dired. It keeps file management in Emacs while moving image decode,
resize, and thumbnail caching to the remote host.

The project has two components:

- `emacs/rimg.el`: Emacs client, bootstrap, SSH tunnel, local cache, and
  Image-Dired integration.
- `server/cmd/rimgd`: a statically linked Go server that listens on a remote
  Unix domain socket.

The design is intentionally narrow: no Web UI, remote TCP listener, daemon
installer, database, Docker, or replacement file manager.

## Current Status

Implementation is active. See [STATUS.md](STATUS.md) for the live checkpoint
and [PLAN.md](PLAN.md) for milestone acceptance criteria.

## Development

Prerequisites:

- Go 1.26 or newer
- GNU Emacs 32 or newer for the current integration spike
- OpenSSH with local TCP to remote Unix-socket forwarding

Run the current checks with:

```sh
make test
```

Build Linux server binaries with:

```sh
make dist
```

Add the Emacs client to your configuration:

```elisp
(add-to-list 'load-path (expand-file-name "~/playground/rimg/emacs"))
(require 'rimg)
```

Open a remote `/ssh:` directory in Dired and invoke `M-x rimg-dired`. Gallery
pages contain at most 200 images; `]` and `[` change pages, RET opens a bounded
local preview, and `C-RET` explicitly opens the TRAMP original.

Maintenance commands are `M-x rimg-clear-local-cache`,
`M-x rimg-prune-remote-cache`, `M-x rimg-reconnect`, and
`M-x rimg-disconnect`.

## Architecture

The control plane remains TRAMP/OpenSSH. Thumbnail and preview payloads flow
through localhost HTTP over an SSH local forward to a per-session remote Unix
socket. See [docs/architecture.md](docs/architecture.md) and
[docs/protocol-v1.md](docs/protocol-v1.md).

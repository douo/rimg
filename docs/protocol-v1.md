# Protocol v1

`rimgd` serves HTTP/1.1 over a Unix domain socket. Emacs reaches that socket
through an OpenSSH local forward bound to `127.0.0.1` on an ephemeral port.

## Common Rules

- Protocol version: `1`
- JSON request content type: `application/json`
- Maximum request body, path length, output dimensions, and prepare batch size
  are enforced by the server.
- JSON errors use:

```json
{"error":{"code":"INVALID_REQUEST","message":"..."}}
```

## Health

`GET /v1/health`

```json
{
  "ok": true,
  "protocol": 1,
  "version": "0.1.0",
  "pid": 12345,
  "capabilities": {
    "decode": ["jpeg", "png", "webp"],
    "encode": ["jpeg", "png"],
    "prepare": false
  }
}
```

## Thumbnail

`POST /v1/thumb`

```json
{
  "path": "/data/001.png",
  "width": 256,
  "height": 256,
  "fit": "contain",
  "format": "jpeg",
  "quality": 82
}
```

Successful responses return image bytes plus:

```text
ETag: "<cache-key>"
X-Rimg-Key: <cache-key>
X-Rimg-Cache: HIT|MISS
```

When the client already has a local entry, it sends the quoted server key in
`If-None-Match`. If that key is still current, rimgd returns `200 OK` with an
empty body and `X-Rimg-Not-Modified: true`, plus `ETag`, `X-Rimg-Key`, and
`X-Rimg-Cache` headers. This explicit 200 response is used because Emacs URL
intercepts 304 to read its unrelated GET cache and clears 204 response buffers
before invoking the caller's callback.

## Preview

`POST /v1/preview` uses maximum dimensions rather than a thumbnail box. It
returns a bounded proxy image. It never returns arbitrary original bytes.

## Prepare

`POST /v1/prepare` accepts at most 1000 paths and a thumbnail specification.
It schedules cache population on a bounded worker pool and returns accepted,
cached, and queued counts. This endpoint is planned for Phase 4; until it is
implemented, health reports `"prepare": false`.

## Error Codes

- `IMAGE_NOT_FOUND`
- `PERMISSION_DENIED`
- `UNSUPPORTED_FORMAT`
- `DECODE_FAILED`
- `INVALID_REQUEST`
- `INVALID_DIMENSION`
- `CACHE_ERROR`
- `INTERNAL_ERROR`
- `PROTOCOL_MISMATCH`

Current HTTP mappings:

- `INVALID_REQUEST`, `INVALID_DIMENSION`: 400
- `PERMISSION_DENIED`: 403
- `IMAGE_NOT_FOUND`: 404
- `UNSUPPORTED_FORMAT`: 415
- `DECODE_FAILED`: 422
- `CACHE_ERROR`, `INTERNAL_ERROR`: 500

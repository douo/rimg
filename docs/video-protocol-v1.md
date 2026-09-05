# rvid Protocol v1

`rvidd` serves HTTP/1.1 over a Unix domain socket.  `rbridge.el` reaches the
socket through an OpenSSH local forward bound explicitly to `127.0.0.1`.

## Health

`GET /v1/health`

```json
{
  "ok": true,
  "protocol": 1,
  "version": "0.1.0",
  "pid": 12345,
  "capabilities": {
    "media_range": true
  }
}
```

Health is intentionally unauthenticated so the client can establish session
readiness.  It does not expose file information.

## Register Media

`POST /v1/media/open`

```text
Authorization: Bearer <session-secret>
Content-Type: application/json
```

```json
{"path":"/srv/videos/example.mkv"}
```

The path must be absolute, readable by the remote SSH user, and resolve to a
regular file.  On success the server returns `201 Created`:

```json
{
  "id": "4d3c2b1a...",
  "name": "example.mkv",
  "size": 4294967296,
  "mtime_ns": 1788537600000000000,
  "etag": "\"sha256-metadata-digest\"",
  "url_path": "/v1/media/4d3c2b1a.../example.mkv",
  "content_type": "video/x-matroska"
}
```

The session has a bounded capability registry.  Capabilities use a sliding
idle timeout; the default is 24 hours.

## Read Media

`GET|HEAD /v1/media/{capability}/{escaped-name}`

This endpoint does not use the registration bearer secret because general
players and HTML `<video>` elements need a directly usable URL.  The random
capability grants access to only the registered file, and the final name must
match its registered basename.

Normal response headers include:

```text
Accept-Ranges: bytes
Content-Length: 4294967296
Content-Type: video/x-matroska
ETag: "..."
Last-Modified: ...
Cache-Control: private, no-store
```

A request such as:

```text
Range: bytes=1048576-2097151
```

returns `206 Partial Content` and:

```text
Content-Range: bytes 1048576-2097151/4294967296
Content-Length: 1048576
```

Unsatisfiable ranges return `416` with `Content-Range: bytes */SIZE`.

## Embedded Player

`GET /v1/player/{capability}`

Returns a minimal HTML document with a same-origin `<video controls>` element.
The page has a restrictive Content Security Policy and contains no script.

## Revoke Media

`DELETE /v1/media/{capability}`

```text
Authorization: Bearer <session-secret>
```

Returns `204 No Content`.  Future reads using that capability return `404`.

## Error Shape

```json
{"error":{"code":"INVALID_PATH","message":"..."}}
```

Defined codes currently include:

- `UNAUTHORIZED`
- `INVALID_REQUEST`
- `INVALID_PATH`
- `MEDIA_NOT_FOUND`
- `MEDIA_CHANGED`
- `PERMISSION_DENIED`
- `TOO_MANY_OPEN_MEDIA`
- `INTERNAL_ERROR`

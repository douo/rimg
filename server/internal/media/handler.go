package media

import (
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"html/template"
	"io"
	"mime"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"github.com/douo/rimg/server/internal/rvidprotocol"
)

const (
	maxRequestBody = 64 << 10
	maxPathLength  = 4096
)

type Options struct {
	AuthToken string
	TokenTTL  time.Duration
	MaxOpen   int
	Now       func() time.Time
}

type handler struct {
	authToken []byte
	tokenTTL  time.Duration
	maxOpen   int
	now       func() time.Time

	mu      sync.Mutex
	entries map[string]entry
}

type entry struct {
	Path       string
	Name       string
	Size       int64
	ModTime    time.Time
	ETag       string
	LastAccess time.Time
}

type openRequest struct {
	Path string `json:"path"`
}

type openResponse struct {
	ID          string `json:"id"`
	Name        string `json:"name"`
	Size        int64  `json:"size"`
	ModTimeNS   int64  `json:"mtime_ns"`
	ETag        string `json:"etag"`
	URLPath     string `json:"url_path"`
	ContentType string `json:"content_type"`
}

type healthResponse struct {
	OK           bool         `json:"ok"`
	Protocol     int          `json:"protocol"`
	Version      string       `json:"version"`
	PID          int          `json:"pid"`
	Capabilities capabilities `json:"capabilities"`
}

type capabilities struct {
	MediaRange bool `json:"media_range"`
}

type errorResponse struct {
	Error protocolError `json:"error"`
}

type protocolError struct {
	Code    string `json:"code"`
	Message string `json:"message"`
}

func NewHandler(options Options) (http.Handler, error) {
	if len(options.AuthToken) < 32 {
		return nil, errors.New("auth token must contain at least 32 characters")
	}
	if options.TokenTTL <= 0 {
		options.TokenTTL = 24 * time.Hour
	}
	if options.MaxOpen <= 0 {
		options.MaxOpen = 256
	}
	if options.Now == nil {
		options.Now = time.Now
	}
	handler := &handler{
		authToken: []byte(options.AuthToken),
		tokenTTL:  options.TokenTTL,
		maxOpen:   options.MaxOpen,
		now:       options.Now,
		entries:   make(map[string]entry),
	}
	mux := http.NewServeMux()
	mux.HandleFunc("GET /v1/health", handler.handleHealth)
	mux.HandleFunc("POST /v1/media/open", handler.handleOpen)
	mux.HandleFunc("GET /v1/media/{token}/{name}", handler.handleMedia)
	mux.HandleFunc("HEAD /v1/media/{token}/{name}", handler.handleMedia)
	mux.HandleFunc("DELETE /v1/media/{token}", handler.handleRevoke)
	mux.HandleFunc("GET /v1/player/{token}", handler.handlePlayer)
	return mux, nil
}

var playerTemplate = template.Must(template.New("player").Parse(`<!doctype html>
<html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width">
<title>{{.Name}}</title><style>
html,body{height:100%;margin:0;background:#111}body{display:flex;align-items:center;justify-content:center}
video{width:100%;height:100%;object-fit:contain}
</style></head><body>
<video controls autoplay playsinline preload="metadata"><source src="{{.Source}}" type="{{.ContentType}}"></video>
</body></html>`))

func (handler *handler) handlePlayer(response http.ResponseWriter, request *http.Request) {
	token := request.PathValue("token")
	opened, ok := handler.lookup(token)
	if !ok {
		writeError(response, http.StatusNotFound, "MEDIA_NOT_FOUND", "media token is unknown or expired")
		return
	}
	response.Header().Set("Content-Type", "text/html; charset=utf-8")
	response.Header().Set("Cache-Control", "no-store")
	response.Header().Set("Content-Security-Policy", "default-src 'none'; media-src 'self'; style-src 'unsafe-inline'")
	_ = playerTemplate.Execute(response, struct {
		Name        string
		Source      string
		ContentType string
	}{
		Name:        opened.Name,
		Source:      "/v1/media/" + token + "/" + url.PathEscape(opened.Name),
		ContentType: contentType(opened.Name),
	})
}

func (handler *handler) handleHealth(response http.ResponseWriter, _ *http.Request) {
	response.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(response).Encode(healthResponse{
		OK:       true,
		Protocol: rvidprotocol.Version,
		Version:  rvidprotocol.BinaryVersion,
		PID:      os.Getpid(),
		Capabilities: capabilities{
			MediaRange: true,
		},
	})
}

func (handler *handler) handleOpen(response http.ResponseWriter, request *http.Request) {
	if !handler.authorized(request) {
		writeError(response, http.StatusUnauthorized, "UNAUTHORIZED", "invalid session token")
		return
	}
	if mediaType := strings.TrimSpace(strings.Split(request.Header.Get("Content-Type"), ";")[0]); mediaType != "application/json" {
		writeError(response, http.StatusUnsupportedMediaType, "INVALID_REQUEST", "content type must be application/json")
		return
	}

	var input openRequest
	decoder := json.NewDecoder(http.MaxBytesReader(response, request.Body, maxRequestBody))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&input); err != nil {
		writeError(response, http.StatusBadRequest, "INVALID_REQUEST", fmt.Sprintf("invalid open request: %v", err))
		return
	}
	if err := ensureJSONEOF(decoder); err != nil {
		writeError(response, http.StatusBadRequest, "INVALID_REQUEST", fmt.Sprintf("invalid open request: %v", err))
		return
	}
	if input.Path == "" || len(input.Path) > maxPathLength || !filepath.IsAbs(input.Path) {
		writeError(response, http.StatusBadRequest, "INVALID_PATH", "path must be a non-empty absolute path")
		return
	}

	opened, err := openEntry(input.Path, handler.now())
	if err != nil {
		writeFileError(response, err)
		return
	}
	token, err := randomToken()
	if err != nil {
		writeError(response, http.StatusInternalServerError, "INTERNAL_ERROR", "could not allocate media token")
		return
	}

	handler.mu.Lock()
	handler.pruneExpiredLocked(handler.now())
	if len(handler.entries) >= handler.maxOpen {
		handler.mu.Unlock()
		writeError(response, http.StatusTooManyRequests, "TOO_MANY_OPEN_MEDIA", "media registration limit reached")
		return
	}
	handler.entries[token] = opened
	handler.mu.Unlock()

	response.Header().Set("Content-Type", "application/json")
	response.Header().Set("Cache-Control", "no-store")
	response.WriteHeader(http.StatusCreated)
	_ = json.NewEncoder(response).Encode(openResponse{
		ID:          token,
		Name:        opened.Name,
		Size:        opened.Size,
		ModTimeNS:   opened.ModTime.UnixNano(),
		ETag:        opened.ETag,
		URLPath:     "/v1/media/" + token + "/" + url.PathEscape(opened.Name),
		ContentType: contentType(opened.Name),
	})
}

func (handler *handler) handleMedia(response http.ResponseWriter, request *http.Request) {
	token := request.PathValue("token")
	opened, ok := handler.lookup(token)
	if !ok || request.PathValue("name") != opened.Name {
		writeError(response, http.StatusNotFound, "MEDIA_NOT_FOUND", "media token is unknown or expired")
		return
	}

	file, err := os.Open(opened.Path)
	if err != nil {
		writeFileError(response, err)
		return
	}
	defer file.Close()
	info, err := file.Stat()
	if err != nil {
		writeFileError(response, err)
		return
	}
	if !info.Mode().IsRegular() {
		writeError(response, http.StatusConflict, "MEDIA_CHANGED", "registered media is no longer a regular file")
		return
	}
	if info.Size() != opened.Size || !info.ModTime().Equal(opened.ModTime) {
		writeError(response, http.StatusConflict, "MEDIA_CHANGED", "registered media changed; open it again")
		return
	}

	response.Header().Set("Content-Type", contentType(opened.Name))
	response.Header().Set("Cache-Control", "private, no-store")
	response.Header().Set("ETag", opened.ETag)
	http.ServeContent(response, request, opened.Name, opened.ModTime, file)
}

func (handler *handler) handleRevoke(response http.ResponseWriter, request *http.Request) {
	if !handler.authorized(request) {
		writeError(response, http.StatusUnauthorized, "UNAUTHORIZED", "invalid session token")
		return
	}
	handler.mu.Lock()
	_, found := handler.entries[request.PathValue("token")]
	delete(handler.entries, request.PathValue("token"))
	handler.mu.Unlock()
	if !found {
		writeError(response, http.StatusNotFound, "MEDIA_NOT_FOUND", "media token is unknown or expired")
		return
	}
	response.WriteHeader(http.StatusNoContent)
}

func (handler *handler) authorized(request *http.Request) bool {
	provided := []byte(strings.TrimPrefix(request.Header.Get("Authorization"), "Bearer "))
	return len(provided) == len(handler.authToken) &&
		subtle.ConstantTimeCompare(provided, handler.authToken) == 1
}

func (handler *handler) lookup(token string) (entry, bool) {
	now := handler.now()
	handler.mu.Lock()
	defer handler.mu.Unlock()
	opened, found := handler.entries[token]
	if !found || now.Sub(opened.LastAccess) > handler.tokenTTL {
		delete(handler.entries, token)
		return entry{}, false
	}
	opened.LastAccess = now
	handler.entries[token] = opened
	return opened, true
}

func (handler *handler) pruneExpiredLocked(now time.Time) {
	for token, opened := range handler.entries {
		if now.Sub(opened.LastAccess) > handler.tokenTTL {
			delete(handler.entries, token)
		}
	}
}

func openEntry(path string, now time.Time) (entry, error) {
	canonical, err := filepath.EvalSymlinks(path)
	if err != nil {
		return entry{}, err
	}
	canonical, err = filepath.Abs(canonical)
	if err != nil {
		return entry{}, err
	}
	file, err := os.Open(canonical)
	if err != nil {
		return entry{}, err
	}
	defer file.Close()
	info, err := file.Stat()
	if err != nil {
		return entry{}, err
	}
	if !info.Mode().IsRegular() {
		return entry{}, errNotRegular
	}
	digest := sha256.Sum256([]byte(fmt.Sprintf(
		"%s\x00%d\x00%d", canonical, info.Size(), info.ModTime().UnixNano(),
	)))
	return entry{
		Path:       canonical,
		Name:       filepath.Base(canonical),
		Size:       info.Size(),
		ModTime:    info.ModTime(),
		ETag:       `"` + hex.EncodeToString(digest[:]) + `"`,
		LastAccess: now,
	}, nil
}

var errNotRegular = errors.New("media is not a regular file")

func randomToken() (string, error) {
	data := make([]byte, 16)
	if _, err := rand.Read(data); err != nil {
		return "", err
	}
	return hex.EncodeToString(data), nil
}

var knownContentTypes = map[string]string{
	".mp4":  "video/mp4",
	".m4v":  "video/x-m4v",
	".mov":  "video/quicktime",
	".mkv":  "video/x-matroska",
	".webm": "video/webm",
	".ogv":  "video/ogg",
	".avi":  "video/x-msvideo",
	".mpeg": "video/mpeg",
	".mpg":  "video/mpeg",
	".ts":   "video/mp2t",
	".mp3":  "audio/mpeg",
	".m4a":  "audio/mp4",
	".aac":  "audio/aac",
	".flac": "audio/flac",
	".ogg":  "audio/ogg",
	".opus": "audio/ogg",
	".wav":  "audio/wav",
}

func contentType(name string) string {
	extension := strings.ToLower(filepath.Ext(name))
	if detected := knownContentTypes[extension]; detected != "" {
		return detected
	}
	if detected := mime.TypeByExtension(extension); detected != "" {
		return detected
	}
	return "application/octet-stream"
}

func writeFileError(response http.ResponseWriter, err error) {
	switch {
	case errors.Is(err, os.ErrNotExist):
		writeError(response, http.StatusNotFound, "MEDIA_NOT_FOUND", "media file does not exist")
	case errors.Is(err, os.ErrPermission):
		writeError(response, http.StatusForbidden, "PERMISSION_DENIED", "media file is not readable")
	case errors.Is(err, errNotRegular):
		writeError(response, http.StatusBadRequest, "INVALID_PATH", "media path is not a regular file")
	default:
		writeError(response, http.StatusInternalServerError, "INTERNAL_ERROR", "media file could not be opened")
	}
}

func writeError(response http.ResponseWriter, status int, code, message string) {
	response.Header().Set("Content-Type", "application/json")
	response.Header().Set("Cache-Control", "no-store")
	response.WriteHeader(status)
	_ = json.NewEncoder(response).Encode(errorResponse{
		Error: protocolError{Code: code, Message: message},
	})
}

func ensureJSONEOF(decoder *json.Decoder) error {
	var extra any
	if err := decoder.Decode(&extra); err != io.EOF {
		if err == nil {
			return errors.New("multiple JSON values")
		}
		return err
	}
	return nil
}

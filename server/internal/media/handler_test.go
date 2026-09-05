package media

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

const testAuthToken = "0123456789abcdef0123456789abcdef"

type registeredMedia struct {
	ID          string `json:"id"`
	Name        string `json:"name"`
	Size        int64  `json:"size"`
	ModTimeNS   int64  `json:"mtime_ns"`
	ETag        string `json:"etag"`
	URLPath     string `json:"url_path"`
	ContentType string `json:"content_type"`
}

func TestOpenRequiresSessionAuthorizationAndAbsoluteRegularPath(t *testing.T) {
	handler := newTestHandler(t, time.Now, time.Hour)

	request := httptest.NewRequest(http.MethodPost, "/v1/media/open", strings.NewReader(`{"path":"/tmp/movie.mp4"}`))
	request.Header.Set("Content-Type", "application/json")
	response := httptest.NewRecorder()
	handler.ServeHTTP(response, request)
	if response.Code != http.StatusUnauthorized {
		t.Fatalf("unauthorized status = %d, want 401", response.Code)
	}

	request = authorizedOpenRequest(t, "relative/movie.mp4")
	response = httptest.NewRecorder()
	handler.ServeHTTP(response, request)
	if response.Code != http.StatusBadRequest {
		t.Fatalf("relative path status = %d, want 400", response.Code)
	}

	directory := t.TempDir()
	request = authorizedOpenRequest(t, directory)
	response = httptest.NewRecorder()
	handler.ServeHTTP(response, request)
	if response.Code != http.StatusBadRequest {
		t.Fatalf("directory path status = %d, want 400", response.Code)
	}
}

func TestRegisteredMediaSupportsHeadFullGetAndByteRanges(t *testing.T) {
	now := time.Unix(1_700_000_000, 123456789)
	handler := newTestHandler(t, func() time.Time { return now }, time.Hour)
	contents := make([]byte, 256)
	for index := range contents {
		contents[index] = byte(index)
	}
	path := filepath.Join(t.TempDir(), "movie sample.mp4")
	if err := os.WriteFile(path, contents, 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.Chtimes(path, now, now); err != nil {
		t.Fatal(err)
	}
	opened := register(t, handler, path)
	if opened.Name != "movie sample.mp4" || opened.Size != int64(len(contents)) {
		t.Fatalf("unexpected registration: %+v", opened)
	}
	if opened.ContentType != "video/mp4" {
		t.Fatalf("content type = %q, want video/mp4", opened.ContentType)
	}
	if !strings.Contains(opened.URLPath, "movie%20sample.mp4") {
		t.Fatalf("URL path is not escaped: %q", opened.URLPath)
	}
	player := httptest.NewRecorder()
	handler.ServeHTTP(player, httptest.NewRequest(
		http.MethodGet, "/v1/player/"+opened.ID, nil,
	))
	if player.Code != http.StatusOK ||
		!strings.Contains(player.Body.String(), "<video controls") ||
		!strings.Contains(player.Body.String(), opened.URLPath) {
		t.Fatalf("unexpected player page: status=%d body=%s", player.Code, player.Body.String())
	}

	head := httptest.NewRecorder()
	handler.ServeHTTP(head, httptest.NewRequest(http.MethodHead, opened.URLPath, nil))
	if head.Code != http.StatusOK {
		t.Fatalf("HEAD status = %d, want 200: %s", head.Code, head.Body.String())
	}
	if got := head.Header().Get("Accept-Ranges"); got != "bytes" {
		t.Fatalf("Accept-Ranges = %q, want bytes", got)
	}
	if got := head.Header().Get("Content-Length"); got != "256" {
		t.Fatalf("Content-Length = %q, want 256", got)
	}
	if head.Body.Len() != 0 {
		t.Fatalf("HEAD returned %d body bytes", head.Body.Len())
	}

	rangeRequest := httptest.NewRequest(http.MethodGet, opened.URLPath, nil)
	rangeRequest.Header.Set("Range", "bytes=10-19")
	partial := httptest.NewRecorder()
	handler.ServeHTTP(partial, rangeRequest)
	if partial.Code != http.StatusPartialContent {
		t.Fatalf("range status = %d, want 206: %s", partial.Code, partial.Body.String())
	}
	if got := partial.Header().Get("Content-Range"); got != "bytes 10-19/256" {
		t.Fatalf("Content-Range = %q", got)
	}
	if !bytes.Equal(partial.Body.Bytes(), contents[10:20]) {
		t.Fatalf("range body = %v, want %v", partial.Body.Bytes(), contents[10:20])
	}

	full := httptest.NewRecorder()
	handler.ServeHTTP(full, httptest.NewRequest(http.MethodGet, opened.URLPath, nil))
	if full.Code != http.StatusOK || !bytes.Equal(full.Body.Bytes(), contents) {
		t.Fatalf("full GET status/body mismatch: status=%d bytes=%d", full.Code, full.Body.Len())
	}

	invalidRequest := httptest.NewRequest(http.MethodGet, opened.URLPath, nil)
	invalidRequest.Header.Set("Range", "bytes=999-1000")
	invalid := httptest.NewRecorder()
	handler.ServeHTTP(invalid, invalidRequest)
	if invalid.Code != http.StatusRequestedRangeNotSatisfiable {
		t.Fatalf("invalid range status = %d, want 416", invalid.Code)
	}
	if got := invalid.Header().Get("Content-Range"); got != "bytes */256" {
		t.Fatalf("invalid range Content-Range = %q", got)
	}
}

func TestCapabilityIsBoundToOneNameAndDetectsFileChanges(t *testing.T) {
	now := time.Unix(1_700_000_000, 0)
	handler := newTestHandler(t, func() time.Time { return now }, time.Hour)
	path := filepath.Join(t.TempDir(), "movie.mkv")
	if err := os.WriteFile(path, []byte("original movie bytes"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.Chtimes(path, now, now); err != nil {
		t.Fatal(err)
	}
	opened := register(t, handler, path)

	wrongName := strings.TrimSuffix(opened.URLPath, "movie.mkv") + "secret.txt"
	response := httptest.NewRecorder()
	handler.ServeHTTP(response, httptest.NewRequest(http.MethodGet, wrongName, nil))
	if response.Code != http.StatusNotFound {
		t.Fatalf("wrong capability name status = %d, want 404", response.Code)
	}

	if err := os.WriteFile(path, []byte("changed movie bytes with a new size"), 0o600); err != nil {
		t.Fatal(err)
	}
	response = httptest.NewRecorder()
	handler.ServeHTTP(response, httptest.NewRequest(http.MethodGet, opened.URLPath, nil))
	if response.Code != http.StatusConflict {
		t.Fatalf("changed media status = %d, want 409: %s", response.Code, response.Body.String())
	}
}

func TestCapabilityUsesSlidingExpiryAndCanBeRevoked(t *testing.T) {
	now := time.Unix(1_700_000_000, 0)
	handler := newTestHandler(t, func() time.Time { return now }, time.Minute)
	path := filepath.Join(t.TempDir(), "movie.webm")
	if err := os.WriteFile(path, []byte("movie"), 0o600); err != nil {
		t.Fatal(err)
	}
	opened := register(t, handler, path)

	now = now.Add(30 * time.Second)
	response := httptest.NewRecorder()
	handler.ServeHTTP(response, httptest.NewRequest(http.MethodHead, opened.URLPath, nil))
	if response.Code != http.StatusOK {
		t.Fatalf("first refresh status = %d", response.Code)
	}
	now = now.Add(45 * time.Second)
	response = httptest.NewRecorder()
	handler.ServeHTTP(response, httptest.NewRequest(http.MethodHead, opened.URLPath, nil))
	if response.Code != http.StatusOK {
		t.Fatalf("sliding refresh status = %d", response.Code)
	}

	revoke := httptest.NewRequest(http.MethodDelete, "/v1/media/"+opened.ID, nil)
	revoke.Header.Set("Authorization", "Bearer "+testAuthToken)
	response = httptest.NewRecorder()
	handler.ServeHTTP(response, revoke)
	if response.Code != http.StatusNoContent {
		t.Fatalf("revoke status = %d, want 204", response.Code)
	}
	response = httptest.NewRecorder()
	handler.ServeHTTP(response, httptest.NewRequest(http.MethodGet, opened.URLPath, nil))
	if response.Code != http.StatusNotFound {
		t.Fatalf("revoked media status = %d, want 404", response.Code)
	}
}

func TestExpiredCapabilityIsRejected(t *testing.T) {
	now := time.Unix(1_700_000_000, 0)
	handler := newTestHandler(t, func() time.Time { return now }, time.Minute)
	path := filepath.Join(t.TempDir(), "movie.mp4")
	if err := os.WriteFile(path, []byte("movie"), 0o600); err != nil {
		t.Fatal(err)
	}
	opened := register(t, handler, path)
	now = now.Add(time.Minute + time.Nanosecond)

	response := httptest.NewRecorder()
	handler.ServeHTTP(response, httptest.NewRequest(http.MethodGet, opened.URLPath, nil))
	if response.Code != http.StatusNotFound {
		t.Fatalf("expired media status = %d, want 404", response.Code)
	}
}

func newTestHandler(t *testing.T, now func() time.Time, ttl time.Duration) http.Handler {
	t.Helper()
	handler, err := NewHandler(Options{
		AuthToken: testAuthToken,
		TokenTTL:  ttl,
		MaxOpen:   8,
		Now:       now,
	})
	if err != nil {
		t.Fatal(err)
	}
	return handler
}

func authorizedOpenRequest(t *testing.T, path string) *http.Request {
	t.Helper()
	body := fmt.Sprintf(`{"path":%q}`, path)
	request := httptest.NewRequest(http.MethodPost, "/v1/media/open", strings.NewReader(body))
	request.Header.Set("Authorization", "Bearer "+testAuthToken)
	request.Header.Set("Content-Type", "application/json")
	return request
}

func register(t *testing.T, handler http.Handler, path string) registeredMedia {
	t.Helper()
	response := httptest.NewRecorder()
	handler.ServeHTTP(response, authorizedOpenRequest(t, path))
	if response.Code != http.StatusCreated {
		t.Fatalf("open status = %d, want 201: %s", response.Code, response.Body.String())
	}
	var opened registeredMedia
	if err := json.NewDecoder(response.Body).Decode(&opened); err != nil && err != io.EOF {
		t.Fatal(err)
	}
	return opened
}

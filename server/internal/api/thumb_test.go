package api_test

import (
	"bytes"
	"encoding/base64"
	"encoding/json"
	"image"
	"image/color"
	"image/jpeg"
	"image/png"
	"maps"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/douo/rimg/server/internal/api"
)

const webPFixtureBase64 = "UklGRjQAAABXRUJQVlA4ICgAAACQAQCdASoIAAQAAgA0JaACdLoAA5gA/uUK//npn9bfx/5mea+IFuAA"

func TestThumbnailRequestGeneratesThenReusesRemoteCache(t *testing.T) {
	tempDir := t.TempDir()
	original := filepath.Join(tempDir, "original.jpg")
	writeJPEGFixture(t, original, 400, 200)

	handler := api.NewHandler(api.Options{
		CacheDir: filepath.Join(tempDir, "cache"),
	})
	requestBody := map[string]any{
		"path":    original,
		"width":   100,
		"height":  100,
		"fit":     "contain",
		"format":  "jpeg",
		"quality": 82,
	}

	first := performJSONRequest(t, handler, http.MethodPost, "/v1/thumb", requestBody)
	if first.Code != http.StatusOK {
		t.Fatalf("first status = %d, want 200: %s", first.Code, first.Body.String())
	}
	if got := first.Header().Get("Content-Type"); got != "image/jpeg" {
		t.Fatalf("content type = %q, want image/jpeg", got)
	}
	if got := first.Header().Get("X-Rimg-Cache"); got != "MISS" {
		t.Fatalf("first cache status = %q, want MISS", got)
	}
	cacheKey := first.Header().Get("X-Rimg-Key")
	if cacheKey == "" {
		t.Fatal("first response has no X-Rimg-Key")
	}
	if got := first.Header().Get("ETag"); got != `"`+cacheKey+`"` {
		t.Fatalf("ETag = %q, want quoted cache key", got)
	}

	imageConfig, err := jpeg.DecodeConfig(bytes.NewReader(first.Body.Bytes()))
	if err != nil {
		t.Fatalf("decode thumbnail: %v", err)
	}
	if imageConfig.Width != 100 || imageConfig.Height != 50 {
		t.Fatalf("thumbnail dimensions = %dx%d, want 100x50",
			imageConfig.Width, imageConfig.Height)
	}

	second := performJSONRequest(t, handler, http.MethodPost, "/v1/thumb", requestBody)
	if second.Code != http.StatusOK {
		t.Fatalf("second status = %d, want 200: %s", second.Code, second.Body.String())
	}
	if got := second.Header().Get("X-Rimg-Cache"); got != "HIT" {
		t.Fatalf("second cache status = %q, want HIT", got)
	}
	if got := second.Header().Get("X-Rimg-Key"); got != cacheKey {
		t.Fatalf("second cache key = %q, want %q", got, cacheKey)
	}
	if !bytes.Equal(first.Body.Bytes(), second.Body.Bytes()) {
		t.Fatal("cached thumbnail differs from generated thumbnail")
	}

	conditional := performJSONRequestWithHeaders(
		t, handler, http.MethodPost, "/v1/thumb", requestBody,
		map[string]string{"If-None-Match": first.Header().Get("ETag")},
	)
	if conditional.Code != http.StatusOK {
		t.Fatalf("conditional status = %d, want 200", conditional.Code)
	}
	if conditional.Body.Len() != 0 {
		t.Fatalf("conditional body = %d bytes, want 0", conditional.Body.Len())
	}
	if got := conditional.Header().Get("X-Rimg-Key"); got != cacheKey {
		t.Fatalf("conditional cache key = %q, want %q", got, cacheKey)
	}
	if got := conditional.Header().Get("X-Rimg-Cache"); got != "HIT" {
		t.Fatalf("conditional cache status = %q, want HIT", got)
	}
	if got := conditional.Header().Get("X-Rimg-Not-Modified"); got != "true" {
		t.Fatalf("conditional not-modified marker = %q, want true", got)
	}
}

func TestThumbnailRequestDecodesWebPInput(t *testing.T) {
	tempDir := t.TempDir()
	original := filepath.Join(tempDir, "original.webp")
	webPBytes, err := base64.StdEncoding.DecodeString(webPFixtureBase64)
	if err != nil {
		t.Fatalf("decode embedded WebP fixture: %v", err)
	}
	if err := os.WriteFile(original, webPBytes, 0o600); err != nil {
		t.Fatalf("write WebP fixture: %v", err)
	}

	handler := api.NewHandler(api.Options{CacheDir: filepath.Join(tempDir, "cache")})
	response := performJSONRequest(t, handler, http.MethodPost, "/v1/thumb", map[string]any{
		"path": original, "width": 4, "height": 4,
		"fit": "contain", "format": "jpeg", "quality": 82,
	})
	if response.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200: %s", response.Code, response.Body.String())
	}
	config, err := jpeg.DecodeConfig(bytes.NewReader(response.Body.Bytes()))
	if err != nil {
		t.Fatalf("decode generated JPEG: %v", err)
	}
	if config.Width != 4 || config.Height != 2 {
		t.Fatalf("thumbnail dimensions = %dx%d, want 4x2", config.Width, config.Height)
	}
}

func TestThumbnailRequestDecodesAndEncodesPNG(t *testing.T) {
	tempDir := t.TempDir()
	original := filepath.Join(tempDir, "original.png")
	writePNGFixture(t, original, 40, 20)
	handler := api.NewHandler(api.Options{CacheDir: filepath.Join(tempDir, "cache")})
	response := performJSONRequest(t, handler, http.MethodPost, "/v1/thumb", map[string]any{
		"path": original, "width": 20, "height": 20,
		"fit": "contain", "format": "png", "quality": 82,
	})
	if response.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200: %s", response.Code, response.Body.String())
	}
	if got := response.Header().Get("Content-Type"); got != "image/png" {
		t.Fatalf("content type = %q, want image/png", got)
	}
	config, err := png.DecodeConfig(bytes.NewReader(response.Body.Bytes()))
	if err != nil {
		t.Fatalf("decode generated PNG: %v", err)
	}
	if config.Width != 20 || config.Height != 10 {
		t.Fatalf("thumbnail dimensions = %dx%d, want 20x10", config.Width, config.Height)
	}
}

func TestThumbnailRejectsUnsafeDimensionsWithStructuredError(t *testing.T) {
	tempDir := t.TempDir()
	original := filepath.Join(tempDir, "original.jpg")
	writeJPEGFixture(t, original, 16, 16)
	handler := api.NewHandler(api.Options{CacheDir: filepath.Join(tempDir, "cache")})

	for _, dimensions := range []struct {
		name   string
		width  int
		height int
	}{
		{name: "zero", width: 0, height: 100},
		{name: "too large", width: 2049, height: 100},
	} {
		t.Run(dimensions.name, func(t *testing.T) {
			response := performJSONRequest(t, handler, http.MethodPost, "/v1/thumb", map[string]any{
				"path": original, "width": dimensions.width, "height": dimensions.height,
				"fit": "contain", "format": "jpeg", "quality": 82,
			})
			if response.Code != http.StatusBadRequest {
				t.Fatalf("status = %d, want 400: %s", response.Code, response.Body.String())
			}
			assertErrorCode(t, response, "INVALID_DIMENSION")
		})
	}
}

func TestThumbnailReportsMissingImageAsNotFound(t *testing.T) {
	tempDir := t.TempDir()
	handler := api.NewHandler(api.Options{CacheDir: filepath.Join(tempDir, "cache")})
	response := performJSONRequest(t, handler, http.MethodPost, "/v1/thumb", map[string]any{
		"path": filepath.Join(tempDir, "missing.jpg"), "width": 100, "height": 100,
		"fit": "contain", "format": "jpeg", "quality": 82,
	})
	if response.Code != http.StatusNotFound {
		t.Fatalf("status = %d, want 404: %s", response.Code, response.Body.String())
	}
	assertErrorCode(t, response, "IMAGE_NOT_FOUND")
}

func TestThumbnailReportsUnsupportedInputFormat(t *testing.T) {
	tempDir := t.TempDir()
	original := filepath.Join(tempDir, "not-an-image.txt")
	if err := os.WriteFile(original, []byte("not an image"), 0o600); err != nil {
		t.Fatalf("write invalid fixture: %v", err)
	}
	handler := api.NewHandler(api.Options{CacheDir: filepath.Join(tempDir, "cache")})
	response := performJSONRequest(t, handler, http.MethodPost, "/v1/thumb", map[string]any{
		"path": original, "width": 100, "height": 100,
		"fit": "contain", "format": "jpeg", "quality": 82,
	})
	if response.Code != http.StatusUnsupportedMediaType {
		t.Fatalf("status = %d, want 415: %s", response.Code, response.Body.String())
	}
	assertErrorCode(t, response, "UNSUPPORTED_FORMAT")
}

func TestThumbnailReportsCorruptSupportedImage(t *testing.T) {
	tempDir := t.TempDir()
	original := filepath.Join(tempDir, "corrupt.jpg")
	if err := os.WriteFile(original, []byte{0xff, 0xd8, 0xff, 0xdb, 0x00}, 0o600); err != nil {
		t.Fatalf("write corrupt JPEG fixture: %v", err)
	}
	handler := api.NewHandler(api.Options{CacheDir: filepath.Join(tempDir, "cache")})
	response := performJSONRequest(t, handler, http.MethodPost, "/v1/thumb", map[string]any{
		"path": original, "width": 100, "height": 100,
		"fit": "contain", "format": "jpeg", "quality": 82,
	})
	if response.Code != http.StatusUnprocessableEntity {
		t.Fatalf("status = %d, want 422: %s", response.Code, response.Body.String())
	}
	assertErrorCode(t, response, "DECODE_FAILED")
}

func TestThumbnailRejectsInvalidTransformRequests(t *testing.T) {
	tempDir := t.TempDir()
	original := filepath.Join(tempDir, "original.jpg")
	writeJPEGFixture(t, original, 16, 16)
	handler := api.NewHandler(api.Options{CacheDir: filepath.Join(tempDir, "cache")})
	valid := map[string]any{
		"path": original, "width": 100, "height": 100,
		"fit": "contain", "format": "jpeg", "quality": 82,
	}

	tests := []struct {
		name  string
		field string
		value any
	}{
		{name: "empty path", field: "path", value: ""},
		{name: "long path", field: "path", value: "/" + strings.Repeat("a", 4096)},
		{name: "unsupported fit", field: "fit", value: "cover"},
		{name: "unsupported output", field: "format", value: "webp"},
		{name: "zero quality", field: "quality", value: 0},
		{name: "excessive quality", field: "quality", value: 101},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			requestBody := maps.Clone(valid)
			requestBody[test.field] = test.value
			response := performJSONRequest(t, handler, http.MethodPost, "/v1/thumb", requestBody)
			if response.Code != http.StatusBadRequest {
				t.Fatalf("status = %d, want 400: %s", response.Code, response.Body.String())
			}
			assertErrorCode(t, response, "INVALID_REQUEST")
		})
	}
}

func TestThumbnailRejectsOversizedRequestBody(t *testing.T) {
	tempDir := t.TempDir()
	handler := api.NewHandler(api.Options{CacheDir: filepath.Join(tempDir, "cache")})
	body := `{"path":"` + strings.Repeat("a", (1<<20)+1) + `"}`
	request := httptest.NewRequest(http.MethodPost, "/v1/thumb", strings.NewReader(body))
	request.Header.Set("Content-Type", "application/json")
	response := httptest.NewRecorder()
	handler.ServeHTTP(response, request)
	if response.Code != http.StatusBadRequest {
		t.Fatalf("status = %d, want 400: %s", response.Code, response.Body.String())
	}
	assertErrorCode(t, response, "INVALID_REQUEST")
}

func TestThumbnailCacheIdentityTracksMetadataAndTransform(t *testing.T) {
	tempDir := t.TempDir()
	original := filepath.Join(tempDir, "original.jpg")
	writeJPEGFixture(t, original, 64, 32)
	handler := api.NewHandler(api.Options{CacheDir: filepath.Join(tempDir, "cache")})
	requestBody := map[string]any{
		"path": original, "width": 32, "height": 32,
		"fit": "contain", "format": "jpeg", "quality": 82,
	}

	initial := performJSONRequest(t, handler, http.MethodPost, "/v1/thumb", requestBody)
	if initial.Code != http.StatusOK {
		t.Fatalf("initial status = %d: %s", initial.Code, initial.Body.String())
	}
	initialKey := initial.Header().Get("X-Rimg-Key")

	info, err := os.Stat(original)
	if err != nil {
		t.Fatalf("stat original: %v", err)
	}
	mtimeOnly := info.ModTime().Add(time.Second)
	if err := os.Chtimes(original, mtimeOnly, mtimeOnly); err != nil {
		t.Fatalf("change mtime: %v", err)
	}
	afterMtime := performJSONRequest(t, handler, http.MethodPost, "/v1/thumb", requestBody)
	assertCacheMissWithDifferentKey(t, afterMtime, initialKey)
	mtimeKey := afterMtime.Header().Get("X-Rimg-Key")

	file, err := os.OpenFile(original, os.O_APPEND|os.O_WRONLY, 0)
	if err != nil {
		t.Fatalf("open original for size change: %v", err)
	}
	if _, err := file.Write([]byte{0}); err != nil {
		_ = file.Close()
		t.Fatalf("append original: %v", err)
	}
	if err := file.Close(); err != nil {
		t.Fatalf("close original after append: %v", err)
	}
	if err := os.Chtimes(original, mtimeOnly, mtimeOnly); err != nil {
		t.Fatalf("restore mtime after size change: %v", err)
	}
	afterSize := performJSONRequest(t, handler, http.MethodPost, "/v1/thumb", requestBody)
	assertCacheMissWithDifferentKey(t, afterSize, mtimeKey)
	sizeKey := afterSize.Header().Get("X-Rimg-Key")

	changedTransform := maps.Clone(requestBody)
	changedTransform["width"] = 24
	afterTransform := performJSONRequest(t, handler, http.MethodPost, "/v1/thumb", changedTransform)
	assertCacheMissWithDifferentKey(t, afterTransform, sizeKey)
}

func TestConcurrentThumbnailRequestsLeaveValidAtomicCacheEntry(t *testing.T) {
	tempDir := t.TempDir()
	original := filepath.Join(tempDir, "original.jpg")
	writeJPEGFixture(t, original, 800, 400)
	cacheDir := filepath.Join(tempDir, "cache")
	handler := api.NewHandler(api.Options{CacheDir: cacheDir})
	requestBody := map[string]any{
		"path": original, "width": 200, "height": 200,
		"fit": "contain", "format": "jpeg", "quality": 82,
	}

	const requestCount = 16
	responses := make([]*httptest.ResponseRecorder, requestCount)
	var wait sync.WaitGroup
	for index := range responses {
		wait.Add(1)
		go func() {
			defer wait.Done()
			responses[index] = performJSONRequest(
				t, handler, http.MethodPost, "/v1/thumb", requestBody)
		}()
	}
	wait.Wait()

	var wantKey string
	var wantData []byte
	for index, response := range responses {
		if response.Code != http.StatusOK {
			t.Fatalf("response %d status = %d: %s", index, response.Code, response.Body.String())
		}
		if _, err := jpeg.Decode(bytes.NewReader(response.Body.Bytes())); err != nil {
			t.Fatalf("response %d is corrupt: %v", index, err)
		}
		if index == 0 {
			wantKey = response.Header().Get("X-Rimg-Key")
			wantData = bytes.Clone(response.Body.Bytes())
			continue
		}
		if got := response.Header().Get("X-Rimg-Key"); got != wantKey {
			t.Fatalf("response %d key = %q, want %q", index, got, wantKey)
		}
		if !bytes.Equal(response.Body.Bytes(), wantData) {
			t.Fatalf("response %d data differs", index)
		}
	}

	temporaryEntries, err := filepath.Glob(filepath.Join(cacheDir, "*", "*.tmp.*"))
	if err != nil {
		t.Fatalf("scan temporary cache entries: %v", err)
	}
	if len(temporaryEntries) != 0 {
		t.Fatalf("temporary cache entries remain: %v", temporaryEntries)
	}
	warm := performJSONRequest(t, handler, http.MethodPost, "/v1/thumb", requestBody)
	if warm.Header().Get("X-Rimg-Cache") != "HIT" {
		t.Fatalf("warm request cache status = %q, want HIT", warm.Header().Get("X-Rimg-Cache"))
	}
	if !bytes.Equal(warm.Body.Bytes(), wantData) {
		t.Fatal("warm cache entry is corrupt")
	}
}

func TestThumbnailReportsPermissionDenied(t *testing.T) {
	tempDir := t.TempDir()
	original := filepath.Join(tempDir, "private.jpg")
	writeJPEGFixture(t, original, 16, 16)
	if err := os.Chmod(original, 0); err != nil {
		t.Fatalf("remove fixture permissions: %v", err)
	}
	t.Cleanup(func() { _ = os.Chmod(original, 0o600) })

	handler := api.NewHandler(api.Options{CacheDir: filepath.Join(tempDir, "cache")})
	response := performJSONRequest(t, handler, http.MethodPost, "/v1/thumb", map[string]any{
		"path": original, "width": 100, "height": 100,
		"fit": "contain", "format": "jpeg", "quality": 82,
	})
	if response.Code != http.StatusForbidden {
		t.Fatalf("status = %d, want 403: %s", response.Code, response.Body.String())
	}
	assertErrorCode(t, response, "PERMISSION_DENIED")
}

func TestThumbnailReportsCacheFailure(t *testing.T) {
	tempDir := t.TempDir()
	original := filepath.Join(tempDir, "original.jpg")
	writeJPEGFixture(t, original, 16, 16)
	cachePath := filepath.Join(tempDir, "cache-is-a-file")
	if err := os.WriteFile(cachePath, []byte("not a directory"), 0o600); err != nil {
		t.Fatalf("write invalid cache fixture: %v", err)
	}

	handler := api.NewHandler(api.Options{CacheDir: cachePath})
	response := performJSONRequest(t, handler, http.MethodPost, "/v1/thumb", map[string]any{
		"path": original, "width": 100, "height": 100,
		"fit": "contain", "format": "jpeg", "quality": 82,
	})
	if response.Code != http.StatusInternalServerError {
		t.Fatalf("status = %d, want 500: %s", response.Code, response.Body.String())
	}
	assertErrorCode(t, response, "CACHE_ERROR")
}

func performJSONRequest(
	t *testing.T,
	handler http.Handler,
	method string,
	path string,
	body any,
) *httptest.ResponseRecorder {
	t.Helper()
	return performJSONRequestWithHeaders(t, handler, method, path, body, nil)
}

func performJSONRequestWithHeaders(
	t *testing.T,
	handler http.Handler,
	method string,
	path string,
	body any,
	headers map[string]string,
) *httptest.ResponseRecorder {
	t.Helper()
	encoded, err := json.Marshal(body)
	if err != nil {
		t.Fatalf("encode request: %v", err)
	}
	request := httptest.NewRequest(method, path, bytes.NewReader(encoded))
	request.Header.Set("Content-Type", "application/json")
	for name, value := range headers {
		request.Header.Set(name, value)
	}
	response := httptest.NewRecorder()
	handler.ServeHTTP(response, request)
	return response
}

func assertErrorCode(t *testing.T, response *httptest.ResponseRecorder, want string) {
	t.Helper()
	var body struct {
		Error struct {
			Code    string `json:"code"`
			Message string `json:"message"`
		} `json:"error"`
	}
	if err := json.Unmarshal(response.Body.Bytes(), &body); err != nil {
		t.Fatalf("decode error response: %v\n%s", err, response.Body.String())
	}
	if body.Error.Code != want {
		t.Fatalf("error code = %q, want %q: %s", body.Error.Code, want, response.Body.String())
	}
	if body.Error.Message == "" {
		t.Fatal("error message is empty")
	}
}

func assertCacheMissWithDifferentKey(
	t *testing.T,
	response *httptest.ResponseRecorder,
	previousKey string,
) {
	t.Helper()
	if response.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200: %s", response.Code, response.Body.String())
	}
	if got := response.Header().Get("X-Rimg-Cache"); got != "MISS" {
		t.Fatalf("cache status = %q, want MISS", got)
	}
	if got := response.Header().Get("X-Rimg-Key"); got == "" || got == previousKey {
		t.Fatalf("cache key = %q, previous key = %q", got, previousKey)
	}
}

func writeJPEGFixture(t *testing.T, path string, width, height int) {
	t.Helper()
	pixels := image.NewRGBA(image.Rect(0, 0, width, height))
	for y := 0; y < height; y++ {
		for x := 0; x < width; x++ {
			pixels.Set(x, y, color.RGBA{
				R: uint8(x % 256),
				G: uint8(y % 256),
				B: 96,
				A: 255,
			})
		}
	}
	file, err := os.Create(path)
	if err != nil {
		t.Fatalf("create JPEG fixture: %v", err)
	}
	if err := jpeg.Encode(file, pixels, &jpeg.Options{Quality: 90}); err != nil {
		_ = file.Close()
		t.Fatalf("encode JPEG fixture: %v", err)
	}
	if err := file.Close(); err != nil {
		t.Fatalf("close JPEG fixture: %v", err)
	}
}

func writePNGFixture(t *testing.T, path string, width, height int) {
	t.Helper()
	pixels := image.NewNRGBA(image.Rect(0, 0, width, height))
	for y := 0; y < height; y++ {
		for x := 0; x < width; x++ {
			pixels.Set(x, y, color.NRGBA{
				R: uint8(x % 256), G: uint8(y % 256), B: 160, A: uint8(64 + x%192),
			})
		}
	}
	file, err := os.Create(path)
	if err != nil {
		t.Fatalf("create PNG fixture: %v", err)
	}
	if err := png.Encode(file, pixels); err != nil {
		_ = file.Close()
		t.Fatalf("encode PNG fixture: %v", err)
	}
	if err := file.Close(); err != nil {
		t.Fatalf("close PNG fixture: %v", err)
	}
}

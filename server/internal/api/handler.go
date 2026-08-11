package api

import (
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"

	"github.com/douo/rimg/server/internal/cache"
	"github.com/douo/rimg/server/internal/imageproc"
	"github.com/douo/rimg/server/internal/protocol"
)

const (
	maxRequestBody        = 1 << 20
	maxThumbnailDimension = 2048
	maxPathLength         = 4096
)

type Options struct {
	CacheDir string
}

type handler struct {
	cache *cache.Store
}

type healthResponse struct {
	OK           bool         `json:"ok"`
	Protocol     int          `json:"protocol"`
	Version      string       `json:"version"`
	PID          int          `json:"pid"`
	Capabilities capabilities `json:"capabilities"`
}

type capabilities struct {
	Decode  []string `json:"decode"`
	Encode  []string `json:"encode"`
	Prepare bool     `json:"prepare"`
}

func NewHandler(options Options) http.Handler {
	handler := &handler{cache: cache.NewStore(options.CacheDir)}
	mux := http.NewServeMux()
	mux.HandleFunc("GET /v1/health", handleHealth)
	mux.HandleFunc("POST /v1/thumb", handler.handleThumbnail)
	return mux
}

func handleHealth(response http.ResponseWriter, _ *http.Request) {
	response.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(response).Encode(healthResponse{
		OK:       true,
		Protocol: protocol.Version,
		Version:  protocol.BinaryVersion,
		PID:      os.Getpid(),
		Capabilities: capabilities{
			Decode:  []string{"jpeg", "png", "webp"},
			Encode:  []string{"jpeg", "png"},
			Prepare: false,
		},
	})
}

type thumbnailRequest struct {
	Path    string `json:"path"`
	Width   int    `json:"width"`
	Height  int    `json:"height"`
	Fit     string `json:"fit"`
	Format  string `json:"format"`
	Quality int    `json:"quality"`
}

type errorResponse struct {
	Error protocolError `json:"error"`
}

type protocolError struct {
	Code    string `json:"code"`
	Message string `json:"message"`
}

func (handler *handler) handleThumbnail(response http.ResponseWriter, request *http.Request) {
	var input thumbnailRequest
	decoder := json.NewDecoder(http.MaxBytesReader(response, request.Body, maxRequestBody))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&input); err != nil {
		writeError(response, http.StatusBadRequest, "INVALID_REQUEST",
			fmt.Sprintf("invalid thumbnail request: %v", err))
		return
	}
	if err := ensureJSONEOF(decoder); err != nil {
		writeError(response, http.StatusBadRequest, "INVALID_REQUEST",
			fmt.Sprintf("invalid thumbnail request: %v", err))
		return
	}
	if input.Width < 1 || input.Width > maxThumbnailDimension ||
		input.Height < 1 || input.Height > maxThumbnailDimension {
		writeError(response, http.StatusBadRequest, "INVALID_DIMENSION",
			fmt.Sprintf("thumbnail dimensions must be between 1 and %d", maxThumbnailDimension))
		return
	}
	if message := validateThumbnailRequest(input); message != "" {
		writeError(response, http.StatusBadRequest, "INVALID_REQUEST", message)
		return
	}

	spec := imageproc.Spec{
		Width: input.Width, Height: input.Height, Fit: input.Fit,
		Format: input.Format, Quality: input.Quality,
	}
	var generated imageproc.Output
	result, err := handler.cache.GetOrCreate(
		input.Path,
		spec.TransformID(),
		extensionForFormat(input.Format),
		func() ([]byte, error) {
			var err error
			generated, err = imageproc.TransformFile(input.Path, spec)
			return generated.Data, err
		},
	)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			writeError(response, http.StatusNotFound, "IMAGE_NOT_FOUND", "image does not exist")
			return
		}
		if errors.Is(err, cache.ErrCache) {
			writeError(response, http.StatusInternalServerError, "CACHE_ERROR",
				"thumbnail cache is unavailable")
			return
		}
		if errors.Is(err, os.ErrPermission) {
			writeError(response, http.StatusForbidden, "PERMISSION_DENIED",
				"image is not readable")
			return
		}
		if errors.Is(err, imageproc.ErrUnsupportedFormat) {
			writeError(response, http.StatusUnsupportedMediaType, "UNSUPPORTED_FORMAT",
				"image format is not supported")
			return
		}
		if errors.Is(err, imageproc.ErrDecodeFailed) {
			writeError(response, http.StatusUnprocessableEntity, "DECODE_FAILED",
				"image could not be decoded")
			return
		}
		writeError(response, http.StatusInternalServerError, "INTERNAL_ERROR",
			"thumbnail generation failed")
		return
	}

	contentType := generated.ContentType
	if contentType == "" {
		contentType = contentTypeForFormat(input.Format)
	}
	etag := `"` + result.Key + `"`
	response.Header().Set("Content-Type", contentType)
	response.Header().Set("ETag", etag)
	response.Header().Set("X-Rimg-Key", result.Key)
	if result.Hit {
		response.Header().Set("X-Rimg-Cache", "HIT")
	} else {
		response.Header().Set("X-Rimg-Cache", "MISS")
	}
	if request.Header.Get("If-None-Match") == etag {
		response.Header().Set("X-Rimg-Not-Modified", "true")
		response.WriteHeader(http.StatusOK)
		return
	}
	response.WriteHeader(http.StatusOK)
	_, _ = response.Write(result.Data)
}

func validateThumbnailRequest(input thumbnailRequest) string {
	if input.Path == "" {
		return "image path is required"
	}
	if len(input.Path) > maxPathLength {
		return fmt.Sprintf("image path exceeds %d bytes", maxPathLength)
	}
	if input.Fit != "contain" {
		return "fit must be contain"
	}
	if input.Format != "jpeg" && input.Format != "png" {
		return "format must be jpeg or png"
	}
	if input.Quality < 1 || input.Quality > 100 {
		return "quality must be between 1 and 100"
	}
	return ""
}

func writeError(response http.ResponseWriter, status int, code, message string) {
	response.Header().Set("Content-Type", "application/json")
	response.WriteHeader(status)
	_ = json.NewEncoder(response).Encode(errorResponse{
		Error: protocolError{Code: code, Message: message},
	})
}

func ensureJSONEOF(decoder *json.Decoder) error {
	var extra any
	if err := decoder.Decode(&extra); err != io.EOF {
		if err == nil {
			return fmt.Errorf("multiple JSON values")
		}
		return err
	}
	return nil
}

func extensionForFormat(format string) string {
	if format == "png" {
		return ".png"
	}
	return ".jpg"
}

func contentTypeForFormat(format string) string {
	if format == "png" {
		return "image/png"
	}
	return "image/jpeg"
}

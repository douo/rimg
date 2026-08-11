package api

import (
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"runtime"

	"github.com/douo/rimg/server/internal/cache"
	"github.com/douo/rimg/server/internal/imageproc"
	"github.com/douo/rimg/server/internal/protocol"
)

const (
	maxRequestBody        = 1 << 20
	maxThumbnailDimension = 2048
	maxPreviewDimension   = 4096
	maxPathLength         = 4096
	maxPrepareBatch       = 1000
)

type Options struct {
	CacheDir       string
	PrepareWorkers int
}

type handler struct {
	cache        *cache.Store
	prepareQueue chan prepareJob
}

type prepareJob struct {
	path string
	spec imageproc.Spec
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
	workers := options.PrepareWorkers
	if workers <= 0 {
		workers = min(runtime.NumCPU(), 8)
	}
	handler := &handler{
		cache:        cache.NewStore(options.CacheDir),
		prepareQueue: make(chan prepareJob, maxPrepareBatch),
	}
	for range workers {
		go handler.runPrepareWorker()
	}
	mux := http.NewServeMux()
	mux.HandleFunc("GET /v1/health", handleHealth)
	mux.HandleFunc("POST /v1/thumb", handler.handleThumbnail)
	mux.HandleFunc("POST /v1/preview", handler.handlePreview)
	mux.HandleFunc("POST /v1/prepare", handler.handlePrepare)
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
			Prepare: true,
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

type previewRequest struct {
	Path      string `json:"path"`
	MaxWidth  int    `json:"max_width"`
	MaxHeight int    `json:"max_height"`
	Format    string `json:"format"`
	Quality   int    `json:"quality"`
}

type prepareRequest struct {
	Files     []string `json:"files"`
	Thumbnail struct {
		Width   int    `json:"width"`
		Height  int    `json:"height"`
		Format  string `json:"format"`
		Quality int    `json:"quality"`
	} `json:"thumbnail"`
}

type prepareResponse struct {
	Accepted int `json:"accepted"`
	Cached   int `json:"cached"`
	Queued   int `json:"queued"`
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
		Kind:  "thumb",
		Width: input.Width, Height: input.Height, Fit: input.Fit,
		Format: input.Format, Quality: input.Quality,
	}
	handler.handleTransform(response, request, input.Path, spec)
}

func (handler *handler) handlePreview(response http.ResponseWriter, request *http.Request) {
	var input previewRequest
	decoder := json.NewDecoder(http.MaxBytesReader(response, request.Body, maxRequestBody))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&input); err != nil {
		writeError(response, http.StatusBadRequest, "INVALID_REQUEST",
			fmt.Sprintf("invalid preview request: %v", err))
		return
	}
	if err := ensureJSONEOF(decoder); err != nil {
		writeError(response, http.StatusBadRequest, "INVALID_REQUEST",
			fmt.Sprintf("invalid preview request: %v", err))
		return
	}
	if input.MaxWidth < 1 || input.MaxWidth > maxPreviewDimension ||
		input.MaxHeight < 1 || input.MaxHeight > maxPreviewDimension {
		writeError(response, http.StatusBadRequest, "INVALID_DIMENSION",
			fmt.Sprintf("preview dimensions must be between 1 and %d", maxPreviewDimension))
		return
	}
	if message := validateTransformRequest(input.Path, "contain", input.Format, input.Quality); message != "" {
		writeError(response, http.StatusBadRequest, "INVALID_REQUEST", message)
		return
	}
	handler.handleTransform(response, request, input.Path, imageproc.Spec{
		Kind: "preview", Width: input.MaxWidth, Height: input.MaxHeight,
		Fit: "contain", Format: input.Format, Quality: input.Quality,
	})
}

func (handler *handler) handlePrepare(response http.ResponseWriter, request *http.Request) {
	var input prepareRequest
	decoder := json.NewDecoder(http.MaxBytesReader(response, request.Body, maxRequestBody))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&input); err != nil {
		writeError(response, http.StatusBadRequest, "INVALID_REQUEST",
			fmt.Sprintf("invalid prepare request: %v", err))
		return
	}
	if err := ensureJSONEOF(decoder); err != nil {
		writeError(response, http.StatusBadRequest, "INVALID_REQUEST",
			fmt.Sprintf("invalid prepare request: %v", err))
		return
	}
	if len(input.Files) < 1 || len(input.Files) > maxPrepareBatch {
		writeError(response, http.StatusBadRequest, "INVALID_REQUEST",
			fmt.Sprintf("prepare files must contain between 1 and %d paths", maxPrepareBatch))
		return
	}
	if input.Thumbnail.Width < 1 || input.Thumbnail.Width > maxThumbnailDimension ||
		input.Thumbnail.Height < 1 || input.Thumbnail.Height > maxThumbnailDimension {
		writeError(response, http.StatusBadRequest, "INVALID_DIMENSION",
			fmt.Sprintf("thumbnail dimensions must be between 1 and %d", maxThumbnailDimension))
		return
	}
	if message := validateTransformRequest(
		input.Files[0], "contain", input.Thumbnail.Format, input.Thumbnail.Quality,
	); message != "" {
		writeError(response, http.StatusBadRequest, "INVALID_REQUEST", message)
		return
	}
	for _, path := range input.Files {
		if path == "" || len(path) > maxPathLength {
			writeError(response, http.StatusBadRequest, "INVALID_REQUEST",
				"prepare contains an invalid image path")
			return
		}
	}

	spec := imageproc.Spec{
		Kind: "thumb", Width: input.Thumbnail.Width, Height: input.Thumbnail.Height,
		Fit: "contain", Format: input.Thumbnail.Format, Quality: input.Thumbnail.Quality,
	}
	result := prepareResponse{}
	for _, path := range input.Files {
		_, found, err := handler.cache.Lookup(
			path, spec.TransformID(), extensionForFormat(spec.Format),
		)
		if err == nil && found {
			result.Cached++
			result.Accepted++
			continue
		}
		select {
		case handler.prepareQueue <- prepareJob{path: path, spec: spec}:
			result.Queued++
			result.Accepted++
		default:
		}
	}
	response.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(response).Encode(result)
}

func (handler *handler) runPrepareWorker() {
	for job := range handler.prepareQueue {
		_, _ = handler.cache.GetOrCreate(
			job.path,
			job.spec.TransformID(),
			extensionForFormat(job.spec.Format),
			func() ([]byte, error) {
				output, err := imageproc.TransformFile(job.path, job.spec)
				return output.Data, err
			},
		)
	}
}

func (handler *handler) handleTransform(
	response http.ResponseWriter,
	request *http.Request,
	path string,
	spec imageproc.Spec,
) {
	var generated imageproc.Output
	result, err := handler.cache.GetOrCreate(
		path,
		spec.TransformID(),
		extensionForFormat(spec.Format),
		func() ([]byte, error) {
			var err error
			generated, err = imageproc.TransformFile(path, spec)
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
		contentType = contentTypeForFormat(spec.Format)
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
	return validateTransformRequest(
		input.Path, input.Fit, input.Format, input.Quality,
	)
}

func validateTransformRequest(path, fit, format string, quality int) string {
	if path == "" {
		return "image path is required"
	}
	if len(path) > maxPathLength {
		return fmt.Sprintf("image path exceeds %d bytes", maxPathLength)
	}
	if fit != "contain" {
		return "fit must be contain"
	}
	if format != "jpeg" && format != "png" {
		return "format must be jpeg or png"
	}
	if quality < 1 || quality > 100 {
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

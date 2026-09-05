package server

import (
	"context"
	"errors"
	"fmt"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"time"
)

type Options struct {
	SocketPath string
	CacheDir   string
	Handler    http.Handler
}

func Serve(ctx context.Context, options Options) error {
	if options.SocketPath == "" {
		return errors.New("socket path is required")
	}
	if options.Handler == nil {
		return errors.New("HTTP handler is required")
	}

	if options.CacheDir != "" {
		if err := os.MkdirAll(options.CacheDir, 0o700); err != nil {
			return fmt.Errorf("create cache directory: %w", err)
		}
	}
	if err := os.MkdirAll(filepath.Dir(options.SocketPath), 0o700); err != nil {
		return fmt.Errorf("create socket directory: %w", err)
	}

	listener, err := net.Listen("unix", options.SocketPath)
	if err != nil {
		return fmt.Errorf("listen on Unix socket: %w", err)
	}
	defer listener.Close()
	defer os.Remove(options.SocketPath)
	if err := os.Chmod(options.SocketPath, 0o600); err != nil {
		return fmt.Errorf("set Unix socket permissions: %w", err)
	}

	httpServer := &http.Server{
		Handler:           options.Handler,
		ReadHeaderTimeout: 5 * time.Second,
		MaxHeaderBytes:    64 << 10,
	}
	serveResult := make(chan error, 1)
	go func() {
		serveResult <- httpServer.Serve(listener)
	}()

	select {
	case err := <-serveResult:
		if errors.Is(err, http.ErrServerClosed) {
			return nil
		}
		return err
	case <-ctx.Done():
		shutdownCtx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
		defer cancel()
		if err := httpServer.Shutdown(shutdownCtx); err != nil {
			return fmt.Errorf("shut down HTTP server: %w", err)
		}
		err := <-serveResult
		if err != nil && !errors.Is(err, http.ErrServerClosed) {
			return err
		}
		return nil
	}
}

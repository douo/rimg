package main

import (
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"os"
	"os/signal"
	"time"

	"github.com/douo/rimg/server/internal/api"
	"github.com/douo/rimg/server/internal/cache"
	"github.com/douo/rimg/server/internal/protocol"
	rimgserver "github.com/douo/rimg/server/internal/server"
)

type versionResponse struct {
	Version  string `json:"version"`
	Protocol int    `json:"protocol"`
}

func main() {
	if len(os.Args) >= 2 && os.Args[1] == "version" {
		runVersion(os.Args[2:])
		return
	}
	if len(os.Args) >= 2 && os.Args[1] == "serve" {
		runServe(os.Args[2:])
		return
	}
	if len(os.Args) >= 2 && os.Args[1] == "prune" {
		runPrune(os.Args[2:])
		return
	}

	usage()
	os.Exit(2)
}

func runPrune(arguments []string) {
	flags := flag.NewFlagSet("prune", flag.ContinueOnError)
	flags.SetOutput(os.Stderr)
	cacheDir := flags.String("cache-dir", "", "persistent cache directory")
	maxAge := flags.Duration("max-age", 0, "maximum cache entry age")
	maxSizeBytes := flags.Int64("max-size-bytes", 0, "maximum total cache size in bytes")
	jsonOutput := flags.Bool("json", false, "write JSON result")
	if err := flags.Parse(arguments); err != nil {
		os.Exit(2)
	}
	if flags.NArg() != 0 || *cacheDir == "" || (*maxAge <= 0 && *maxSizeBytes <= 0) ||
		*maxAge < 0 || *maxSizeBytes < 0 {
		fmt.Fprintln(os.Stderr, "usage: rimgd prune --cache-dir PATH [--max-age DURATION] [--max-size-bytes N] [--json]")
		os.Exit(2)
	}

	result, err := cache.Prune(*cacheDir, cache.PruneOptions{
		MaxAge: *maxAge, MaxSizeBytes: *maxSizeBytes, Now: time.Now(),
	})
	if err != nil {
		fmt.Fprintf(os.Stderr, "rimgd: prune: %v\n", err)
		os.Exit(1)
	}
	if *jsonOutput {
		if err := json.NewEncoder(os.Stdout).Encode(result); err != nil {
			fmt.Fprintf(os.Stderr, "rimgd: write prune result: %v\n", err)
			os.Exit(1)
		}
		return
	}
	fmt.Printf("removed %d files, freed %d bytes, %d bytes remain\n",
		result.RemovedFiles, result.FreedBytes, result.RemainingBytes)
}

func runVersion(arguments []string) {
	if len(arguments) == 1 && arguments[0] == "--json" {
		if err := json.NewEncoder(os.Stdout).Encode(versionResponse{
			Version:  protocol.BinaryVersion,
			Protocol: protocol.Version,
		}); err != nil {
			fmt.Fprintf(os.Stderr, "rimgd: write version: %v\n", err)
			os.Exit(1)
		}
		return
	}
	usage()
	os.Exit(2)
}

func runServe(arguments []string) {
	flags := flag.NewFlagSet("serve", flag.ContinueOnError)
	flags.SetOutput(os.Stderr)
	socketPath := flags.String("socket", "", "Unix socket path")
	cacheDir := flags.String("cache-dir", "", "persistent cache directory")
	if err := flags.Parse(arguments); err != nil {
		os.Exit(2)
	}
	if flags.NArg() != 0 || *socketPath == "" || *cacheDir == "" {
		fmt.Fprintln(os.Stderr, "usage: rimgd serve --socket PATH --cache-dir PATH")
		os.Exit(2)
	}

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt)
	defer stop()
	if err := rimgserver.Serve(ctx, rimgserver.Options{
		SocketPath: *socketPath,
		CacheDir:   *cacheDir,
		Handler:    api.NewHandler(api.Options{CacheDir: *cacheDir}),
	}); err != nil {
		fmt.Fprintf(os.Stderr, "rimgd: serve: %v\n", err)
		os.Exit(1)
	}
}

func usage() {
	fmt.Fprintln(os.Stderr, "usage: rimgd version --json | serve --socket PATH --cache-dir PATH | prune --cache-dir PATH OPTIONS")
}

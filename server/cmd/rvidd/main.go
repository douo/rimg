package main

import (
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/douo/rimg/server/internal/media"
	"github.com/douo/rimg/server/internal/rvidprotocol"
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
	usage()
	os.Exit(2)
}

func runVersion(arguments []string) {
	if len(arguments) == 1 && arguments[0] == "--json" {
		if err := json.NewEncoder(os.Stdout).Encode(versionResponse{
			Version: rvidprotocol.BinaryVersion, Protocol: rvidprotocol.Version,
		}); err != nil {
			fmt.Fprintf(os.Stderr, "rvidd: write version: %v\n", err)
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
	authToken := flags.String("auth-token", "", "session token for media registration")
	tokenTTL := flags.Duration("token-idle-ttl", 24*time.Hour, "idle lifetime of media URLs")
	maxOpen := flags.Int("max-open", 256, "maximum registered media files")
	exitOnStdinEOF := flags.Bool(
		"exit-on-stdin-eof", false, "stop serving when standard input closes",
	)
	if err := flags.Parse(arguments); err != nil {
		os.Exit(2)
	}
	if flags.NArg() != 0 || *socketPath == "" || *authToken == "" || *tokenTTL <= 0 || *maxOpen <= 0 {
		fmt.Fprintln(os.Stderr, "usage: rvidd serve --socket PATH --auth-token TOKEN [--token-idle-ttl DURATION] [--max-open N]")
		os.Exit(2)
	}

	handler, err := media.NewHandler(media.Options{
		AuthToken: *authToken, TokenTTL: *tokenTTL, MaxOpen: *maxOpen,
	})
	if err != nil {
		fmt.Fprintf(os.Stderr, "rvidd: configure server: %v\n", err)
		os.Exit(1)
	}

	signalContext, stop := signal.NotifyContext(
		context.Background(), os.Interrupt, syscall.SIGHUP, syscall.SIGTERM,
	)
	defer stop()
	ctx := signalContext
	if *exitOnStdinEOF {
		var cancel context.CancelFunc
		ctx, cancel = context.WithCancel(signalContext)
		defer cancel()
		go func() {
			_, _ = io.Copy(io.Discard, os.Stdin)
			cancel()
		}()
	}
	if err := rimgserver.Serve(ctx, rimgserver.Options{
		SocketPath: *socketPath,
		Handler:    handler,
	}); err != nil {
		fmt.Fprintf(os.Stderr, "rvidd: serve: %v\n", err)
		os.Exit(1)
	}
}

func usage() {
	fmt.Fprintln(os.Stderr, "usage: rvidd version --json | serve --socket PATH --auth-token TOKEN")
}

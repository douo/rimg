package main_test

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"net"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"testing"
	"time"
)

func TestServeUsesPrivateUnixSocketAndExitsOnStdinEOF(t *testing.T) {
	tempDir, err := os.MkdirTemp("/tmp", "rvid-test-")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.RemoveAll(tempDir) })
	binary := filepath.Join(tempDir, "rvidd")
	build := exec.Command("go", "build", "-o", binary, ".")
	if output, err := build.CombinedOutput(); err != nil {
		t.Fatalf("build rvidd: %v\n%s", err, output)
	}

	socket := filepath.Join(tempDir, "rvidd.sock")
	command := exec.Command(
		binary, "serve", "--socket", socket,
		"--auth-token", "0123456789abcdef0123456789abcdef",
		"--exit-on-stdin-eof",
	)
	stdin, err := command.StdinPipe()
	if err != nil {
		t.Fatal(err)
	}
	var processOutput bytes.Buffer
	command.Stdout = &processOutput
	command.Stderr = &processOutput
	if err := command.Start(); err != nil {
		t.Fatal(err)
	}
	processExited := false
	t.Cleanup(func() {
		if !processExited && command.Process != nil {
			_ = command.Process.Kill()
			_ = command.Wait()
		}
	})

	transport := &http.Transport{
		DialContext: func(ctx context.Context, _, _ string) (net.Conn, error) {
			return (&net.Dialer{}).DialContext(ctx, "unix", socket)
		},
	}
	client := &http.Client{Transport: transport, Timeout: time.Second}
	defer transport.CloseIdleConnections()

	var response *http.Response
	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		response, err = client.Get("http://rvid/v1/health")
		if err == nil {
			break
		}
		time.Sleep(20 * time.Millisecond)
	}
	if response == nil {
		t.Fatalf("health endpoint did not become ready: %v\n%s", err, processOutput.String())
	}
	defer response.Body.Close()
	var health struct {
		OK           bool `json:"ok"`
		Capabilities struct {
			MediaRange bool `json:"media_range"`
		} `json:"capabilities"`
	}
	if err := json.NewDecoder(response.Body).Decode(&health); err != nil {
		t.Fatal(err)
	}
	if !health.OK || !health.Capabilities.MediaRange {
		t.Fatalf("unexpected health response: %+v", health)
	}
	info, err := os.Stat(socket)
	if err != nil {
		t.Fatal(err)
	}
	if got := info.Mode().Perm(); got != 0o600 {
		t.Fatalf("socket permissions = %04o, want 0600", got)
	}

	if err := stdin.Close(); err != nil {
		t.Fatal(err)
	}
	waited := make(chan error, 1)
	go func() { waited <- command.Wait() }()
	select {
	case err := <-waited:
		processExited = true
		if err != nil {
			t.Fatalf("rvidd exit: %v\n%s", err, processOutput.String())
		}
	case <-time.After(3 * time.Second):
		t.Fatal("rvidd did not exit after stdin EOF")
	}
	if _, err := os.Stat(socket); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("socket remains after shutdown: %v", err)
	}
}

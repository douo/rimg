package main_test

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"syscall"
	"testing"
	"time"
)

func TestServeExposesHealthOnPrivateUnixSocketAndCleansUpAfterSIGTERM(t *testing.T) {
	testServeExposesHealthOnPrivateUnixSocketAndCleansUp(t, syscall.SIGTERM, false)
}

func TestServeExposesHealthOnPrivateUnixSocketAndCleansUpAfterSIGHUP(t *testing.T) {
	testServeExposesHealthOnPrivateUnixSocketAndCleansUp(t, syscall.SIGHUP, false)
}

func TestServeExitsAndCleansUpAfterStdinEOF(t *testing.T) {
	testServeExposesHealthOnPrivateUnixSocketAndCleansUp(t, nil, true)
}

func testServeExposesHealthOnPrivateUnixSocketAndCleansUp(
	t *testing.T,
	shutdownSignal os.Signal,
	exitOnStdinEOF bool,
) {
	t.Helper()
	tempDir, err := os.MkdirTemp("/tmp", "rimg-test-")
	if err != nil {
		t.Fatalf("create short temp directory: %v", err)
	}
	t.Cleanup(func() { _ = os.RemoveAll(tempDir) })
	binary := filepath.Join(tempDir, "rimgd")
	build := exec.Command("go", "build", "-o", binary, ".")
	if output, err := build.CombinedOutput(); err != nil {
		t.Fatalf("build rimgd: %v\n%s", err, output)
	}

	socket := filepath.Join(tempDir, "rimgd.sock")
	cacheDir := filepath.Join(tempDir, "cache")
	arguments := []string{"serve", "--socket", socket, "--cache-dir", cacheDir}
	if exitOnStdinEOF {
		arguments = append(arguments, "--exit-on-stdin-eof")
	}
	command := exec.Command(binary, arguments...)
	var processOutput bytes.Buffer
	command.Stdout = &processOutput
	command.Stderr = &processOutput
	var stdin io.WriteCloser
	if exitOnStdinEOF {
		stdin, err = command.StdinPipe()
		if err != nil {
			t.Fatalf("create rimgd stdin pipe: %v", err)
		}
	}
	if err := command.Start(); err != nil {
		t.Fatalf("start rimgd: %v", err)
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
		var err error
		response, err = client.Get("http://rimg/v1/health")
		if err == nil {
			break
		}
		time.Sleep(20 * time.Millisecond)
	}
	if response == nil {
		t.Fatalf("health endpoint did not become ready\n%s", processOutput.String())
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK {
		t.Fatalf("health status = %d, want 200", response.StatusCode)
	}

	var health struct {
		OK           bool   `json:"ok"`
		Protocol     int    `json:"protocol"`
		Version      string `json:"version"`
		PID          int    `json:"pid"`
		Capabilities struct {
			Decode  []string `json:"decode"`
			Encode  []string `json:"encode"`
			Prepare bool     `json:"prepare"`
		} `json:"capabilities"`
	}
	if err := json.NewDecoder(response.Body).Decode(&health); err != nil {
		t.Fatalf("decode health response: %v", err)
	}
	if !health.OK || health.Protocol != 1 || health.Version != "0.1.0" {
		t.Fatalf("unexpected health response: %+v", health)
	}
	if health.PID != command.Process.Pid {
		t.Fatalf("health pid = %d, process pid = %d", health.PID, command.Process.Pid)
	}
	if got := fmt.Sprint(health.Capabilities.Decode); got != "[jpeg png webp]" {
		t.Fatalf("decode capabilities = %s", got)
	}
	if got := fmt.Sprint(health.Capabilities.Encode); got != "[jpeg png]" {
		t.Fatalf("encode capabilities = %s", got)
	}
	if health.Capabilities.Prepare {
		t.Fatal("prepare capability is true before /v1/prepare is implemented")
	}

	info, err := os.Stat(socket)
	if err != nil {
		t.Fatalf("stat socket: %v", err)
	}
	if permissions := info.Mode().Perm(); permissions != 0o600 {
		t.Fatalf("socket permissions = %04o, want 0600", permissions)
	}

	if exitOnStdinEOF {
		if err := stdin.Close(); err != nil {
			t.Fatalf("close rimgd stdin: %v", err)
		}
	} else if err := command.Process.Signal(shutdownSignal); err != nil {
		t.Fatalf("signal rimgd with %v: %v", shutdownSignal, err)
	}
	waited := make(chan error, 1)
	go func() { waited <- command.Wait() }()
	select {
	case err := <-waited:
		processExited = true
		if err != nil {
			t.Fatalf("rimgd exit: %v\n%s", err, processOutput.String())
		}
	case <-time.After(3 * time.Second):
		t.Fatalf("rimgd did not exit after signal %v (stdin EOF: %t)",
			shutdownSignal, exitOnStdinEOF)
	}

	if _, err := os.Stat(socket); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("socket remains after shutdown: %v", err)
	}
	if _, err := os.Stat(cacheDir); err != nil {
		t.Fatalf("cache directory was not created: %v", err)
	}
}

package main_test

import (
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"testing"
	"time"
)

func TestPruneCommandEnforcesMaxAgeAndTotalSize(t *testing.T) {
	tempDir := t.TempDir()
	cacheDir := filepath.Join(tempDir, "cache")
	if err := os.MkdirAll(cacheDir, 0o700); err != nil {
		t.Fatalf("create cache directory: %v", err)
	}
	now := time.Now()
	old := writeCacheFixture(t, cacheDir, "old.jpg", 10, now.Add(-48*time.Hour))
	recentOlder := writeCacheFixture(t, cacheDir, "recent-older.jpg", 20, now.Add(-2*time.Hour))
	newest := writeCacheFixture(t, cacheDir, "newest.jpg", 30, now.Add(-time.Hour))

	binary := filepath.Join(tempDir, "rimgd")
	build := exec.Command("go", "build", "-o", binary, ".")
	if output, err := build.CombinedOutput(); err != nil {
		t.Fatalf("build rimgd: %v\n%s", err, output)
	}
	command := exec.Command(binary,
		"prune",
		"--cache-dir", cacheDir,
		"--max-age", "24h",
		"--max-size-bytes", "40",
		"--json",
	)
	output, err := command.CombinedOutput()
	if err != nil {
		t.Fatalf("rimgd prune failed: %v\n%s", err, output)
	}
	var result struct {
		RemovedFiles   int   `json:"removed_files"`
		FreedBytes     int64 `json:"freed_bytes"`
		RemainingBytes int64 `json:"remaining_bytes"`
	}
	if err := json.Unmarshal(output, &result); err != nil {
		t.Fatalf("decode prune result: %v\n%s", err, output)
	}
	if result.RemovedFiles != 2 || result.FreedBytes != 30 || result.RemainingBytes != 30 {
		t.Fatalf("unexpected prune result: %+v", result)
	}
	if _, err := os.Stat(old); !os.IsNotExist(err) {
		t.Fatalf("old entry was not removed: %v", err)
	}
	if _, err := os.Stat(recentOlder); !os.IsNotExist(err) {
		t.Fatalf("oldest entry above size limit was not removed: %v", err)
	}
	if _, err := os.Stat(newest); err != nil {
		t.Fatalf("newest entry was removed: %v", err)
	}
}

func writeCacheFixture(
	t *testing.T,
	directory string,
	name string,
	size int,
	mtime time.Time,
) string {
	t.Helper()
	path := filepath.Join(directory, name)
	if err := os.WriteFile(path, make([]byte, size), 0o600); err != nil {
		t.Fatalf("write cache fixture: %v", err)
	}
	if err := os.Chtimes(path, mtime, mtime); err != nil {
		t.Fatalf("set cache fixture time: %v", err)
	}
	return path
}

package cache

import (
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"os"
	"path/filepath"
)

const formatVersion = "rimg-cache-v1"

var ErrCache = errors.New("cache operation failed")

type Result struct {
	Key  string
	Data []byte
	Hit  bool
	Path string
}

type Store struct {
	directory string
}

func NewStore(directory string) *Store {
	return &Store{directory: directory}
}

func (store *Store) GetOrCreate(
	sourcePath string,
	transform string,
	extension string,
	generate func() ([]byte, error),
) (Result, error) {
	lookup, found, err := store.Lookup(sourcePath, transform, extension)
	if err != nil {
		return Result{}, err
	}
	if found {
		return lookup, nil
	}

	data, err := generate()
	if err != nil {
		return Result{}, err
	}
	if err := writeAtomically(lookup.Path, data); err != nil {
		return Result{}, fmt.Errorf("%w: %v", ErrCache, err)
	}
	lookup.Data = data
	return lookup, nil
}

func (store *Store) Lookup(
	sourcePath string,
	transform string,
	extension string,
) (Result, bool, error) {
	key, err := sourceKey(sourcePath, transform)
	if err != nil {
		return Result{}, false, err
	}
	cachePath := filepath.Join(store.directory, key[:2], key+extension)
	data, err := os.ReadFile(cachePath)
	if err == nil {
		return Result{Key: key, Data: data, Hit: true, Path: cachePath}, true, nil
	}
	if !errors.Is(err, os.ErrNotExist) {
		return Result{}, false, fmt.Errorf("%w: read cache entry: %v", ErrCache, err)
	}
	return Result{Key: key, Hit: false, Path: cachePath}, false, nil
}

func sourceKey(sourcePath string, transform string) (string, error) {
	canonicalPath, err := filepath.EvalSymlinks(sourcePath)
	if err != nil {
		return "", fmt.Errorf("resolve source path: %w", err)
	}
	canonicalPath, err = filepath.Abs(canonicalPath)
	if err != nil {
		return "", fmt.Errorf("make source path absolute: %w", err)
	}
	info, err := os.Stat(canonicalPath)
	if err != nil {
		return "", fmt.Errorf("stat source: %w", err)
	}

	payload := fmt.Sprintf("%s\x00%s\x00%d\x00%d\x00%s",
		formatVersion,
		canonicalPath,
		info.Size(),
		info.ModTime().UnixNano(),
		transform,
	)
	digest := sha256.Sum256([]byte(payload))
	return hex.EncodeToString(digest[:]), nil
}

func writeAtomically(path string, data []byte) error {
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return fmt.Errorf("create cache shard: %w", err)
	}
	temporary, err := os.CreateTemp(filepath.Dir(path), filepath.Base(path)+".tmp.*")
	if err != nil {
		return fmt.Errorf("create temporary cache entry: %w", err)
	}
	temporaryPath := temporary.Name()
	defer os.Remove(temporaryPath)

	if err := temporary.Chmod(0o600); err != nil {
		_ = temporary.Close()
		return fmt.Errorf("set cache entry permissions: %w", err)
	}
	if _, err := temporary.Write(data); err != nil {
		_ = temporary.Close()
		return fmt.Errorf("write cache entry: %w", err)
	}
	if err := temporary.Close(); err != nil {
		return fmt.Errorf("close cache entry: %w", err)
	}
	if err := os.Rename(temporaryPath, path); err != nil {
		return fmt.Errorf("commit cache entry: %w", err)
	}
	return nil
}

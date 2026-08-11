package cache

import (
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"sort"
	"time"
)

type PruneOptions struct {
	MaxAge       time.Duration
	MaxSizeBytes int64
	Now          time.Time
}

type PruneResult struct {
	RemovedFiles   int   `json:"removed_files"`
	FreedBytes     int64 `json:"freed_bytes"`
	RemainingBytes int64 `json:"remaining_bytes"`
}

type cacheEntry struct {
	path    string
	size    int64
	modTime time.Time
}

func Prune(directory string, options PruneOptions) (PruneResult, error) {
	if options.Now.IsZero() {
		options.Now = time.Now()
	}
	entries, err := listEntries(directory)
	if err != nil {
		return PruneResult{}, err
	}

	result := PruneResult{}
	remaining := make([]cacheEntry, 0, len(entries))
	for _, entry := range entries {
		if options.MaxAge > 0 && options.Now.Sub(entry.modTime) > options.MaxAge {
			if err := os.Remove(entry.path); err != nil {
				return PruneResult{}, fmt.Errorf("remove expired cache entry: %w", err)
			}
			result.RemovedFiles++
			result.FreedBytes += entry.size
			continue
		}
		remaining = append(remaining, entry)
		result.RemainingBytes += entry.size
	}

	if options.MaxSizeBytes > 0 && result.RemainingBytes > options.MaxSizeBytes {
		sort.Slice(remaining, func(i, j int) bool {
			return remaining[i].modTime.Before(remaining[j].modTime)
		})
		for _, entry := range remaining {
			if result.RemainingBytes <= options.MaxSizeBytes {
				break
			}
			if err := os.Remove(entry.path); err != nil {
				return PruneResult{}, fmt.Errorf("remove cache entry above size limit: %w", err)
			}
			result.RemovedFiles++
			result.FreedBytes += entry.size
			result.RemainingBytes -= entry.size
		}
	}
	return result, nil
}

func listEntries(directory string) ([]cacheEntry, error) {
	entries := make([]cacheEntry, 0)
	err := filepath.WalkDir(directory, func(path string, entry fs.DirEntry, walkErr error) error {
		if walkErr != nil {
			return walkErr
		}
		if !entry.Type().IsRegular() {
			return nil
		}
		info, err := entry.Info()
		if err != nil {
			return err
		}
		entries = append(entries, cacheEntry{
			path: path, size: info.Size(), modTime: info.ModTime(),
		})
		return nil
	})
	if err != nil {
		return nil, fmt.Errorf("scan cache directory: %w", err)
	}
	return entries, nil
}

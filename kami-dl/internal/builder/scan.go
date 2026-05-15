package builder

import (
	"context"
	"path/filepath"
	"strings"
)

// ScanLibrary returns all gallery IDs in the library directory.
// It assumes every CBZ is named {id}.cbz at the top level.
func (b *Builder) ScanLibrary(ctx context.Context) ([]string, error) {
	matches, err := filepath.Glob(filepath.Join(b.libraryPath, "*.cbz"))
	if err != nil {
		return nil, err
	}

	ids := make([]string, 0, len(matches))
	for _, path := range matches {
		if ctx.Err() != nil {
			return ids, ctx.Err()
		}
		stem := filepath.Base(path)
		stem = strings.TrimSuffix(stem, filepath.Ext(stem))
		ids = append(ids, stem)
	}

	return ids, nil
}
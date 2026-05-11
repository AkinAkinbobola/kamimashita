package downloader

import (
	"context"
	"fmt"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"github.com/AkinAkinbobola/kamimashita/kami-dl/internal/nhentai"
)

const (
	pageWorkers    = 10
	maxPageRetries = 3
)

type DownloadResult struct {
	Path  string
	Error error
}

type downloadJob struct {
	page    nhentai.Page
	index   int
	destDir string
}

func downloadPages(
	ctx context.Context,
	client *nhentai.Client,
	pages []nhentai.Page,
	destDir string,
	workers int,
	progress func(current, total int),
) ([]string, error) {
	if len(pages) == 0 {
		return nil, nil
	}
	if workers <= 0 {
		workers = pageWorkers
	}

	runCtx, cancel := context.WithCancel(ctx)
	defer cancel()

	jobs := make(chan downloadJob, len(pages))
	results := make(chan DownloadResult, len(pages))

	var wg sync.WaitGroup
	for i := 0; i < workers; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			worker(runCtx, client, jobs, results)
		}()
	}

	for i, page := range pages {
		select {
		case jobs <- downloadJob{page: page, index: i, destDir: destDir}:
		case <-runCtx.Done():
			return nil, runCtx.Err()
		}
	}
	close(jobs)

	go func() {
		wg.Wait()
		close(results)
	}()

	completed := 0
	total := len(pages)
	paths := make([]string, 0, len(pages))
	for completed < total {
		select {
		case <-runCtx.Done():
			return nil, runCtx.Err()
		case result, ok := <-results:
			if !ok {
				completed = total
				break
			}
			if result.Error != nil {
				cancel()
				return nil, result.Error
			}
			completed++
			if result.Path != "" && !strings.HasSuffix(strings.ToLower(result.Path), ".part") {
				paths = append(paths, result.Path)
			}
			if progress != nil {
				progress(completed, total)
			}
		}
	}

	files, err := filepath.Glob(filepath.Join(destDir, "*"))
	if err != nil {
		return nil, err
	}
	filtered := make([]string, 0, len(files))
	for _, path := range files {
		if strings.HasSuffix(strings.ToLower(path), ".part") {
			continue
		}
		filtered = append(filtered, path)
	}
	if len(filtered) != len(pages) {
		return nil, fmt.Errorf("expected %d completed pages but found %d", len(pages), len(filtered))
	}
	return filtered, nil
}

func worker(ctx context.Context, client *nhentai.Client, jobs <-chan downloadJob, results chan<- DownloadResult) {
	for {
		if err := ctx.Err(); err != nil {
			return
		}

		select {
		case job, ok := <-jobs:
			if !ok {
				return
			}
			path, err := downloadPageWithRetry(ctx, client, job)
			select {
			case results <- DownloadResult{Path: path, Error: err}:
			case <-ctx.Done():
				return
			}
		case <-ctx.Done():
			return
		}
	}
}

func downloadPageWithRetry(ctx context.Context, client *nhentai.Client, job downloadJob) (string, error) {
	var lastErr error
	backoffs := []time.Duration{time.Second, 2 * time.Second, 4 * time.Second}
	for attempt := 1; attempt <= maxPageRetries; attempt++ {
		path, err := downloadPage(ctx, client, job)
		if err == nil {
			return path, nil
		}
		if ctx.Err() != nil {
			return "", ctx.Err()
		}
		lastErr = err
		if attempt < maxPageRetries {
			if err := sleepWithContext(ctx, backoffs[attempt-1]); err != nil {
				return "", err
			}
		}
	}
	return "", fmt.Errorf("failed to download page %d after %d attempts: %w", job.page.Number, maxPageRetries, lastErr)
}

func downloadPage(ctx context.Context, client *nhentai.Client, job downloadJob) (string, error) {
	ext := filepath.Ext(job.page.Path)
	if ext == "" {
		ext = ".jpg"
	}
	filename := fmt.Sprintf("%03d%s", job.index+1, ext)
	filePath := filepath.Join(job.destDir, filename)

	if err := client.DownloadPage(ctx, job.page.Path, filePath); err != nil {
		return "", fmt.Errorf("failed to download page %d: %w", job.page.Number, err)
	}

	return filePath, nil
}

func sleepWithContext(ctx context.Context, wait time.Duration) error {
	if wait <= 0 {
		return nil
	}
	timer := time.NewTimer(wait)
	defer timer.Stop()

	select {
	case <-timer.C:
		return nil
	case <-ctx.Done():
		return ctx.Err()
	}
}

package nhentai

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"time"
)

const (
	APIBase                = "https://nhentai.net/api/v2"
	ThumbnailBase          = "https://t.nhentai.net"
	UserAgent              = "kami-dl/1.0 (github.com/AkinAkinbobola/kamimashita)"
	MaxRetries             = 3
	BackoffBase            = 2.0
	MetadataRequestTimeout = 10 * time.Second
	PageDownloadTimeout    = 30 * time.Second
)

var (
	ErrGalleryNotFound   = errors.New("gallery not found")
	ErrMaxRetriesReached = errors.New("max retries exceeded")
	imageHosts           = []string{
		"https://i1.nhentai.net",
		"https://i2.nhentai.net",
		"https://i3.nhentai.net",
		"https://i4.nhentai.net",
		"https://i5.nhentai.net",
		"https://i6.nhentai.net",
		"https://i7.nhentai.net",
	}
)

type searchAPIResponse struct {
	Results []searchAPIItem `json:"results"`
	Result  []searchAPIItem `json:"result"`
	Total   int             `json:"total"`
	PerPage int             `json:"per_page"`
}

type searchAPIItem struct {
	ID            int           `json:"id"`
	EnglishTitle  string        `json:"english_title"`
	JapaneseTitle string        `json:"japanese_title"`
	Thumbnail     thumbnailPath `json:"thumbnail"`
	NumPages      int           `json:"num_pages"`
}

type thumbnailPath string

func (p *thumbnailPath) UnmarshalJSON(data []byte) error {
	var path string
	if err := json.Unmarshal(data, &path); err == nil {
		*p = thumbnailPath(path)
		return nil
	}

	var image Image
	if err := json.Unmarshal(data, &image); err != nil {
		return err
	}
	*p = thumbnailPath(image.Path)
	return nil
}

type Client struct {
	http   *http.Client
	apiKey string
}

func NewClient(apiKey string) *Client {
	transport := &http.Transport{
		Proxy:                 http.ProxyFromEnvironment,
		MaxIdleConns:          100,
		MaxIdleConnsPerHost:   20,
		MaxConnsPerHost:       20,
		IdleConnTimeout:       90 * time.Second,
		TLSHandshakeTimeout:   10 * time.Second,
		ExpectContinueTimeout: 1 * time.Second,
		DisableCompression:    true,
	}

	return &Client{
		http: &http.Client{
			Transport: transport,
			Timeout:   PageDownloadTimeout,
		},
		apiKey: strings.TrimSpace(apiKey),
	}
}

func (c *Client) FetchGallery(ctx context.Context, id string) (*Gallery, error) {
	requestCtx := contextOrBackground(ctx)
	url := fmt.Sprintf("%s/galleries/%s", APIBase, id)

	for attempt := 1; attempt <= MaxRetries; attempt++ {
		attemptCtx, cancel := context.WithTimeout(requestCtx, MetadataRequestTimeout)
		req, err := http.NewRequestWithContext(attemptCtx, http.MethodGet, url, nil)
		if err != nil {
			cancel()
			return nil, err
		}
		c.setRequestHeaders(req)

		resp, err := c.http.Do(req)
		if err != nil {
			cancel()
			if errors.Is(err, context.Canceled) || errors.Is(err, context.DeadlineExceeded) {
				return nil, err
			}
			return nil, err
		}

		switch resp.StatusCode {
		case http.StatusOK:
			var gallery Gallery
			err = json.NewDecoder(resp.Body).Decode(&gallery)
			resp.Body.Close()
			cancel()
			if err != nil {
				return nil, err
			}
			return &gallery, nil
		case http.StatusNotFound:
			resp.Body.Close()
			cancel()
			return nil, ErrGalleryNotFound
		case http.StatusTooManyRequests:
			wait := retryBackoff(attempt, resp.Header.Get("Retry-After"))
			resp.Body.Close()
			cancel()
			if attempt == MaxRetries {
				return nil, fmt.Errorf("%w after %d attempts", ErrMaxRetriesReached, MaxRetries)
			}
			log.Printf("[NHENTAI] Metadata fetch for %s hit 429; retrying in %s (attempt %d/%d)", id, wait, attempt, MaxRetries)
			if err := sleepWithContext(requestCtx, wait); err != nil {
				return nil, err
			}
		default:
			body, _ := io.ReadAll(io.LimitReader(resp.Body, 512))
			resp.Body.Close()
			cancel()
			if len(body) > 0 {
				return nil, fmt.Errorf("api returned status %d: %s", resp.StatusCode, strings.TrimSpace(string(body)))
			}
			return nil, fmt.Errorf("api returned status %d", resp.StatusCode)
		}
	}

	return nil, ErrMaxRetriesReached
}

func (c *Client) SearchGalleries(ctx context.Context, query string, page int) (*SearchResult, error) {
	requestCtx, cancel := context.WithTimeout(contextOrBackground(ctx), MetadataRequestTimeout)
	defer cancel()

	if page < 1 {
		page = 1
	}
	params := url.Values{}
	params.Set("query", query)
	params.Set("sort", "popular")
	params.Set("page", strconv.Itoa(page))

	req, err := http.NewRequestWithContext(requestCtx, http.MethodGet, APIBase+"/search?"+params.Encode(), nil)
	if err != nil {
		return nil, err
	}
	c.setRequestHeaders(req)

	resp, err := c.http.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		body, _ := io.ReadAll(io.LimitReader(resp.Body, 512))
		if len(body) > 0 {
			return nil, fmt.Errorf("api returned status %d: %s", resp.StatusCode, strings.TrimSpace(string(body)))
		}
		return nil, fmt.Errorf("api returned status %d", resp.StatusCode)
	}

	var payload searchAPIResponse
	if err := json.NewDecoder(resp.Body).Decode(&payload); err != nil {
		return nil, err
	}
	items := payload.Results
	if len(items) == 0 && len(payload.Result) > 0 {
		items = payload.Result
	}

	result := &SearchResult{
		Results: make([]SearchItem, 0, len(items)),
		Total:   payload.Total,
		PerPage: payload.PerPage,
	}
	for _, item := range items {
		title := strings.TrimSpace(item.EnglishTitle)
		if title == "" {
			title = strings.TrimSpace(item.JapaneseTitle)
		}
		result.Results = append(result.Results, SearchItem{
			ID:        item.ID,
			Title:     title,
			Thumbnail: string(item.Thumbnail),
			NumPages:  item.NumPages,
		})
	}

	return result, nil
}

func (c *Client) FetchThumbnail(ctx context.Context, path string) ([]byte, string, error) {
	requestCtx, cancel := context.WithTimeout(contextOrBackground(ctx), PageDownloadTimeout)
	defer cancel()

	req, err := http.NewRequestWithContext(requestCtx, http.MethodGet, ThumbnailBase+normalizePagePath(path), nil)
	if err != nil {
		return nil, "", err
	}
	c.setRequestHeaders(req)
	req.Header.Set("Referer", "https://nhentai.net/")

	resp, err := c.http.Do(req)
	if err != nil {
		return nil, "", err
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		return nil, "", fmt.Errorf("thumbnail returned status %d", resp.StatusCode)
	}

	body, err := io.ReadAll(resp.Body)
	if err != nil {
		return nil, "", err
	}
	return body, resp.Header.Get("Content-Type"), nil
}

func (c *Client) DownloadPage(ctx context.Context, path string, destPath string) error {
	candidates := buildPathCandidates(path)
	var lastErr error

	for _, candidate := range candidates {
		normalizedPath := normalizePagePath(candidate)
		if err := c.downloadFromHosts(ctx, normalizedPath, destPath); err == nil {
			return nil
		} else {
			lastErr = err
		}
	}

	if lastErr != nil {
		log.Printf("[NHENTAI] All image mirrors failed for %s: %v", path, lastErr)
		return fmt.Errorf("all mirrors failed: %w", lastErr)
	}
	return fmt.Errorf("failed to download page")
}

func (c *Client) downloadFromHosts(ctx context.Context, normalizedPath string, destPath string) error {
	requestCtx, cancel := context.WithCancel(contextOrBackground(ctx))
	defer cancel()

	_ = os.Remove(destPath)
	staleParts, _ := filepath.Glob(destPath + ".*.part")
	for _, path := range staleParts {
		_ = os.Remove(path)
	}

	type result struct {
		tempPath string
		err      error
	}

	results := make(chan result, len(imageHosts))
	var wg sync.WaitGroup

	for index, host := range imageHosts {
		wg.Add(1)
		go func(i int, imageHost string) {
			defer wg.Done()
			url := imageHost + normalizedPath
			tempPath := fmt.Sprintf("%s.%d.part", destPath, i)
			results <- result{tempPath: tempPath, err: c.downloadToTemp(requestCtx, url, tempPath)}
		}(index, host)
	}

	go func() {
		wg.Wait()
		close(results)
	}()

	var lastErr error
	for result := range results {
		if result.err == nil {
			cancel()
			for leftover := range results {
				if leftover.tempPath != result.tempPath {
					_ = os.Remove(leftover.tempPath)
				}
			}
			if err := os.Rename(result.tempPath, destPath); err != nil {
				_ = os.Remove(result.tempPath)
				return err
			}
			return nil
		}
		if result.tempPath != "" {
			_ = os.Remove(result.tempPath)
		}
		if !errors.Is(result.err, context.Canceled) {
			lastErr = result.err
		}
	}

	return lastErr
}

func (c *Client) downloadToTemp(ctx context.Context, url string, tempPath string) error {
	requestCtx, cancel := context.WithTimeout(ctx, PageDownloadTimeout)
	defer cancel()

	req, err := http.NewRequestWithContext(requestCtx, http.MethodGet, url, nil)
	if err != nil {
		return err
	}
	c.setRequestHeaders(req)
	req.Header.Set("Referer", "https://nhentai.net/")

	resp, err := c.http.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("download returned status %d", resp.StatusCode)
	}

	_ = os.Remove(tempPath)
	file, err := os.Create(tempPath)
	if err != nil {
		return err
	}

	_, copyErr := io.Copy(file, resp.Body)
	syncErr := file.Sync()
	closeErr := file.Close()
	if copyErr != nil {
		_ = os.Remove(tempPath)
		return copyErr
	}
	if syncErr != nil {
		_ = os.Remove(tempPath)
		return syncErr
	}
	if closeErr != nil {
		_ = os.Remove(tempPath)
		return closeErr
	}
	return nil
}

func (c *Client) setRequestHeaders(req *http.Request) {
	req.Header.Set("User-Agent", UserAgent)
	if c.apiKey != "" {
		req.Header.Set("Authorization", "Key "+c.apiKey)
	}
}

func contextOrBackground(ctx context.Context) context.Context {
	if ctx != nil {
		return ctx
	}
	return context.Background()
}

func buildPathCandidates(path string) []string {
	candidates := []string{path}
	dot := strings.LastIndex(path, ".")
	if dot == -1 {
		return candidates
	}

	base := path[:dot]
	seen := map[string]bool{path: true}
	for _, ext := range []string{".jpg", ".png", ".gif", ".webp"} {
		candidate := base + ext
		if !seen[candidate] {
			candidates = append(candidates, candidate)
			seen[candidate] = true
		}
	}

	return candidates
}

func normalizePagePath(path string) string {
	trimmed := strings.TrimSpace(path)
	if trimmed == "" {
		return "/"
	}
	if strings.HasPrefix(trimmed, "/") {
		return trimmed
	}
	return "/" + trimmed
}

func parseRetryAfter(value string) time.Duration {
	trimmed := strings.TrimSpace(value)
	if trimmed == "" {
		return 0
	}
	if seconds, err := strconv.Atoi(trimmed); err == nil {
		if seconds > 0 {
			return time.Duration(seconds) * time.Second
		}
		return 0
	}
	if retryTime, err := http.ParseTime(trimmed); err == nil {
		wait := time.Until(retryTime)
		if wait > 0 {
			return wait
		}
	}
	return 0
}

func retryBackoff(attempt int, retryAfter string) time.Duration {
	if wait := parseRetryAfter(retryAfter); wait > 0 {
		return wait
	}
	multiplier := 1 << uint(attempt-1)
	return time.Duration(BackoffBase*float64(multiplier)) * time.Second
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

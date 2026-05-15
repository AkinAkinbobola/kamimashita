package main

import (
	"context"
	"flag"
	"fmt"
	"io/fs"
	"log"
	"net/http"
	"os"
	"os/signal"
	"path/filepath"
	"strings"
	"sync"
	"syscall"
	"time"

	"github.com/AkinAkinbobola/kamimashita/kami-dl/internal/api"
	"github.com/AkinAkinbobola/kamimashita/kami-dl/internal/builder"
	"github.com/AkinAkinbobola/kamimashita/kami-dl/internal/downloader"
	"github.com/AkinAkinbobola/kamimashita/kami-dl/internal/nhentai"
)

const port = 8765

var recentLogs = newLogRingBuffer(200)

type logRingBuffer struct {
	mu    sync.Mutex
	lines []string
	next  int
	count int
}

func newLogRingBuffer(size int) *logRingBuffer {
	return &logRingBuffer{lines: make([]string, size)}
}

func (b *logRingBuffer) Add(line string) {
	line = strings.TrimRight(line, "\r\n")
	if line == "" {
		return
	}

	b.mu.Lock()
	defer b.mu.Unlock()

	b.lines[b.next] = line
	b.next = (b.next + 1) % len(b.lines)
	if b.count < len(b.lines) {
		b.count++
	}
}

func (b *logRingBuffer) Lines() []string {
	b.mu.Lock()
	defer b.mu.Unlock()

	lines := make([]string, 0, b.count)
	start := (b.next - b.count + len(b.lines)) % len(b.lines)
	for i := 0; i < b.count; i++ {
		lines = append(lines, b.lines[(start+i)%len(b.lines)])
	}
	return lines
}

type ringLogWriter struct {
	buffer *logRingBuffer
}

func (w ringLogWriter) Write(p []byte) (int, error) {
	written, err := os.Stderr.Write(p)
	for _, line := range strings.Split(string(p), "\n") {
		w.buffer.Add(line)
	}
	return written, err
}

func main() {
	log.SetOutput(ringLogWriter{buffer: recentLogs})

	output := flag.String("output", "", "Path to the LRR watch folder")
	apiKey := flag.String("api-key", "", "nhentai API key")
	flag.Parse()

	if *output == "" {
		log.Fatal("--output is required")
	}
	if err := os.MkdirAll(*output, 0755); err != nil {
		log.Fatal(err)
	}
	if err := removeTempCBZ(*output); err != nil {
		log.Fatal(err)
	}

	client := nhentai.NewClient(*apiKey)
	archiveBuilder := builder.New(*output)
	manager := downloader.NewManager(client, archiveBuilder, *output)

	runtimeCtx, cancelRuntime := context.WithCancel(context.Background())
	defer cancelRuntime()
	manager.Start(runtimeCtx)

	go func() {
    log.Printf("scanning library at %s", *output)
    ids, err := archiveBuilder.ScanLibrary(runtimeCtx)
    if err != nil && err != context.Canceled {
        log.Printf("library scan error: %v", err)
        return
    }
    manager.LoadOwned(ids)
    log.Printf("library scan complete: %d owned galleries loaded", len(ids))
	}()

	handlers := api.NewHandlers(manager, recentLogs.Lines)
	router := api.NewRouter(handlers)

	server := &http.Server{
		Addr:              fmt.Sprintf("127.0.0.1:%d", port),
		Handler:           router,
		ReadHeaderTimeout: 5 * time.Second,
		IdleTimeout:       60 * time.Second,
	}

	go func() {
		log.Printf("kami-dl listening on %s", server.Addr)
		if err := server.ListenAndServe(); err != nil && err != http.ErrServerClosed {
			log.Fatal(err)
		}
	}()

	quit := make(chan os.Signal, 1)
	signal.Notify(quit, syscall.SIGINT, syscall.SIGTERM)
	<-quit

	cancelRuntime()
	shutdownCtx, cancelShutdown := context.WithTimeout(context.Background(), time.Second)
	defer cancelShutdown()
	if err := server.Shutdown(shutdownCtx); err != nil {
		log.Printf("server shutdown error: %v", err)
	}
}

func removeTempCBZ(root string) error {
	return filepath.WalkDir(root, func(path string, d fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if d.IsDir() {
			return nil
		}
		if filepath.Ext(path) == ".cbz" && len(path) >= len(".tmp.cbz") && path[len(path)-len(".tmp.cbz"):] == ".tmp.cbz" {
			if removeErr := os.Remove(path); removeErr != nil && !os.IsNotExist(removeErr) {
				return removeErr
			}
		}
		return nil
	})
}

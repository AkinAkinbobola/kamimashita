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
	"syscall"
	"time"

	"github.com/AkinAkinbobola/kamimashita/kami-dl/internal/api"
	"github.com/AkinAkinbobola/kamimashita/kami-dl/internal/builder"
	"github.com/AkinAkinbobola/kamimashita/kami-dl/internal/downloader"
	"github.com/AkinAkinbobola/kamimashita/kami-dl/internal/nhentai"
)

const port = 8765

func main() {
	output := flag.String("output", "", "Path to the LRR watch folder")
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

	client := nhentai.NewClient()
	archiveBuilder := builder.New(*output)
	manager := downloader.NewManager(client, archiveBuilder, *output)

	runtimeCtx, cancelRuntime := context.WithCancel(context.Background())
	defer cancelRuntime()
	manager.Start(runtimeCtx)

	handlers := api.NewHandlers(manager)
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

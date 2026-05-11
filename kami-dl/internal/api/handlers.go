package api

import (
	"encoding/json"
	"fmt"
	"net/http"
	"regexp"
	"sort"
	"time"

	"github.com/AkinAkinbobola/kamimashita/kami-dl/internal/downloader"
	"github.com/AkinAkinbobola/kamimashita/kami-dl/internal/models"
)

var numericIDPattern = regexp.MustCompile(`^\d+$`)

type Handlers struct {
	manager *downloader.Manager
}

type queueRequest struct {
	IDs []string `json:"ids"`
}

func NewHandlers(manager *downloader.Manager) *Handlers {
	return &Handlers{manager: manager}
}

func (h *Handlers) Queue(w http.ResponseWriter, r *http.Request) {
	var req queueRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		http.Error(w, "invalid request body", http.StatusBadRequest)
		return
	}
	if len(req.IDs) == 0 {
		http.Error(w, "ids are required", http.StatusBadRequest)
		return
	}
	unique := dedupeIDs(req.IDs)
	for _, id := range unique {
		if !numericIDPattern.MatchString(id) {
			http.Error(w, fmt.Sprintf("invalid id: %s", id), http.StatusBadRequest)
			return
		}
	}
	if err := h.manager.Enqueue(unique); err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	writeJSON(w, http.StatusAccepted, map[string]any{"ids": unique, "count": len(unique)})
}

func (h *Handlers) Start(w http.ResponseWriter, r *http.Request) {
	queued := h.manager.StartPending()
	writeJSON(w, http.StatusOK, map[string]any{"queued": queued})
}

func (h *Handlers) Pause(w http.ResponseWriter, r *http.Request) {
	paused := h.manager.PauseDownloads()
	writeJSON(w, http.StatusOK, map[string]any{"paused": paused})
}

func (h *Handlers) Status(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, http.StatusOK, h.manager.StatusSnapshot())
}

func (h *Handlers) Jobs(w http.ResponseWriter, r *http.Request) {
	jobs := h.manager.ListJobs()
	writeJSON(w, http.StatusOK, jobs)
}

func (h *Handlers) ClearFinishedJobs(w http.ResponseWriter, r *http.Request) {
	cleared := h.manager.ClearFinished()
	writeJSON(w, http.StatusOK, map[string]any{"cleared": cleared})
}

func (h *Handlers) Progress(w http.ResponseWriter, r *http.Request) {
	flusher, ok := w.(http.Flusher)
	if !ok {
		http.Error(w, "streaming unsupported", http.StatusInternalServerError)
		return
	}

	w.Header().Set("Content-Type", "text/event-stream")
	w.Header().Set("Cache-Control", "no-cache")
	w.Header().Set("Connection", "keep-alive")

	progressCh, cleanup := h.manager.SubscribeProgress()
	defer cleanup()

	if snapshot := h.manager.CurrentProgress(); snapshot != nil {
		if err := writeSSE(w, *snapshot); err != nil {
			return
		}
		flusher.Flush()
	}

	keepAlive := time.NewTicker(20 * time.Second)
	defer keepAlive.Stop()

	for {
		select {
		case <-r.Context().Done():
			return
		case progress, ok := <-progressCh:
			if !ok {
				return
			}
			if err := writeSSE(w, progress); err != nil {
				return
			}
			flusher.Flush()
		case <-keepAlive.C:
			if _, err := fmt.Fprint(w, ": keepalive\n\n"); err != nil {
				return
			}
			flusher.Flush()
		}
	}
}

func writeSSE(w http.ResponseWriter, progress models.Progress) error {
	payload, err := json.Marshal(progress)
	if err != nil {
		return err
	}
	_, err = fmt.Fprintf(w, "data: %s\n\n", payload)
	return err
}

func writeJSON(w http.ResponseWriter, status int, payload any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(payload)
}

func dedupeIDs(ids []string) []string {
	seen := make(map[string]struct{}, len(ids))
	unique := make([]string, 0, len(ids))
	for _, id := range ids {
		if _, ok := seen[id]; ok {
			continue
		}
		seen[id] = struct{}{}
		unique = append(unique, id)
	}
	sort.Strings(unique)
	return unique
}

package downloader

import (
	"context"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"time"

	"github.com/AkinAkinbobola/kamimashita/kami-dl/internal/builder"
	"github.com/AkinAkinbobola/kamimashita/kami-dl/internal/models"
	"github.com/AkinAkinbobola/kamimashita/kami-dl/internal/nhentai"
)

const galleryWorkers = 3

type StatusSnapshot struct {
	Counts   map[models.JobStatus]int `json:"counts"`
	Jobs     []models.Job             `json:"jobs"`
	Progress *models.Progress         `json:"progress,omitempty"`
	Total    int                      `json:"total"`
}

type Manager struct {
	client  *nhentai.Client
	builder *builder.Builder
	output  string

	jobCh  chan string
	cancel context.CancelFunc
	runCtx context.Context
	wg     sync.WaitGroup

	stateMu         sync.RWMutex
	jobs            map[string]*models.Job
	currentProgress *models.Progress
	currentCancels  map[string]context.CancelFunc
	scheduledIDs    map[string]struct{}
	subscribers     map[int]chan models.Progress
	nextSubscriber  int
	shuttingDown    bool
}

func NewManager(client *nhentai.Client, archiveBuilder *builder.Builder, outputPath string) *Manager {
	return &Manager{
		client:         client,
		builder:        archiveBuilder,
		output:         outputPath,
		jobCh:          make(chan string, 4096),
		jobs:           make(map[string]*models.Job),
		currentCancels: make(map[string]context.CancelFunc),
		scheduledIDs:   make(map[string]struct{}),
		subscribers:    make(map[int]chan models.Progress),
	}
}

func (m *Manager) Start(ctx context.Context) {
	ctx, cancel := context.WithCancel(ctx)
	m.runCtx = ctx
	m.cancel = cancel
	for i := 0; i < galleryWorkers; i++ {
		m.wg.Add(1)
		go m.galleryWorker(ctx)
	}
}

func (m *Manager) Stop() {
	m.stateMu.Lock()
	m.shuttingDown = true
	m.stateMu.Unlock()
	if m.cancel != nil {
		m.cancel()
	}
	m.wg.Wait()
	close(m.jobCh)

	m.stateMu.Lock()
	for id, ch := range m.subscribers {
		close(ch)
		delete(m.subscribers, id)
	}
	m.currentProgress = nil
	m.stateMu.Unlock()
}

func (m *Manager) Enqueue(ids []string) error {
	now := time.Now()
	m.stateMu.Lock()
	defer m.stateMu.Unlock()
	for _, id := range ids {
		if _, exists := m.jobs[id]; exists {
			continue
		}
		m.jobs[id] = &models.Job{
			ID:        id,
			Title:     id,
			Status:    models.StatusPending,
			AddedAt:   now,
			UpdatedAt: now,
		}
	}
	return nil
}

func (m *Manager) StartPending() int {
	m.stateMu.Lock()
	defer m.stateMu.Unlock()
	queued := 0
	for id, job := range m.jobs {
		if job.Status != models.StatusPending {
			continue
		}
		if _, exists := m.scheduledIDs[id]; exists {
			continue
		}
		m.scheduledIDs[id] = struct{}{}
		queued++
		m.jobCh <- id
	}
	return queued
}

func (m *Manager) PauseDownloads() int {
	m.stateMu.Lock()
	cancels := make(map[string]context.CancelFunc, len(m.currentCancels))
	for id, cancel := range m.currentCancels {
		cancels[id] = cancel
	}
	m.stateMu.Unlock()

	for _, cancel := range cancels {
		cancel()
	}

	paused := len(cancels)
	for {
		select {
		case id := <-m.jobCh:
			m.stateMu.Lock()
			delete(m.scheduledIDs, id)
			if job, ok := m.jobs[id]; ok {
				job.Status = models.StatusPending
				job.Error = ""
				job.UpdatedAt = time.Now()
			}
			m.stateMu.Unlock()
			paused++
		default:
			m.stateMu.Lock()
			m.currentProgress = nil
			m.stateMu.Unlock()
			return paused
		}
	}
}

func (m *Manager) CurrentProgress() *models.Progress {
	m.stateMu.RLock()
	defer m.stateMu.RUnlock()
	if m.currentProgress == nil {
		return nil
	}
	copy := *m.currentProgress
	return &copy
}

func (m *Manager) SubscribeProgress() (<-chan models.Progress, func()) {
	ch := make(chan models.Progress, 16)
	m.stateMu.Lock()
	id := m.nextSubscriber
	m.nextSubscriber++
	m.subscribers[id] = ch
	m.stateMu.Unlock()

	cleanup := func() {
		m.stateMu.Lock()
		registered, ok := m.subscribers[id]
		if ok {
			delete(m.subscribers, id)
		}
		m.stateMu.Unlock()
		if ok {
			close(registered)
		}
	}

	return ch, cleanup
}

func (m *Manager) ListJobs() []models.Job {
	m.stateMu.RLock()
	defer m.stateMu.RUnlock()

	jobs := make([]models.Job, 0, len(m.jobs))
	for _, job := range m.jobs {
		jobs = append(jobs, *job)
	}

	sort.Slice(jobs, func(i, j int) bool {
		if jobs[i].AddedAt.Equal(jobs[j].AddedAt) {
			return jobs[i].ID < jobs[j].ID
		}
		return jobs[i].AddedAt.After(jobs[j].AddedAt)
	})

	return jobs
}

func (m *Manager) ClearFinished() int {
	m.stateMu.Lock()
	defer m.stateMu.Unlock()

	cleared := 0
	for id, job := range m.jobs {
		if job.Status != models.StatusDone &&
			job.Status != models.StatusDuplicate &&
			job.Status != models.StatusFailed {
			continue
		}
		delete(m.jobs, id)
		cleared++
	}
	return cleared
}

func (m *Manager) StatusSnapshot() StatusSnapshot {
	m.stateMu.RLock()
	defer m.stateMu.RUnlock()
	counts := map[models.JobStatus]int{
		models.StatusPending:     0,
		models.StatusDownloading: 0,
		models.StatusDone:        0,
		models.StatusFailed:      0,
		models.StatusDuplicate:   0,
	}
	for _, job := range m.jobs {
		counts[job.Status]++
	}
	jobs := make([]models.Job, 0, len(m.jobs))
	for _, job := range m.jobs {
		jobs = append(jobs, *job)
	}
	sort.Slice(jobs, func(i, j int) bool {
		if jobs[i].UpdatedAt.Equal(jobs[j].UpdatedAt) {
			return jobs[i].AddedAt.After(jobs[j].AddedAt)
		}
		return jobs[i].UpdatedAt.After(jobs[j].UpdatedAt)
	})
	var progress *models.Progress
	if m.currentProgress != nil {
		copy := *m.currentProgress
		progress = &copy
	}
	return StatusSnapshot{Counts: counts, Jobs: jobs, Progress: progress, Total: len(m.jobs)}
}

func (m *Manager) galleryWorker(ctx context.Context) {
	defer m.wg.Done()
	for {
		select {
		case id, ok := <-m.jobCh:
			if !ok {
				return
			}
			m.processGallery(ctx, id)
		case <-ctx.Done():
			return
		}
	}
}

func (m *Manager) processGallery(ctx context.Context, galleryID string) {
	jobCtx, cancel := context.WithCancel(ctx)
	startedAt := time.Now()
	m.setActiveGallery(galleryID, cancel)
	defer func() {
		cancel()
		m.clearActiveGallery(galleryID)
		m.unmarkScheduled(galleryID)
	}()

	m.updateJob(galleryID, func(job *models.Job) {
		job.Status = models.StatusDownloading
		job.Error = ""
		job.UpdatedAt = time.Now()
	})
	m.publishProgress(models.Progress{GalleryID: galleryID, Title: galleryID, Status: "preparing", ElapsedMs: 0})

	gallery, err := m.client.FetchGallery(jobCtx, galleryID)
	if err != nil {
		if errors.Is(err, context.Canceled) {
			m.cancelGallery(galleryID)
			return
		}
		if errors.Is(err, nhentai.ErrGalleryNotFound) {
			m.failGallery(galleryID, "gallery not found")
			return
		}
		m.failGallery(galleryID, err.Error())
		return
	}

	title := strings.TrimSpace(gallery.Title.Pretty)
	if title == "" {
		title = galleryID
	}
	m.updateJob(galleryID, func(job *models.Job) {
		job.Title = title
		job.UpdatedAt = time.Now()
	})
	m.publishProgress(models.Progress{GalleryID: galleryID, Title: title, TotalPages: gallery.NumPages, Status: "preparing", ElapsedMs: time.Since(startedAt).Milliseconds()})

	duplicate, err := m.builder.HasGallery(gallery)
	if err != nil {
		m.failGallery(galleryID, err.Error())
		return
	}
	if duplicate {
		m.updateJob(galleryID, func(job *models.Job) {
			job.Status = models.StatusDuplicate
			job.Error = ""
			job.UpdatedAt = time.Now()
		})
		m.publishProgress(models.Progress{GalleryID: galleryID, Title: title, TotalPages: gallery.NumPages, Percentage: 100, Status: string(models.StatusDuplicate), ElapsedMs: time.Since(startedAt).Milliseconds()})
		return
	}

	if err := os.MkdirAll(m.output, 0755); err != nil {
		m.failGallery(galleryID, err.Error())
		return
	}
	tempDir, err := os.MkdirTemp(m.output, "kami-dl-*")
	if err != nil {
		m.failGallery(galleryID, err.Error())
		return
	}
	defer os.RemoveAll(tempDir)

	_, err = downloadPages(jobCtx, m.client, gallery.Pages, tempDir, pageWorkers, func(current, total int) {
		percentage := 0
		if total > 0 {
			percentage = int(float64(current) / float64(total) * 100)
		}
		m.publishProgress(models.Progress{
			GalleryID:   galleryID,
			Title:       title,
			CurrentPage: current,
			TotalPages:  total,
			Percentage:  percentage,
			Status:      string(models.StatusDownloading),
			ElapsedMs:   time.Since(startedAt).Milliseconds(),
		})
	})
	if err != nil {
		if errors.Is(err, context.Canceled) {
			m.cancelGallery(galleryID)
			return
		}
		m.failGallery(galleryID, err.Error())
		return
	}

	files, err := filepath.Glob(filepath.Join(tempDir, "*"))
	if err != nil {
		m.failGallery(galleryID, err.Error())
		return
	}
	pageFiles := make([]string, 0, len(files))
	for _, file := range files {
		if strings.HasSuffix(strings.ToLower(file), ".part") {
			continue
		}
		pageFiles = append(pageFiles, file)
	}
	if len(pageFiles) != gallery.NumPages {
		m.failGallery(galleryID, fmt.Sprintf("expected %d pages but found %d", gallery.NumPages, len(pageFiles)))
		return
	}

	m.publishProgress(models.Progress{GalleryID: galleryID, Title: title, CurrentPage: gallery.NumPages, TotalPages: gallery.NumPages, Percentage: 100, Status: "finalizing", ElapsedMs: time.Since(startedAt).Milliseconds()})
	_, err = m.builder.Build(builder.BuildInput{Gallery: gallery, PageFiles: pageFiles, TempDir: tempDir})
	if err != nil {
		m.failGallery(galleryID, err.Error())
		return
	}

	m.updateJob(galleryID, func(job *models.Job) {
		job.Status = models.StatusDone
		job.Error = ""
		job.Title = title
		job.UpdatedAt = time.Now()
	})
	m.publishProgress(models.Progress{GalleryID: galleryID, Title: title, CurrentPage: gallery.NumPages, TotalPages: gallery.NumPages, Percentage: 100, Status: string(models.StatusDone), ElapsedMs: time.Since(startedAt).Milliseconds()})
}

func (m *Manager) updateJob(id string, update func(job *models.Job)) {
	m.stateMu.Lock()
	defer m.stateMu.Unlock()
	job, ok := m.jobs[id]
	if !ok {
		job = &models.Job{ID: id, Title: id, AddedAt: time.Now(), UpdatedAt: time.Now(), Status: models.StatusPending}
		m.jobs[id] = job
	}
	update(job)
}

func (m *Manager) failGallery(galleryID, errorMsg string) {
	title := m.jobTitle(galleryID)
	m.updateJob(galleryID, func(job *models.Job) {
		job.Status = models.StatusFailed
		job.Error = errorMsg
		job.UpdatedAt = time.Now()
	})
	m.publishProgress(models.Progress{GalleryID: galleryID, Title: title, Status: string(models.StatusFailed), ElapsedMs: 0})
}

func (m *Manager) cancelGallery(galleryID string) {
	title := m.jobTitle(galleryID)
	m.updateJob(galleryID, func(job *models.Job) {
		job.Status = models.StatusPending
		job.Error = ""
		job.UpdatedAt = time.Now()
	})
	m.publishProgress(models.Progress{GalleryID: galleryID, Title: title, Status: string(models.StatusPending), ElapsedMs: 0})
}

func (m *Manager) jobTitle(galleryID string) string {
	m.stateMu.RLock()
	defer m.stateMu.RUnlock()
	job, ok := m.jobs[galleryID]
	if !ok || strings.TrimSpace(job.Title) == "" {
		return galleryID
	}
	return job.Title
}

func (m *Manager) publishProgress(progress models.Progress) {
	m.stateMu.Lock()
	copy := progress
	m.currentProgress = &copy
	subscribers := make([]chan models.Progress, 0, len(m.subscribers))
	for _, ch := range m.subscribers {
		subscribers = append(subscribers, ch)
	}
	m.stateMu.Unlock()

	for _, ch := range subscribers {
		select {
		case ch <- progress:
		default:
		}
	}
}

func (m *Manager) setActiveGallery(galleryID string, cancel context.CancelFunc) {
	m.stateMu.Lock()
	m.currentCancels[galleryID] = cancel
	m.stateMu.Unlock()
}

func (m *Manager) clearActiveGallery(galleryID string) {
	m.stateMu.Lock()
	delete(m.currentCancels, galleryID)
	m.stateMu.Unlock()
}

func (m *Manager) unmarkScheduled(galleryID string) {
	m.stateMu.Lock()
	delete(m.scheduledIDs, galleryID)
	m.stateMu.Unlock()
}

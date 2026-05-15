package downloader

import (
	"time"

	"github.com/AkinAkinbobola/kamimashita/kami-dl/internal/models"
)

// LoadOwned pre-populates the job map with StatusDone for each ID.
// It does not overwrite jobs that are already tracked (e.g. actively
// downloading or queued), so it is safe to call concurrently with Start.
func (m *Manager) LoadOwned(ids []string) {
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
			Status:    models.StatusDone,
			AddedAt:   now,
			UpdatedAt: now,
		}
	}
}
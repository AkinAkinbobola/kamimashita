package models

import "time"

type JobStatus string

const (
	StatusPending     JobStatus = "pending"
	StatusDownloading JobStatus = "downloading"
	StatusDone        JobStatus = "done"
	StatusFailed      JobStatus = "failed"
	StatusDuplicate   JobStatus = "duplicate"
)

type Job struct {
	ID        string    `json:"id"`
	Title     string    `json:"title"`
	Status    JobStatus `json:"status"`
	Error     string    `json:"error,omitempty"`
	AddedAt   time.Time `json:"added_at"`
	UpdatedAt time.Time `json:"updated_at"`
}

type Progress struct {
	GalleryID   string `json:"gallery_id"`
	Title       string `json:"title"`
	CurrentPage int    `json:"current_page"`
	TotalPages  int    `json:"total_pages"`
	Percentage  int    `json:"percentage"`
	Status      string `json:"status"`
	ElapsedMs   int64  `json:"elapsed_ms"`
}

package builder

import (
	"encoding/xml"
	"fmt"
	"strconv"
	"strings"
	"time"

	"github.com/AkinAkinbobola/kamimashita/kami-dl/internal/nhentai"
)

// ComicInfo represents the ComicInfo.xml structure
type ComicInfo struct {
	XMLName   xml.Name `xml:"ComicInfo"`
	Title     string   `xml:"Title"`
	Web       string   `xml:"Web"`
	Notes     string   `xml:"Notes"`
	PageCount string   `xml:"PageCount"`
	Year      string   `xml:"Year"`
	Month     string   `xml:"Month"`
	Day       string   `xml:"Day"`
	Tags      string   `xml:"Tags"`
}

func GenerateComicInfo(gallery *nhentai.Gallery) *ComicInfo {
	if gallery == nil {
		return &ComicInfo{}
	}

	yearValue, monthValue, dayValue := releaseDateValues(gallery.UploadDate)

	return &ComicInfo{
		Title:     strings.TrimSpace(gallery.Title.Pretty),
		Web:       fmt.Sprintf("https://nhentai.net/g/%d", gallery.ID),
		Notes:     fmt.Sprintf("source_id:%d media_id:%s", gallery.ID, gallery.MediaID),
		PageCount: formatPositiveIntString(gallery.NumPages),
		Year:      yearValue,
		Month:     monthValue,
		Day:       dayValue,
		Tags:      formatLRRTags(gallery),
	}
}

func formatLRRTags(gallery *nhentai.Gallery) string {
	tags := make([]string, 0, len(gallery.Tags))
	for _, tag := range gallery.Tags {
		normalizedType := strings.TrimSpace(tag.Type)
		normalized := strings.TrimSpace(tag.Name)
		if normalizedType == "" || normalized == "" {
			continue
		}
		tags = append(tags, normalizedType+":"+normalized)
	}
	return strings.Join(tags, ", ")
}

func releaseDateValues(unixTimestamp int64) (year string, month string, day string) {
	if unixTimestamp <= 0 {
		return "", "", ""
	}
	t := time.Unix(unixTimestamp, 0).UTC()
	return strconv.Itoa(t.Year()), strconv.Itoa(int(t.Month())), strconv.Itoa(t.Day())
}

func formatPositiveIntString(value int) string {
	if value <= 0 {
		return ""
	}
	return strconv.Itoa(value)
}

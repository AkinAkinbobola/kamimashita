package builder

import (
	"encoding/xml"
	"fmt"
	"math"
	"strconv"
	"strings"
	"time"
	"unicode"

	"github.com/AkinAkinbobola/kamimashita/kami-dl/internal/nhentai"
)

// ComicInfo represents the ComicInfo.xml structure
type ComicInfo struct {
	XMLName         xml.Name `xml:"ComicInfo"`
	XMLNSXSD        string   `xml:"xmlns:xsd,attr"`
	XMLNSXSI        string   `xml:"xmlns:xsi,attr"`
	Title           string   `xml:"Title"`
	Series          string   `xml:"Series"`
	LocalizedSeries string   `xml:"LocalizedSeries"`
	Number          string   `xml:"Number"`
	Volume          string   `xml:"Volume"`
	Summary         string   `xml:"Summary"`
	Writer          string   `xml:"Writer"`
	Penciller       string   `xml:"Penciller"`
	Inker           string   `xml:"Inker"`
	Colorist        string   `xml:"Colorist"`
	CoverArtist     string   `xml:"CoverArtist"`
	Letterer        string   `xml:"Letterer"`
	Editor          string   `xml:"Editor"`
	Translator      string   `xml:"Translator"`
	Publisher       string   `xml:"Publisher"`
	Imprint         string   `xml:"Imprint"`
	Genre           string   `xml:"Genre"`
	Tags            string   `xml:"Tags"`
	Web             string   `xml:"Web"`
	Notes           string   `xml:"Notes"`
	PageCount       string   `xml:"PageCount"`
	Year            string   `xml:"Year"`
	Month           string   `xml:"Month"`
	Day             string   `xml:"Day"`
	AgeRating       string   `xml:"AgeRating"`
	CommunityRating string   `xml:"CommunityRating"`
	LanguageISO     string   `xml:"LanguageISO"`
	Manga           string   `xml:"Manga"`
	BlackAndWhite   string   `xml:"BlackAndWhite"`
	Characters      string   `xml:"Characters"`
	SeriesGroup     string   `xml:"SeriesGroup"`
	StoryArc        string   `xml:"StoryArc"`
	StoryArcNumber  string   `xml:"StoryArcNumber"`
}

func GenerateComicInfo(gallery *nhentai.Gallery) *ComicInfo {
	if gallery == nil {
		return &ComicInfo{
			XMLNSXSD:      "http://www.w3.org/2001/XMLSchema",
			XMLNSXSI:      "http://www.w3.org/2001/XMLSchema-instance",
			AgeRating:     "Adults Only 18+",
			LanguageISO:   "en",
			Manga:         "YesAndRightToLeft",
			BlackAndWhite: "No",
		}
	}

	artists := uniqueTagNames(gallery, "artist")
	groups := uniqueTagNames(gallery, "group")
	parodies := uniqueTagNames(gallery, "parody")
	characters := uniqueTagNames(gallery, "character")
	tags := collectCanonicalTags(gallery)
	series := sanitizeArtistFolder(resolveComicInfoSeries(gallery), "")
	writer := joinTitleCased(artists)
	publisher := ""
	if len(groups) > 0 {
		publisher = titleCaseName(groups[0])
	}
	genre := "Original"
	if len(parodies) > 0 {
		genre = joinTitleCased(parodies)
	}
	yearValue, monthValue, dayValue, releaseKey := releaseDateValues(gallery.UploadDate)

	info := &ComicInfo{
		XMLNSXSD:        "http://www.w3.org/2001/XMLSchema",
		XMLNSXSI:        "http://www.w3.org/2001/XMLSchema-instance",
		Title:           strings.TrimSpace(gallery.Title.Pretty),
		Series:          series,
		LocalizedSeries: strings.TrimSpace(gallery.Title.Japanese),
		Number:          releaseKey,
		Volume:          releaseKey,
		Summary:         "",
		Writer:          writer,
		Penciller:       "",
		Inker:           "",
		Colorist:        "",
		CoverArtist:     "",
		Letterer:        "",
		Editor:          "",
		Translator:      strings.TrimSpace(gallery.Scanlator),
		Publisher:       publisher,
		Imprint:         "",
		Genre:           genre,
		Tags:            joinTitleCased(tags),
		Web:             "https://nhentai.net/g/" + fmt.Sprintf("%d", gallery.ID),
		Notes:           fmt.Sprintf("source_id:%d media_id:%s", gallery.ID, gallery.MediaID),
		PageCount:       formatPositiveIntString(gallery.NumPages),
		Year:            yearValue,
		Month:           monthValue,
		Day:             dayValue,
		AgeRating:       "Adults Only 18+",
		CommunityRating: formatCommunityRating(gallery.NumFavorites),
		LanguageISO:     "en",
		Manga:           "YesAndRightToLeft",
		BlackAndWhite:   "No",
		Characters:      joinTitleCased(characters),
		SeriesGroup:     "",
		StoryArc:        "",
		StoryArcNumber:  "",
	}

	if len(artists) == 1 {
		info.Penciller = writer
		info.Inker = writer
		info.Colorist = writer
		info.CoverArtist = writer
	}

	return info
}

func uniqueTagNames(gallery *nhentai.Gallery, tagType string) []string {
	seen := make(map[string]bool)
	result := make([]string, 0)

	for _, tag := range gallery.Tags {
		if tag.Type != tagType {
			continue
		}

		normalized := strings.TrimSpace(tag.Name)
		if normalized == "" {
			continue
		}

		key := strings.ToLower(normalized)
		if seen[key] {
			continue
		}
		seen[key] = true
		result = append(result, normalized)
	}

	return result
}

func titleCaseName(value string) string {
	words := strings.Fields(strings.ToLower(strings.TrimSpace(value)))
	for i, word := range words {
		runes := []rune(word)
		makeUpper := true
		for j, r := range runes {
			if makeUpper && unicode.IsLetter(r) {
				runes[j] = unicode.ToUpper(r)
				makeUpper = false
				continue
			}
			if r == '-' || r == '/' || r == '(' {
				makeUpper = true
			}
		}
		words[i] = string(runes)
	}
	return strings.Join(words, " ")
}

func sanitizeArtistFolder(value, fallback string) string {
	return sanitizeWindowsComponent(value, fallback)
}

func sanitizeWindowsComponent(value, fallback string) string {
	sanitized := strings.TrimSpace(value)
	sanitized = strings.ReplaceAll(sanitized, "\t", " ")
	sanitized = strings.ReplaceAll(sanitized, "\r", " ")
	sanitized = strings.ReplaceAll(sanitized, "\n", " ")
	sanitized = strings.ReplaceAll(sanitized, "<", "(")
	sanitized = strings.ReplaceAll(sanitized, ">", ")")
	sanitized = strings.ReplaceAll(sanitized, ":", " -")
	sanitized = strings.ReplaceAll(sanitized, "\"", "'")
	sanitized = strings.ReplaceAll(sanitized, "|", " ")
	sanitized = strings.ReplaceAll(sanitized, "?", "")
	sanitized = strings.ReplaceAll(sanitized, "*", "")
	sanitized = strings.ReplaceAll(sanitized, "\\", "-")
	sanitized = strings.ReplaceAll(sanitized, "/", "-")
	sanitized = strings.Join(strings.Fields(sanitized), " ")
	sanitized = strings.TrimRight(strings.TrimSpace(sanitized), " .")

	if sanitized == "" {
		sanitized = fallback
	}

	reserved := map[string]bool{
		"CON": true, "PRN": true, "AUX": true, "NUL": true,
		"COM1": true, "COM2": true, "COM3": true, "COM4": true, "COM5": true, "COM6": true, "COM7": true, "COM8": true, "COM9": true,
		"LPT1": true, "LPT2": true, "LPT3": true, "LPT4": true, "LPT5": true, "LPT6": true, "LPT7": true, "LPT8": true, "LPT9": true,
	}
	if reserved[strings.ToUpper(sanitized)] {
		sanitized = "_" + sanitized
	}

	return sanitized
}

func resolveComicInfoSeries(gallery *nhentai.Gallery) string {
	artists := uniqueTagNames(gallery, "artist")
	if len(artists) == 1 {
		return titleCaseName(artists[0])
	}
	if len(artists) > 1 {
		return "_Collaborations"
	}

	groups := uniqueTagNames(gallery, "group")
	if len(groups) > 0 {
		return titleCaseName(groups[0])
	}

	return "_Unsorted"
}

func collectCanonicalTags(gallery *nhentai.Gallery) []string {
	seen := make(map[string]bool)
	tags := make([]string, 0, len(gallery.Tags))
	for _, tag := range gallery.Tags {
		normalized := strings.TrimSpace(tag.Name)
		if normalized == "" {
			continue
		}
		if tag.Type == "artist" || tag.Type == "group" {
			continue
		}
		if tag.Type == "language" && (strings.EqualFold(normalized, "translated") || strings.EqualFold(normalized, "rewrite")) {
			continue
		}
		key := strings.ToLower(normalized)
		if seen[key] {
			continue
		}
		seen[key] = true
		tags = append(tags, normalized)
	}
	return tags
}

func joinTitleCased(values []string) string {
	formatted := make([]string, 0, len(values))
	for _, value := range values {
		trimmed := strings.TrimSpace(value)
		if trimmed == "" {
			continue
		}
		formatted = append(formatted, titleCaseName(trimmed))
	}
	return strings.Join(formatted, ", ")
}

func releaseDateValues(unixTimestamp int64) (year string, month string, day string, key string) {
	if unixTimestamp <= 0 {
		return "", "", "", ""
	}
	t := time.Unix(unixTimestamp, 0).UTC()
	return strconv.Itoa(t.Year()), strconv.Itoa(int(t.Month())), strconv.Itoa(t.Day()), fmt.Sprintf("%04d%02d%02d", t.Year(), int(t.Month()), t.Day())
}

func formatPositiveIntString(value int) string {
	if value <= 0 {
		return ""
	}
	return strconv.Itoa(value)
}

func formatCommunityRating(numFavorites int) string {
	if numFavorites <= 0 {
		return ""
	}
	rating := float64(numFavorites) / 10000.0
	if rating > 5.0 {
		rating = 5.0
	}
	rounded := math.Round(rating*100) / 100
	return strconv.FormatFloat(rounded, 'f', -1, 64)
}

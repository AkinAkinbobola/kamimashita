package builder

import (
	"archive/zip"
	"encoding/xml"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"time"
	"unicode"

	"github.com/AkinAkinbobola/kamimashita/kami-dl/internal/nhentai"
)

var sourceIDPattern = regexp.MustCompile(`source_id:(\d+)`)

type Builder struct {
	libraryPath string
}

type BuildInput struct {
	Gallery   *nhentai.Gallery
	PageFiles []string
	TempDir   string
}

type BuildResult struct {
	CBZPath      string
	ArtistFolder string
	Title        string
}

func New(outputPath string) *Builder {
	return &Builder{libraryPath: filepath.Clean(outputPath)}
}

func (b *Builder) Build(input BuildInput) (*BuildResult, error) {
	if input.Gallery == nil {
		return nil, fmt.Errorf("gallery metadata is required")
	}
	if len(input.PageFiles) == 0 {
		return nil, fmt.Errorf("at least one page file is required")
	}

	baseLibraryPath, err := filepath.Abs(b.libraryPath)
	if err != nil {
		return nil, fmt.Errorf("failed to resolve library path: %w", err)
	}

	artistFolder := sanitizeArtistFolder(b.resolveArtistFolder(input.Gallery), "_Unsorted")
	title := sanitizeCBZTitle(input.Gallery.Title.Pretty, fmt.Sprintf("gallery_%d", input.Gallery.ID))
	artistPath, cbzPath, tempCBZ, overwriteExisting, err := b.resolveCBZPaths(baseLibraryPath, artistFolder, title, input.Gallery.ID)
	if err != nil {
		return nil, err
	}

	if err := os.MkdirAll(artistPath, 0755); err != nil {
		return nil, fmt.Errorf("failed to create artist directory: %w", err)
	}
	if err := os.Remove(tempCBZ); err != nil && !os.IsNotExist(err) {
		return nil, fmt.Errorf("failed to prepare temp cbz path: %w", err)
	}

	if err := b.createCBZ(tempCBZ, input); err != nil {
		_ = os.Remove(tempCBZ)
		return nil, fmt.Errorf("failed to create CBZ: %w", err)
	}
	if overwriteExisting {
		if err := os.Remove(cbzPath); err != nil && !os.IsNotExist(err) {
			_ = os.Remove(tempCBZ)
			return nil, fmt.Errorf("failed to replace existing CBZ: %w", err)
		}
	}
	if err := os.Rename(tempCBZ, cbzPath); err != nil {
		_ = os.Remove(tempCBZ)
		return nil, fmt.Errorf("failed to move CBZ to library: %w", err)
	}

	return &BuildResult{
		CBZPath:      cbzPath,
		ArtistFolder: artistFolder,
		Title:        strings.TrimSuffix(filepath.Base(cbzPath), filepath.Ext(cbzPath)),
	}, nil
}

func (b *Builder) HasGallery(gallery *nhentai.Gallery) (bool, error) {
	if gallery == nil {
		return false, fmt.Errorf("gallery metadata is required")
	}
	baseLibraryPath, err := filepath.Abs(b.libraryPath)
	if err != nil {
		return false, fmt.Errorf("failed to resolve library path: %w", err)
	}
	artistFolder := sanitizeArtistFolder(b.resolveArtistFolder(gallery), "_Unsorted")
	title := sanitizeCBZTitle(gallery.Title.Pretty, fmt.Sprintf("gallery_%d", gallery.ID))
	_, _, _, overwriteExisting, err := b.resolveCBZPaths(baseLibraryPath, artistFolder, title, gallery.ID)
	if err != nil {
		return false, err
	}
	return overwriteExisting, nil
}

func (b *Builder) resolveCBZPaths(baseLibraryPath, artistFolder, title string, galleryID int) (string, string, string, bool, error) {
	artistPath, err := safeJoinWithinBase(baseLibraryPath, artistFolder)
	if err != nil {
		return "", "", "", false, fmt.Errorf("failed to resolve artist directory: %w", err)
	}

	resolvePath := func(fileTitle string) (string, error) {
		return safeJoinWithinBase(artistPath, fileTitle+".cbz")
	}
	resolveTempPath := func(fileTitle string) (string, error) {
		return safeJoinWithinBase(artistPath, fileTitle+".tmp.cbz")
	}

	preferredPath, err := resolvePath(title)
	if err != nil {
		return "", "", "", false, fmt.Errorf("failed to resolve cbz path: %w", err)
	}
	preferredTempPath, err := resolveTempPath(title)
	if err != nil {
		return "", "", "", false, fmt.Errorf("failed to resolve temp cbz path: %w", err)
	}

	if _, err := os.Stat(preferredPath); os.IsNotExist(err) {
		return artistPath, preferredPath, preferredTempPath, false, nil
	} else if err != nil {
		return "", "", "", false, fmt.Errorf("failed to inspect cbz path: %w", err)
	}

	galleryIDString := strconv.Itoa(galleryID)
	if b.readSourceID(preferredPath) == galleryIDString {
		return artistPath, preferredPath, preferredTempPath, true, nil
	}

	suffixedTitle := sanitizeWindowsComponent(fmt.Sprintf("%s [%s]", title, galleryIDString), title)
	suffixedPath, err := resolvePath(suffixedTitle)
	if err != nil {
		return "", "", "", false, fmt.Errorf("failed to resolve suffixed cbz path: %w", err)
	}
	suffixedTempPath, err := resolveTempPath(suffixedTitle)
	if err != nil {
		return "", "", "", false, fmt.Errorf("failed to resolve suffixed temp cbz path: %w", err)
	}

	if _, err := os.Stat(suffixedPath); os.IsNotExist(err) {
		return artistPath, suffixedPath, suffixedTempPath, false, nil
	} else if err != nil {
		return "", "", "", false, fmt.Errorf("failed to inspect suffixed cbz path: %w", err)
	}

	if b.readSourceID(suffixedPath) == galleryIDString {
		return artistPath, suffixedPath, suffixedTempPath, true, nil
	}

	fallbackTitle := sanitizeWindowsComponent(fmt.Sprintf("%s [%s][%d]", title, galleryIDString, time.Now().Unix()), suffixedTitle)
	fallbackPath, err := resolvePath(fallbackTitle)
	if err != nil {
		return "", "", "", false, fmt.Errorf("failed to resolve fallback cbz path: %w", err)
	}
	fallbackTempPath, err := resolveTempPath(fallbackTitle)
	if err != nil {
		return "", "", "", false, fmt.Errorf("failed to resolve fallback temp cbz path: %w", err)
	}

	return artistPath, fallbackPath, fallbackTempPath, false, nil
}

func (b *Builder) readSourceID(cbzPath string) string {
	archive, err := zip.OpenReader(cbzPath)
	if err != nil {
		return ""
	}
	defer archive.Close()

	for _, file := range archive.File {
		if !strings.EqualFold(file.Name, "ComicInfo.xml") {
			continue
		}

		reader, err := file.Open()
		if err != nil {
			return ""
		}

		var comicInfo ComicInfo
		decodeErr := xml.NewDecoder(reader).Decode(&comicInfo)
		closeErr := reader.Close()
		if decodeErr != nil || closeErr != nil {
			return ""
		}

		matches := sourceIDPattern.FindStringSubmatch(comicInfo.Notes)
		if len(matches) == 2 {
			return matches[1]
		}
		return ""
	}

	return ""
}

func (b *Builder) resolveArtistFolder(gallery *nhentai.Gallery) string {
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

func sanitizeCBZTitle(value, fallback string) string {
	sanitized := strings.TrimSpace(value)
	replacer := strings.NewReplacer(
		"\\", "-",
		"/", "-",
		":", " -",
		"?", "",
		"\"", "'",
		"<", "(",
		">", ")",
		"|", " ",
		"*", "",
	)
	sanitized = replacer.Replace(sanitized)
	sanitized = collapseWhitespace(sanitized)
	sanitized = truncateAtWordBoundary(sanitized, 180)
	return sanitizeWindowsComponent(sanitized, fallback)
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
	sanitized = collapseWhitespace(sanitized)
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

func collapseWhitespace(value string) string {
	return strings.Join(strings.Fields(value), " ")
}

func safeJoinWithinBase(base string, child string) (string, error) {
	joined := filepath.Join(base, child)
	cleanBase, err := filepath.Abs(base)
	if err != nil {
		return "", err
	}
	cleanJoined, err := filepath.Abs(joined)
	if err != nil {
		return "", err
	}
	rel, err := filepath.Rel(cleanBase, cleanJoined)
	if err != nil {
		return "", err
	}
	if strings.HasPrefix(rel, "..") || filepath.IsAbs(rel) {
		return "", fmt.Errorf("path escapes library root")
	}
	return cleanJoined, nil
}

func truncateAtWordBoundary(value string, limit int) string {
	runes := []rune(strings.TrimSpace(value))
	if len(runes) <= limit {
		return string(runes)
	}

	truncated := strings.TrimSpace(string(runes[:limit]))
	lastBreak := strings.LastIndexAny(truncated, " -_([")
	if lastBreak >= limit/2 {
		truncated = strings.TrimSpace(truncated[:lastBreak])
	}
	return truncated
}

func (b *Builder) createCBZ(cbzPath string, input BuildInput) error {
	file, err := os.Create(cbzPath)
	if err != nil {
		return err
	}

	zipWriter := zip.NewWriter(file)

	sort.Slice(input.PageFiles, func(i, j int) bool {
		return naturalLess(input.PageFiles[i], input.PageFiles[j])
	})

	for i, pageFile := range input.PageFiles {
		if err := b.addFileToZip(zipWriter, pageFile, fmt.Sprintf("%03d%s", i+1, filepath.Ext(pageFile))); err != nil {
			zipWriter.Close()
			file.Close()
			return err
		}
	}

	comicInfo := GenerateComicInfo(input.Gallery)
	comicInfoXML, err := xml.MarshalIndent(comicInfo, "", "  ")
	if err != nil {
		zipWriter.Close()
		file.Close()
		return err
	}

	comicInfoWriter, err := createStoredZipEntry(zipWriter, "ComicInfo.xml")
	if err != nil {
		zipWriter.Close()
		file.Close()
		return err
	}
	if _, err := comicInfoWriter.Write([]byte(xml.Header + string(comicInfoXML))); err != nil {
		zipWriter.Close()
		file.Close()
		return err
	}
	if err := zipWriter.Close(); err != nil {
		file.Close()
		return err
	}
	if err := file.Close(); err != nil {
		return err
	}

	return nil
}

func (b *Builder) addFileToZip(zipWriter *zip.Writer, filePath, zipPath string) error {
	file, err := os.Open(filePath)
	if err != nil {
		return err
	}
	defer file.Close()

	writer, err := createStoredZipEntry(zipWriter, zipPath)
	if err != nil {
		return err
	}

	_, err = io.Copy(writer, file)
	return err
}

func createStoredZipEntry(zipWriter *zip.Writer, name string) (io.Writer, error) {
	header := &zip.FileHeader{
		Name:   name,
		Method: zip.Store,
	}
	return zipWriter.CreateHeader(header)
}

func naturalLess(a, b string) bool {
	return naturalCompare(a, b) < 0
}

func naturalCompare(a, b string) int {
	i, j := 0, 0
	for i < len(a) && j < len(b) {
		if a[i] != b[j] {
			if isDigit(a[i]) && isDigit(b[j]) {
				numA, lenA := extractNumber(a[i:])
				numB, lenB := extractNumber(b[j:])
				if numA != numB {
					return int(numA - numB)
				}
				i += lenA
				j += lenB
			} else {
				return int(a[i] - b[j])
			}
		} else {
			i++
			j++
		}
	}
	return len(a) - len(b)
}

func isDigit(c byte) bool {
	return c >= '0' && c <= '9'
}

func extractNumber(s string) (int, int) {
	i := 0
	for i < len(s) && isDigit(s[i]) {
		i++
	}
	num, _ := strconv.Atoi(s[:i])
	return num, i
}

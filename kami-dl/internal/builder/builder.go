package builder

import (
	"archive/zip"
	"encoding/xml"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"sort"
	"strconv"

	"github.com/AkinAkinbobola/kamimashita/kami-dl/internal/nhentai"
)

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

	tempDir, err := os.MkdirTemp(os.TempDir(), "kami-dl-*")
	if err != nil {
		return nil, fmt.Errorf("failed to create temp build directory: %w", err)
	}
	defer os.RemoveAll(tempDir)

	cbzPath := filepath.Join(baseLibraryPath, fmt.Sprintf("%d.cbz", input.Gallery.ID))
	tempCBZ := filepath.Join(tempDir, filepath.Base(cbzPath))

	if err := b.createCBZ(tempCBZ, input); err != nil {
		_ = os.Remove(tempCBZ)
		return nil, fmt.Errorf("failed to create CBZ: %w", err)
	}
	if err := verifyCBZ(tempCBZ); err != nil {
		_ = os.Remove(tempCBZ)
		return nil, fmt.Errorf("failed to verify CBZ: %w", err)
	}
	if err := moveFile(tempCBZ, cbzPath); err != nil {
		_ = os.Remove(tempCBZ)
		return nil, fmt.Errorf("failed to move CBZ to library: %w", err)
	}

	return &BuildResult{
		CBZPath:      cbzPath,
		ArtistFolder: "",
		Title:        strconv.Itoa(input.Gallery.ID),
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
	cbzPath := filepath.Join(baseLibraryPath, fmt.Sprintf("%d.cbz", gallery.ID))
	if _, err := os.Stat(cbzPath); err == nil {
		return true, nil
	} else if err != nil && !os.IsNotExist(err) {
		return false, fmt.Errorf("failed to inspect cbz path: %w", err)
	}
	return false, nil
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

func verifyCBZ(cbzPath string) error {
	archive, err := zip.OpenReader(cbzPath)
	if err != nil {
		return err
	}
	return archive.Close()
}

func moveFile(sourcePath, destinationPath string) error {
	if err := os.Rename(sourcePath, destinationPath); err == nil {
		return nil
	}

	source, err := os.Open(sourcePath)
	if err != nil {
		return err
	}

	destination, err := os.Create(destinationPath)
	if err != nil {
		source.Close()
		return err
	}

	if _, err := io.Copy(destination, source); err != nil {
		destination.Close()
		source.Close()
		_ = os.Remove(destinationPath)
		return err
	}
	if err := destination.Close(); err != nil {
		source.Close()
		_ = os.Remove(destinationPath)
		return err
	}
	if err := source.Close(); err != nil {
		_ = os.Remove(destinationPath)
		return err
	}

	return os.Remove(sourcePath)
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

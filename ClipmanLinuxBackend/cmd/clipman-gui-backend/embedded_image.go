package main

import (
	"bytes"
	"crypto/sha256"
	"encoding/base64"
	"encoding/binary"
	"errors"
	"fmt"
	"image"
	"image/jpeg"
	"image/png"
	"path"
	"strings"
	"unicode"
	"unicode/utf8"

	"github.com/OnjLouis/Clipman/ClipmanLinuxBackend/internal/model"
	xdraw "golang.org/x/image/draw"
	xhtml "golang.org/x/net/html"
)

const (
	maxImageInputBytes          = 16 * 1024 * 1024
	maxStoredImageBytes         = 512 * 1024
	maxEmbeddedImageBudgetBytes = 8 * 1024 * 1024
	maxImagePixels              = 16 * 1024 * 1024
	maxImageInputDimension      = 4096
	maxImageStoredDimension     = 2048
	maxPreservedMetadataBytes   = 64 * 1024
)

var pngSignature = []byte("\x89PNG\r\n\x1a\n")

type embeddedImage struct {
	Filename string
	Alt      string
	MIME     string
	Data     []byte
	Width    int
	Height   int
}

type preparedImageJSON struct {
	Text     string        `json:"text"`
	RichText *richTextJSON `json:"rich_text"`
	Filename string        `json:"filename"`
	MIME     string        `json:"mime"`
	Width    int           `json:"width"`
	Height   int           `json:"height"`
	Size     int           `json:"size"`
}

func prepareEmbeddedImage(mimeType, filename, encoded string) (*preparedImageJSON, error) {
	mimeType = strings.ToLower(strings.TrimSpace(strings.Split(mimeType, ";")[0]))
	if mimeType != "image/png" && mimeType != "image/jpeg" {
		return nil, errors.New("Clipman can add only standalone PNG or JPEG images")
	}
	if base64.StdEncoding.DecodedLen(len(encoded)) > maxImageInputBytes+2 {
		return nil, errors.New("the clipboard image is larger than the 16 MiB input limit")
	}
	raw, err := base64.StdEncoding.DecodeString(encoded)
	if err != nil {
		return nil, errors.New("the clipboard image data is invalid")
	}
	if len(raw) == 0 || len(raw) > maxImageInputBytes {
		return nil, errors.New("the clipboard image is empty or larger than the 16 MiB input limit")
	}
	optimized, outputMIME, width, height, err := optimizeEmbeddedImage(raw, mimeType)
	if err != nil {
		return nil, err
	}
	filename = safeImageFilename(filename, outputMIME)
	alt := "Image: " + filename
	digest := sha256.Sum256(optimized)
	wrapper := buildEmbeddedImageWrapper(filename, alt, outputMIME, optimized)
	if len([]byte(wrapper)) > maxRichHTMLBytes {
		return nil, errors.New("the optimized image cannot fit within Clipman's Rich Text limit")
	}
	return &preparedImageJSON{
		Text:     fmt.Sprintf("Image: %s (%x)", filename, digest[:6]),
		RichText: &richTextJSON{Version: 1, HTMLFragment: wrapper, PreferredFormat: "Html"},
		Filename: filename, MIME: outputMIME, Width: width, Height: height, Size: len(optimized),
	}, nil
}

func safeImageFilename(value, mimeType string) string {
	if !utf8.ValidString(value) {
		value = ""
	}
	lowerInput := strings.ToLower(strings.TrimSpace(value))
	if strings.Contains(lowerInput, "://") || strings.HasPrefix(lowerInput, "content:") || strings.HasPrefix(lowerInput, "file:") {
		value = ""
	}
	value = strings.ReplaceAll(strings.TrimSpace(value), "\\", "/")
	value = path.Base(value)
	var clean strings.Builder
	pendingSpace := false
	for _, character := range value {
		if unicode.IsSpace(character) {
			pendingSpace = clean.Len() > 0
			continue
		}
		if unicode.IsControl(character) || unicode.In(character, unicode.Cf, unicode.Cs) ||
			character == utf8.RuneError || character == '/' || character == '\\' || character == ':' {
			continue
		}
		if pendingSpace {
			clean.WriteByte(' ')
			pendingSpace = false
		}
		clean.WriteRune(character)
	}
	value = clean.String()
	extension := ".png"
	if mimeType == "image/jpeg" {
		if strings.HasSuffix(strings.ToLower(value), ".jpeg") {
			extension = ".jpeg"
		} else if strings.HasSuffix(strings.ToLower(value), ".jpg") {
			extension = ".jpg"
		} else {
			extension = ".jpg"
		}
	}
	stem := strings.TrimSpace(strings.TrimSuffix(value, path.Ext(value)))
	if stem == "" || stem == "." {
		stem = "Clipboard image"
	}
	stemRunes := []rune(stem)
	maximumStemLength := 120 - len([]rune(extension))
	if len(stemRunes) > maximumStemLength {
		stem = strings.TrimSpace(string(stemRunes[:maximumStemLength]))
	}
	return stem + extension
}

func escapeClipmanImageAttribute(value string) string {
	return strings.NewReplacer(
		"&", "&amp;",
		`"`, "&quot;",
		"<", "&lt;",
		">", "&gt;",
	).Replace(value)
}

func buildEmbeddedImageWrapper(filename, alt, mimeType string, raw []byte) string {
	return `<img data-clipman-image="1" data-clipman-filename="` + escapeClipmanImageAttribute(filename) +
		`" alt="` + escapeClipmanImageAttribute(alt) + `" src="data:` + mimeType + `;base64,` +
		base64.StdEncoding.EncodeToString(raw) + `">`
}

func parseEmbeddedImageWrapper(fragment string) (*embeddedImage, error) {
	if fragment == "" || len([]byte(fragment)) > maxRichHTMLBytes {
		return nil, errors.New("not a Clipman image wrapper")
	}
	tokenizer := xhtml.NewTokenizer(strings.NewReader(fragment))
	tokenType := tokenizer.Next()
	if tokenType != xhtml.StartTagToken && tokenType != xhtml.SelfClosingTagToken {
		return nil, errors.New("not a Clipman image wrapper")
	}
	token := tokenizer.Token()
	if token.Data != "img" || len(token.Attr) != 4 {
		return nil, errors.New("not a Clipman image wrapper")
	}
	attributes := map[string]string{}
	for _, attribute := range token.Attr {
		if attribute.Namespace != "" || attributes[attribute.Key] != "" {
			return nil, errors.New("not a Clipman image wrapper")
		}
		attributes[attribute.Key] = attribute.Val
	}
	if attributes["data-clipman-image"] != "1" || attributes["data-clipman-filename"] == "" || attributes["alt"] == "" {
		return nil, errors.New("not a Clipman image wrapper")
	}
	if attributes["alt"] != "Image: "+attributes["data-clipman-filename"] {
		return nil, errors.New("not a canonical Clipman image wrapper")
	}
	if next := tokenizer.Next(); next != xhtml.ErrorToken {
		return nil, errors.New("not a Clipman image wrapper")
	}
	source := attributes["src"]
	mimeType := ""
	for _, candidate := range []string{"image/jpeg", "image/png"} {
		prefix := "data:" + candidate + ";base64,"
		if strings.HasPrefix(source, prefix) {
			mimeType = candidate
			source = strings.TrimPrefix(source, prefix)
			break
		}
	}
	if mimeType == "" || base64.StdEncoding.DecodedLen(len(source)) > maxStoredImageBytes+2 {
		return nil, errors.New("not a Clipman image wrapper")
	}
	raw, err := base64.StdEncoding.DecodeString(source)
	if err != nil || len(raw) == 0 || len(raw) > maxStoredImageBytes {
		return nil, errors.New("not a Clipman image wrapper")
	}
	filename := attributes["data-clipman-filename"]
	if safeImageFilename(filename, mimeType) != filename {
		return nil, errors.New("not a canonical Clipman image filename")
	}
	if mimeType == "image/png" && pngContainsChunk(raw, "acTL") {
		return nil, errors.New("animated PNG images are not supported")
	}
	config, format, err := image.DecodeConfig(bytes.NewReader(raw))
	if err != nil || !imageFormatMatchesMIME(format, mimeType) {
		return nil, errors.New("not a Clipman image wrapper")
	}
	if config.Width <= 0 || config.Height <= 0 || config.Width > maxImageStoredDimension || config.Height > maxImageStoredDimension || int64(config.Width)*int64(config.Height) > int64(maxImageStoredDimension*maxImageStoredDimension) {
		return nil, errors.New("not a bounded Clipman image wrapper")
	}
	parsed := &embeddedImage{
		Filename: filename, Alt: attributes["alt"], MIME: mimeType,
		Data: raw, Width: config.Width, Height: config.Height,
	}
	if buildEmbeddedImageWrapper(parsed.Filename, parsed.Alt, parsed.MIME, parsed.Data) != fragment {
		return nil, errors.New("not a canonical Clipman image wrapper")
	}
	return parsed, nil
}

func imageFormatMatchesMIME(format, mimeType string) bool {
	return (format == "png" && mimeType == "image/png") || (format == "jpeg" && mimeType == "image/jpeg")
}

func optimizeEmbeddedImage(raw []byte, mimeType string) ([]byte, string, int, int, error) {
	if mimeType == "image/png" && pngContainsChunk(raw, "acTL") {
		return nil, "", 0, 0, errors.New("animated PNG images are not supported")
	}
	config, format, err := image.DecodeConfig(bytes.NewReader(raw))
	if err != nil || !imageFormatMatchesMIME(format, mimeType) {
		return nil, "", 0, 0, errors.New("the clipboard image does not match its PNG or JPEG format")
	}
	if config.Width <= 0 || config.Height <= 0 || config.Width > maxImageInputDimension || config.Height > maxImageInputDimension || int64(config.Width)*int64(config.Height) > maxImagePixels {
		return nil, "", 0, 0, errors.New("the clipboard image exceeds the 4096-pixel or 16-megapixel input limit")
	}
	if len(raw) <= maxStoredImageBytes && config.Width <= maxImageStoredDimension && config.Height <= maxImageStoredDimension {
		preserved := append([]byte(nil), raw...)
		return preserved, mimeType, config.Width, config.Height, nil
	}
	decoded, decodedFormat, err := image.Decode(bytes.NewReader(raw))
	if err != nil || !imageFormatMatchesMIME(decodedFormat, mimeType) {
		return nil, "", 0, 0, errors.New("the clipboard image could not be decoded safely")
	}
	metadata := extractBoundedImageMetadata(raw, mimeType)
	width, height := fitDimensions(config.Width, config.Height, maxImageStoredDimension)
	quality := 88
	for attempts := 0; attempts < 18; attempts++ {
		resized := resizeImage(decoded, width, height)
		var buffer bytes.Buffer
		if mimeType == "image/jpeg" {
			err = jpeg.Encode(&buffer, resized, &jpeg.Options{Quality: quality})
		} else {
			encoder := png.Encoder{CompressionLevel: png.BestCompression}
			err = encoder.Encode(&buffer, resized)
		}
		if err != nil {
			return nil, "", 0, 0, errors.New("the clipboard image could not be optimized")
		}
		encoded := attachBoundedImageMetadata(buffer.Bytes(), metadata, mimeType, maxStoredImageBytes)
		if len(encoded) <= maxStoredImageBytes {
			return encoded, mimeType, width, height, nil
		}
		if mimeType == "image/jpeg" && quality > 58 {
			quality -= 10
			continue
		}
		newWidth, newHeight := fitDimensions(width, height, maxInt(64, int(float64(maxInt(width, height))*0.82)))
		if newWidth == width && newHeight == height {
			break
		}
		width, height, quality = newWidth, newHeight, 82
	}
	return nil, "", 0, 0, errors.New("the clipboard image could not be reduced below the 512 KiB storage limit")
}

func pngContainsChunk(raw []byte, wanted string) bool {
	if !bytes.HasPrefix(raw, pngSignature) {
		return false
	}
	for offset := len(pngSignature); offset+12 <= len(raw); {
		length := int64(binary.BigEndian.Uint32(raw[offset : offset+4]))
		end := int64(offset) + 12 + length
		if end > int64(len(raw)) {
			return false
		}
		if string(raw[offset+4:offset+8]) == wanted {
			return true
		}
		offset = int(end)
	}
	return false
}

func fitDimensions(width, height, longest int) (int, int) {
	if width <= longest && height <= longest {
		return width, height
	}
	if width >= height {
		return longest, maxInt(1, int(float64(height)*float64(longest)/float64(width)))
	}
	return maxInt(1, int(float64(width)*float64(longest)/float64(height))), longest
}

func maxInt(left, right int) int {
	if left > right {
		return left
	}
	return right
}

func resizeImage(source image.Image, width, height int) image.Image {
	if source.Bounds().Dx() == width && source.Bounds().Dy() == height {
		return source
	}
	destination := image.NewNRGBA(image.Rect(0, 0, width, height))
	xdraw.ApproxBiLinear.Scale(destination, destination.Bounds(), source, source.Bounds(), xdraw.Src, nil)
	return destination
}

func extractBoundedImageMetadata(raw []byte, mimeType string) [][]byte {
	if mimeType == "image/jpeg" {
		return extractJPEGMetadata(raw)
	}
	return extractPNGMetadata(raw)
}

func extractJPEGMetadata(raw []byte) [][]byte {
	if len(raw) < 4 || raw[0] != 0xff || raw[1] != 0xd8 {
		return nil
	}
	result, total := [][]byte{}, 0
	for offset := 2; offset+4 <= len(raw) && raw[offset] == 0xff; {
		marker := raw[offset+1]
		if marker == 0xda || marker == 0xd9 {
			break
		}
		length := int(binary.BigEndian.Uint16(raw[offset+2 : offset+4]))
		end := offset + 2 + length
		if length < 2 || end > len(raw) {
			break
		}
		if marker == 0xe1 || marker == 0xe2 || marker == 0xed || marker == 0xfe {
			segment := append([]byte(nil), raw[offset:end]...)
			if total+len(segment) <= maxPreservedMetadataBytes {
				result, total = append(result, segment), total+len(segment)
			}
		}
		offset = end
	}
	return result
}

func extractPNGMetadata(raw []byte) [][]byte {
	if !bytes.HasPrefix(raw, pngSignature) {
		return nil
	}
	allowed := map[string]bool{"cHRM": true, "eXIf": true, "gAMA": true, "iCCP": true, "iTXt": true, "pHYs": true, "sRGB": true, "tEXt": true, "tIME": true, "zTXt": true}
	result, total := [][]byte{}, 0
	for offset := len(pngSignature); offset+12 <= len(raw); {
		length := int64(binary.BigEndian.Uint32(raw[offset : offset+4]))
		end := int64(offset) + 12 + length
		if end > int64(len(raw)) {
			break
		}
		kind := string(raw[offset+4 : offset+8])
		if allowed[kind] {
			chunk := append([]byte(nil), raw[offset:int(end)]...)
			if total+len(chunk) <= maxPreservedMetadataBytes {
				result, total = append(result, chunk), total+len(chunk)
			}
		}
		offset = int(end)
	}
	return result
}

func attachBoundedImageMetadata(encoded []byte, metadata [][]byte, mimeType string, limit int) []byte {
	if len(metadata) == 0 || len(encoded) >= limit {
		return encoded
	}
	available := limit - len(encoded)
	selected := make([][]byte, 0, len(metadata))
	for _, item := range metadata {
		if len(item) <= available {
			selected, available = append(selected, item), available-len(item)
		}
	}
	if len(selected) == 0 {
		return encoded
	}
	if mimeType == "image/jpeg" && len(encoded) >= 2 {
		result := append([]byte(nil), encoded[:2]...)
		for _, item := range selected {
			result = append(result, item...)
		}
		return append(result, encoded[2:]...)
	}
	if mimeType == "image/png" && len(encoded) >= 33 {
		result := append([]byte(nil), encoded[:33]...)
		for _, item := range selected {
			result = append(result, item...)
		}
		return append(result, encoded[33:]...)
	}
	return encoded
}

func embeddedImageBytes(database *model.Database) int {
	total := 0
	for _, entry := range database.Entries {
		richText, _ := richTextFromEntry(entry)
		if richText == nil {
			continue
		}
		if image, err := parseEmbeddedImageWrapper(richText.HTMLFragment); err == nil {
			total += len(image.Data)
		}
	}
	return total
}

func validateEmbeddedImageBudget(database *model.Database, text string, template bool, duplicate string, richText *richTextJSON) error {
	if richText == nil {
		return nil
	}
	image, err := parseEmbeddedImageWrapper(richText.HTMLFragment)
	if err != nil {
		return nil
	}
	total := embeddedImageBytes(database)
	mode := strings.ToLower(strings.TrimSpace(duplicate))
	for _, entry := range database.Entries {
		if entry.Text != text || entry.IsTemplate != template {
			continue
		}
		if mode == "ignore" {
			return nil
		}
		if mode != "keep" {
			if existingRichText, _ := richTextFromEntry(entry); existingRichText != nil {
				if existingImage, parseErr := parseEmbeddedImageWrapper(existingRichText.HTMLFragment); parseErr == nil {
					total -= len(existingImage.Data)
				}
			}
		}
		break
	}
	if total+len(image.Data) > maxEmbeddedImageBudgetBytes {
		return fmt.Errorf("adding this image would exceed the 8 MiB embedded-image history budget")
	}
	return nil
}

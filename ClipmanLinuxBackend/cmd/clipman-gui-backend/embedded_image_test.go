package main

import (
	"bytes"
	"encoding/base64"
	"encoding/json"
	"image"
	"image/color"
	"image/jpeg"
	"image/png"
	"strings"
	"testing"
	"unicode/utf8"

	"github.com/OnjLouis/Clipman/ClipmanLinuxBackend/internal/model"
)

func testPNG(t *testing.T, width, height int) []byte {
	t.Helper()
	picture := image.NewNRGBA(image.Rect(0, 0, width, height))
	for y := 0; y < height; y++ {
		for x := 0; x < width; x++ {
			picture.Set(x, y, color.NRGBA{R: uint8(x), G: uint8(y), B: 120, A: 255})
		}
	}
	var output bytes.Buffer
	if err := png.Encode(&output, picture); err != nil {
		t.Fatal(err)
	}
	return output.Bytes()
}

func testJPEG(t *testing.T) []byte {
	t.Helper()
	picture := image.NewRGBA(image.Rect(0, 0, 2, 2))
	var output bytes.Buffer
	if err := jpeg.Encode(&output, picture, &jpeg.Options{Quality: 80}); err != nil {
		t.Fatal(err)
	}
	return output.Bytes()
}

func TestEmbeddedImagePreservesCompliantOriginalAndRoundTrips(t *testing.T) {
	raw := testPNG(t, 8, 6)
	prepared, err := prepareEmbeddedImage("image/png", "Holiday photo.png", base64.StdEncoding.EncodeToString(raw))
	if err != nil {
		t.Fatal(err)
	}
	parsed, err := parseEmbeddedImageWrapper(prepared.RichText.HTMLFragment)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(parsed.Data, raw) {
		t.Fatal("a compliant original image was re-encoded")
	}
	if parsed.Width != 8 || parsed.Height != 6 || parsed.Filename != "Holiday photo.png" || !strings.HasPrefix(prepared.Text, "Image: Holiday photo.png (") || len(prepared.Text) != len("Image: Holiday photo.png (")+12+1 {
		t.Fatalf("unexpected image details: %#v %#v", parsed, prepared)
	}
	if parsed.Alt != "Image: Holiday photo.png" {
		t.Fatalf("alt = %q", parsed.Alt)
	}
}

func TestCompliantImageFastPathDoesNotRequireFullDecode(t *testing.T) {
	headerOnly := testPNG(t, 1, 1)[:33]
	if _, _, err := image.Decode(bytes.NewReader(headerOnly)); err == nil {
		t.Fatal("test image unexpectedly passed a full decode")
	}
	prepared, err := prepareEmbeddedImage("image/png", "Header.png", base64.StdEncoding.EncodeToString(headerOnly))
	if err != nil {
		t.Fatalf("bounded header-validated image was unnecessarily fully decoded: %v", err)
	}
	parsed, err := parseEmbeddedImageWrapper(prepared.RichText.HTMLFragment)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(parsed.Data, headerOnly) {
		t.Fatal("bounded header-validated image bytes were changed")
	}
}

func TestEmbeddedImageReencodePreservesBoundedMetadata(t *testing.T) {
	picture := image.NewRGBA(image.Rect(0, 0, 3000, 2))
	var encoded bytes.Buffer
	if err := jpeg.Encode(&encoded, picture, &jpeg.Options{Quality: 80}); err != nil {
		t.Fatal(err)
	}
	metadata := []byte("Exif\x00\x00camera-and-location-metadata")
	segment := []byte{0xff, 0xe1, byte((len(metadata) + 2) >> 8), byte(len(metadata) + 2)}
	segment = append(segment, metadata...)
	raw := append(append(append([]byte(nil), encoded.Bytes()[:2]...), segment...), encoded.Bytes()[2:]...)
	prepared, err := prepareEmbeddedImage("image/jpeg", "Camera photo.jpg", base64.StdEncoding.EncodeToString(raw))
	if err != nil {
		t.Fatal(err)
	}
	parsed, err := parseEmbeddedImageWrapper(prepared.RichText.HTMLFragment)
	if err != nil {
		t.Fatal(err)
	}
	if parsed.Width != maxImageStoredDimension || !bytes.Contains(parsed.Data, metadata) {
		t.Fatal("bounded JPEG metadata was not retained during required re-encoding")
	}
}

func TestEmbeddedImageFilenameIsNeverAPathOrProviderIdentifier(t *testing.T) {
	raw := testPNG(t, 2, 2)
	tests := map[string]string{
		"/home/user/private/photo.png":     "photo.png",
		`C:\Users\user\photo.png`:          "photo.png",
		"content://provider/private/id":    "Clipboard image.png",
		"photo:private.png":                "photoprivate.png",
		"bad\u202ename.png":                "badname.png",
		"Photo.PNG":                        "Photo.png",
		"word\t\u00a0\u2028\u2029name.PNG": "word name.png",
		"word\u001cname.PNG":                "wordname.png",
		strings.Repeat("a", 140) + ".png":  strings.Repeat("a", 116) + ".png",
		strings.Repeat("📷", 116) + ".png":  strings.Repeat("📷", 116) + ".png",
	}
	for name, expected := range tests {
		prepared, err := prepareEmbeddedImage("image/png", name, base64.StdEncoding.EncodeToString(raw))
		if err != nil {
			t.Fatal(err)
		}
		parsed, err := parseEmbeddedImageWrapper(prepared.RichText.HTMLFragment)
		if err != nil {
			t.Fatal(err)
		}
		if parsed.Filename != expected {
			t.Fatalf("unsafe source name %q became %q", name, parsed.Filename)
		}
		if utf8.RuneCountInString(parsed.Filename) > 120 {
			t.Fatalf("canonical filename is longer than 120 characters: %q", parsed.Filename)
		}
	}
	jpeg, err := prepareEmbeddedImage("image/jpeg", "Photo.jpeg", base64.StdEncoding.EncodeToString(testJPEG(t)))
	if err != nil {
		t.Fatal(err)
	}
	if jpeg.Filename != "Photo.jpeg" {
		t.Fatalf("JPEG extension was not canonicalized: %q", jpeg.Filename)
	}
	parsedJPEG, err := parseEmbeddedImageWrapper(jpeg.RichText.HTMLFragment)
	if err != nil {
		t.Fatalf("canonical .jpeg wrapper was not accepted: %v", err)
	}
	if parsedJPEG.Filename != "Photo.jpeg" {
		t.Fatalf("canonical .jpeg filename changed during parsing: %q", parsedJPEG.Filename)
	}
	longJPEG, err := prepareEmbeddedImage("image/jpeg", strings.Repeat("b", 140)+".jpeg", base64.StdEncoding.EncodeToString(testJPEG(t)))
	if err != nil {
		t.Fatal(err)
	}
	if longJPEG.Filename != strings.Repeat("b", 115)+".jpeg" || utf8.RuneCountInString(longJPEG.Filename) != 120 {
		t.Fatalf("JPEG filename was not capped with its extension inside 120 runes: %q", longJPEG.Filename)
	}
}

func TestEmbeddedImageApostropheUsesSharedCanonicalEscaping(t *testing.T) {
	raw := testPNG(t, 2, 2)
	filename := "Andre's photo.png"
	wrapper := buildEmbeddedImageWrapper(filename, "Image: "+filename, "image/png", raw)
	if strings.Contains(wrapper, "&#39;") || !strings.Contains(wrapper, filename) {
		t.Fatalf("apostrophe was not preserved in the canonical wrapper: %q", wrapper)
	}
	parsed, err := parseEmbeddedImageWrapper(wrapper)
	if err != nil {
		t.Fatal(err)
	}
	if parsed.Filename != filename || buildEmbeddedImageWrapper(parsed.Filename, parsed.Alt, parsed.MIME, parsed.Data) != wrapper {
		t.Fatal("apostrophe filename did not parse and canonicalize identically")
	}
	noncanonical := strings.ReplaceAll(wrapper, "Andre's", "Andre&#39;s")
	if _, err := parseEmbeddedImageWrapper(noncanonical); err == nil {
		t.Fatal("noncanonical apostrophe escaping was accepted")
	}
}

func TestEmbeddedImageWrapperRejectsNonCanonicalAndExternalContent(t *testing.T) {
	raw := testPNG(t, 2, 2)
	valid := buildEmbeddedImageWrapper("test.png", "Image: test.png", "image/png", raw)
	bad := []string{
		`<img src="https://example.com/image.png">`,
		`<img data-clipman-image="1" data-clipman-filename="test.svg" alt="test" src="data:image/svg+xml;base64,AAAA">`,
		strings.Replace(valid, ` alt="Image: test.png"`, ` onclick="run()" alt="Image: test.png"`, 1),
		valid + `<script>run()</script>`,
		strings.Replace(valid, "image/png", "image/jpeg", 1),
		buildEmbeddedImageWrapper("/home/user/private/test.png", "Image: /home/user/private/test.png", "image/png", raw),
		buildEmbeddedImageWrapper("private:test.png", "Image: private:test.png", "image/png", raw),
		buildEmbeddedImageWrapper("test.jpg", "Image: test.jpg", "image/png", raw),
		buildEmbeddedImageWrapper("bad\x01name.png", "Image: bad\x01name.png", "image/png", raw),
		buildEmbeddedImageWrapper("bad\u200fname.png", "Image: bad\u200fname.png", "image/png", raw),
		buildEmbeddedImageWrapper("bad\u202ename.png", "Image: bad\u202ename.png", "image/png", raw),
		buildEmbeddedImageWrapper("bad\u2028name.png", "Image: bad\u2028name.png", "image/png", raw),
		buildEmbeddedImageWrapper("two  spaces.png", "Image: two  spaces.png", "image/png", raw),
		buildEmbeddedImageWrapper("upper.PNG", "Image: upper.PNG", "image/png", raw),
		buildEmbeddedImageWrapper(strings.Repeat("📷", 117)+".png", "Image: "+strings.Repeat("📷", 117)+".png", "image/png", raw),
	}
	for _, value := range bad {
		if _, err := parseEmbeddedImageWrapper(value); err == nil {
			t.Errorf("unsafe wrapper was accepted: %.100q", value)
		}
	}
}

func TestEmbeddedImageLimitsAndBudget(t *testing.T) {
	tooWide := testPNG(t, maxImageInputDimension+1, 1)
	if _, err := prepareEmbeddedImage("image/png", "wide.png", base64.StdEncoding.EncodeToString(tooWide)); err == nil {
		t.Fatal("over-dimension image was accepted")
	}
	jpegData := testJPEG(t)
	padded := append(append([]byte(nil), jpegData...), bytes.Repeat([]byte{0}, maxStoredImageBytes-len(jpegData))...)
	fragment := buildEmbeddedImageWrapper("budget.jpg", "Image: budget.jpg", "image/jpeg", padded)
	rich := &richTextJSON{HTMLFragment: fragment, PreferredFormat: "Html"}
	database := model.Database{}
	for index := 0; index < maxEmbeddedImageBudgetBytes/maxStoredImageBytes; index++ {
		entry := model.Entry{ID: string(rune('a' + index)), Text: "existing " + string(rune('a'+index))}
		setRichText(&entry, rich, 1)
		database.Entries = append(database.Entries, entry)
	}
	if err := validateEmbeddedImageBudget(&database, "new image", false, "keep", rich); err == nil {
		t.Fatal("embedded-image budget overflow was accepted")
	}
	if err := validateEmbeddedImageBudget(&database, database.Entries[0].Text, false, "move", rich); err != nil {
		t.Fatalf("replacing an existing image incorrectly exceeded the budget: %v", err)
	}
	if err := validateEmbeddedImageBudget(&database, database.Entries[0].Text, false, "keep", rich); err == nil {
		t.Fatal("keeping a duplicate bypassed the embedded-image budget")
	}
	oversized := buildEmbeddedImageWrapper("large.jpg", "Image: large.jpg", "image/jpeg", append(padded, 0))
	if _, err := parseEmbeddedImageWrapper(oversized); err == nil {
		t.Fatal("oversized stored image was accepted")
	}
}

func TestInvalidClipmanImageMarkerIsNotStoredAsRichText(t *testing.T) {
	value := normalizeRichText(&richTextJSON{HTMLFragment: `<img data-clipman-image="1" src="https://example.com/a.png">`})
	if value != nil {
		t.Fatalf("invalid Clipman image marker was accepted: %#v", value)
	}
	entry := model.Entry{Text: "image"}
	raw, _ := json.Marshal(storedRichText{Version: 1, HTMLFragment: `<img data-clipman-image="1" src="file:///tmp/a.png">`, PreferredFormat: "Html"})
	entry.Extra = map[string]json.RawMessage{"RichText": raw}
	if rich, _ := richTextFromEntry(entry); rich != nil {
		t.Fatal("invalid stored image wrapper was exported as rich text")
	}
}

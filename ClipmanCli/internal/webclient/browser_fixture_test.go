package webclient

import (
	"bytes"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"image"
	"image/color"
	"image/png"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"reflect"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/OnjLouis/Clipman/ClipmanCli/internal/clipdb"
	"github.com/OnjLouis/Clipman/ClipmanCli/internal/identity"
	"github.com/OnjLouis/Clipman/ClipmanCli/internal/merge"
	"github.com/OnjLouis/Clipman/ClipmanCli/internal/model"
)

func TestBrowserUploadedFixtureRoundTripsWithNativeCodec(t *testing.T) {
	path := os.Getenv("CLIPMAN_WEB_UPLOADED_FIXTURE")
	if path == "" {
		t.Skip("synthetic browser upload is opt-in")
	}
	read := func(path string) model.Database {
		blob, err := os.ReadFile(path)
		if err != nil {
			t.Fatal(err)
		}
		db, err := clipdb.Decode(blob, "browser-test-password", clipdb.DefaultLimits())
		if err != nil {
			t.Fatal(err)
		}
		return db
	}
	before := read(os.Getenv("CLIPMAN_WEB_FIXTURE_ORIGINAL"))
	// Legacy zero ordering and last-used values receive the native engine's
	// normalisation on a write; compare against that same canonical baseline.
	merge.Normalize(&before, before.UpdatedUnixMs)
	after := read(path)
	if len(after.Entries) != len(before.Entries)+1 {
		t.Fatalf("entry count: %d -> %d", len(before.Entries), len(after.Entries))
	}
	byID := make(map[string]model.Entry)
	for _, entry := range after.Entries {
		byID[entry.ID] = entry
	}
	for _, entry := range before.Entries {
		a, _ := json.Marshal(entry)
		b, _ := json.Marshal(byID[entry.ID])
		var first, second any
		_ = json.Unmarshal(a, &first)
		_ = json.Unmarshal(b, &second)
		if !reflect.DeepEqual(first, second) {
			t.Fatalf("existing synthetic entry changed: %s\nBefore: %s\nAfter: %s", entry.ID, a, b)
		}
	}
}

// This opt-in fixture contains only synthetic history and never opens a profile.
func TestBrowserFixture(t *testing.T) {
	tool := os.Getenv("CLIPMAN_WEB_FIXTURE_TOOL")
	seedPath := os.Getenv("CLIPMAN_WEB_FIXTURE_SEED")
	if tool == "" && seedPath == "" {
		t.Skip("interactive browser fixture is opt-in")
	}
	const password, token = "browser-test-password", "browser-test-token"
	now := time.Now().UnixMilli()
	db := model.NewDatabase(now)
	for i := 0; i < 1200; i++ {
		db.Entries = append(db.Entries, model.Entry{ID: fmt.Sprintf("fixture-%03d", i), Text: fmt.Sprintf("Synthetic clip %03d\nSecond line", i), Name: fmt.Sprintf("Test clip %03d", i), SourceMachine: "Fixture", CreatedUnixMs: now + int64(i), LastUsedUnixMs: now + int64(i)})
		db.Entries[i].Extra = map[string]json.RawMessage{"RichText": json.RawMessage(`null`)}
	}
	for i := 0; i < 12; i++ {
		db.Entries = append(db.Entries, model.Entry{ID: fmt.Sprintf("link-%03d", i), Text: fmt.Sprintf("https://example.com/page/%d  link", i), Name: fmt.Sprintf("Synthetic link %03d", i), CreatedUnixMs: now, Extra: map[string]json.RawMessage{"RichText": json.RawMessage(`null`)}})
	}
	db.Entries[119].Text = "<img src=x onerror=globalThis.injected=true>\n<script>globalThis.injected=true</script>"
	imageData := image.NewRGBA(image.Rect(0, 0, 32, 32))
	for y := 0; y < 32; y++ {
		for x := 0; x < 32; x++ {
			imageData.SetRGBA(x, y, color.RGBA{R: uint8(x * 8), G: uint8(y * 8), B: 160, A: 255})
		}
	}
	var encoded bytes.Buffer
	if err := png.Encode(&encoded, imageData); err != nil {
		t.Fatal(err)
	}
	imageHTML := `<img data-clipman-image="1" data-clipman-filename="Synthetic image.png" alt="Image: Synthetic image.png" src="data:image/png;base64,` + base64.StdEncoding.EncodeToString(encoded.Bytes()) + `">`
	for _, item := range []struct{ id, name, text, fragment, rtf string }{
		{"rich-html", "Formatted test", "Invoice Bold Italic Safe Link Item Total", `<h2>Invoice</h2><p><strong>Bold</strong> <em>Italic</em> <a href="https://example.com">Safe Link</a></p><table><tr><th>Item</th><th>Total</th></tr><tr><td>Test</td><td>12</td></tr></table><script>globalThis.injected=true</script><iframe src="https://example.com/tracker"></iframe><form><input name="password"></form><img src="https://example.com/tracker"><div id="status" style="position:fixed">Literal extra text</div><a href="javascript:alert(1)">Unsafe link</a>`, ""},
		{"rich-image", "Image test", "Image: Synthetic image.png", imageHTML, ""},
		{"rich-rtf", "RTF test", "RTF text", "", "e1xydGYxIHRleHR9"},
	} {
		payload, _ := json.Marshal(richPayload{HtmlFragment: item.fragment, RtfBase64: item.rtf})
		db.Entries = append(db.Entries, model.Entry{ID: item.id, Name: item.name, Text: item.text, CreatedUnixMs: now, Extra: map[string]json.RawMessage{"RichText": payload}})
	}
	merge.Normalize(&db, now)
	blob, err := clipdb.Encode(db, password, nil)
	if err != nil {
		t.Fatal(err)
	}
	if seedPath != "" {
		if err := os.WriteFile(seedPath, blob, 0600); err != nil {
			t.Fatal(err)
		}
		return
	}
	var mu sync.Mutex
	puts := 0
	stop := make(chan struct{}, 1)
	fixture := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		mu.Lock()
		defer mu.Unlock()
		if r.URL.Path == "/fixture/status" {
			saved, err := clipdb.Decode(blob, password, clipdb.DefaultLimits())
			if err != nil {
				t.Error(err)
			}
			_ = json.NewEncoder(w).Encode(map[string]any{"puts": puts, "count": len(saved.Entries), "entries": saved.Entries})
			return
		}
		if r.URL.Path == "/fixture/stop" {
			select {
			case stop <- struct{}{}:
			default:
			}
			return
		}
		if r.Header.Get("Authorization") != "Bearer "+token {
			w.WriteHeader(401)
			return
		}
		if !strings.HasSuffix(r.URL.Path, identity.DatabaseID(token, password)) {
			w.WriteHeader(404)
			return
		}
		h := sha256.Sum256(blob)
		revision := hex.EncodeToString(h[:])
		if r.Method == "PUT" {
			if r.Header.Get("If-Match") != `"`+revision+`"` {
				w.WriteHeader(409)
				return
			}
			incoming, _ := io.ReadAll(r.Body)
			if !strings.HasPrefix(string(incoming), "CLIPDB2") || strings.Contains(string(incoming), "Quick browser test") {
				t.Error("plaintext reached relay")
			}
			if _, err := clipdb.Decode(incoming, password, clipdb.DefaultLimits()); err != nil {
				t.Error(err)
				w.WriteHeader(400)
				return
			}
			blob = incoming
			puts++
			h = sha256.Sum256(blob)
			revision = hex.EncodeToString(h[:])
		}
		w.Header().Set("ETag", `"`+revision+`"`)
		if r.Method == "GET" {
			_, _ = w.Write(blob)
		}
	}))
	defer fixture.Close()
	command := exec.Command(tool, "-upstream", fixture.URL, "-assets", os.Getenv("CLIPMAN_WEB_FIXTURE_ASSETS"), "-port", "41821", "-duration", "10m")
	command.Stdout, command.Stderr = os.Stdout, os.Stderr
	if err := command.Start(); err != nil {
		t.Fatal(err)
	}
	defer func() { _ = command.Process.Kill(); _ = command.Wait() }()
	fmt.Printf("FIXTURE_URL=%s\n", fixture.URL)
	select {
	case <-stop:
	case <-time.After(8 * time.Minute):
		t.Fatal("browser fixture expired")
	}
}

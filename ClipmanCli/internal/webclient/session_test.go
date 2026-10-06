package webclient

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/OnjLouis/Clipman/ClipmanCli/internal/clipdb"
	"github.com/OnjLouis/Clipman/ClipmanCli/internal/identity"
	"github.com/OnjLouis/Clipman/ClipmanCli/internal/model"
)

func TestBrowserSessionRoundTripAndConflict(t *testing.T) {
	password, token := "disposable-history", "disposable-token"
	now := time.Now().UnixMilli()
	db := model.NewDatabase(now)
	db.Extra["FutureField"] = json.RawMessage(`{"keep":true}`)
	db.Entries = []model.Entry{
		{ID: "old", Text: "<img src=x onerror=alert(1)>", Name: "Literal <script>", CreatedUnixMs: now, LastUsedUnixMs: now, Extra: map[string]json.RawMessage{"RichText": json.RawMessage(`null`)}},
		{ID: "image", Text: "image marker", Extra: map[string]json.RawMessage{"RichText": json.RawMessage(`{"x":1}`)}},
		{ID: "template", Text: "private template", IsTemplate: true},
	}
	db.Deleted = []model.DeletedEntry{{ID: "deleted", DeletedUnixMs: now}}
	blob, err := clipdb.Encode(db, password, nil)
	if err != nil {
		t.Fatal(err)
	}
	var mu sync.Mutex
	puts := 0
	conflict := false
	revision := func() string { h := sha256.Sum256(blob); return hex.EncodeToString(h[:]) }
	fixture := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		mu.Lock()
		defer mu.Unlock()
		if r.Header.Get("Authorization") != "Bearer "+token {
			w.WriteHeader(401)
			return
		}
		if !strings.HasSuffix(r.URL.Path, identity.DatabaseID(token, password)) {
			w.WriteHeader(404)
			return
		}
		if r.Method == "PUT" {
			puts++
			if conflict {
				conflict = false
				fresh, _ := clipdb.Decode(blob, password, clipdb.DefaultLimits())
				fresh.Entries = append(fresh.Entries, model.Entry{ID: "concurrent", Text: "Another client's note", CreatedUnixMs: now, LastUsedUnixMs: now})
				blob, _ = clipdb.Encode(fresh, password, blob)
				w.WriteHeader(409)
				return
			}
			if r.Header.Get("If-Match") != `"`+revision()+`"` {
				w.WriteHeader(409)
				return
			}
			incoming, _ := io.ReadAll(r.Body)
			if !strings.HasPrefix(string(incoming), "CLIPDB2") {
				t.Error("unencrypted upload")
			}
			blob = incoming
		}
		w.Header().Set("ETag", `"`+revision()+`"`)
		if r.Method == "GET" {
			_, _ = w.Write(blob)
		}
	}))
	defer fixture.Close()
	ctx := context.Background()
	s, err := Connect(ctx, fixture.URL, token, password, "Browser test", nil)
	if err != nil {
		t.Fatal(err)
	}
	rows := s.Rows()
	if len(rows) != 1 || rows[0].Text != db.Entries[0].Text {
		t.Fatalf("rows: %#v", rows)
	}
	if puts != 0 {
		t.Fatal("opening history wrote data")
	}
	if copied, err := s.Copy("old"); err != nil || copied != db.Entries[0].Text {
		t.Fatalf("plain clip with null formatting cannot be copied: %q, %v", copied, err)
	}
	mu.Lock()
	conflict = true
	mu.Unlock()
	if err := s.Add(ctx, "Browser quick clip", "Test name"); err != nil {
		t.Fatal(err)
	}
	mu.Lock()
	saved, err := clipdb.Decode(blob, password, clipdb.DefaultLimits())
	mu.Unlock()
	if err != nil {
		t.Fatal(err)
	}
	if len(saved.Entries) != 5 || len(saved.Deleted) != 1 || string(saved.Extra["FutureField"]) != `{"keep":true}` {
		t.Fatalf("data lost: %#v", saved)
	}
	if puts != 2 {
		t.Fatalf("wanted conflict retry, got %d puts", puts)
	}
	s.Close()
	if len(s.Rows()) != 0 || s.Add(ctx, "blocked", "") == nil {
		t.Fatal("closed session remained usable")
	}
}

func TestPasswordFailureCannotWrite(t *testing.T) {
	blob, _ := clipdb.Encode(model.NewDatabase(time.Now().UnixMilli()), "correct", nil)
	puts := 0
	fixture := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method == "PUT" {
			puts++
			w.WriteHeader(500)
			return
		}
		if strings.HasSuffix(r.URL.Path, identity.SyncRulesDatabaseID("token", "wrong")) {
			w.WriteHeader(404)
			return
		}
		_, _ = w.Write(blob)
	}))
	defer fixture.Close()
	if _, err := Connect(context.Background(), fixture.URL, "token", "wrong", "Browser", nil); err == nil {
		t.Fatal("wrong password accepted")
	}
	if puts != 0 {
		t.Fatal("failed unlock wrote data")
	}
}

func TestMissingHistoryCannotBecomeANewBucket(t *testing.T) {
	puts := 0
	fixture := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method == "PUT" {
			puts++
		}
		w.WriteHeader(404)
	}))
	defer fixture.Close()
	if _, err := Connect(context.Background(), fixture.URL, "token", "wrong-or-new-password", "Browser", nil); err == nil {
		t.Fatal("missing history accepted")
	}
	if puts != 0 {
		t.Fatal("new bucket created")
	}
}

func TestBrowserRejectsUnauthenticatedHistoryContainers(t *testing.T) {
	for _, password := range []string{"", "correct"} {
		t.Run(map[bool]string{true: "unencrypted", false: "tampered"}[password == ""], func(t *testing.T) {
			blob, err := clipdb.Encode(model.NewDatabase(time.Now().UnixMilli()), password, nil)
			if err != nil {
				t.Fatal(err)
			}
			if password != "" {
				blob[len(blob)-1] ^= 1
			}
			puts := 0
			fixture := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				if r.Method == "PUT" {
					puts++
					w.WriteHeader(500)
					return
				}
				_, _ = w.Write(blob)
			}))
			defer fixture.Close()
			if session, err := Connect(context.Background(), fixture.URL, "token", "correct", "Browser", nil); err == nil {
				session.Close()
				t.Fatal("unauthenticated history was accepted")
			}
			if puts != 0 {
				t.Fatal("rejected history wrote server data")
			}
		})
	}
}

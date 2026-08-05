package syncengine

import (
	"context"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/OnjLouis/Clipman/ClipmanLinuxBackend/internal/clipdb"
	"github.com/OnjLouis/Clipman/ClipmanLinuxBackend/internal/model"
	"github.com/OnjLouis/Clipman/ClipmanLinuxBackend/internal/operation"
	"github.com/OnjLouis/Clipman/ClipmanLinuxBackend/internal/server"
)

func TestFirstWriterConflictMergesBothEntries(t *testing.T) {
	password := "test-password"
	limits := clipdb.DefaultLimits()
	remote := model.NewDatabase(1000)
	remote.Entries = append(remote.Entries, model.Entry{ID: "remote-entry", Text: "remote", CreatedUnixMs: 1000, LastUsedUnixMs: 1000})
	remoteBlob, err := clipdb.Encode(remote, password, nil)
	if err != nil {
		t.Fatal(err)
	}

	var lock sync.Mutex
	var blob []byte
	revision := ""
	firstCreate := true
	handler := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		lock.Lock()
		defer lock.Unlock()
		switch r.Method {
		case http.MethodGet:
			if blob == nil {
				http.NotFound(w, r)
				return
			}
			w.Header().Set("X-Clipman-Revision", revision)
			_, _ = w.Write(blob)
		case http.MethodPut:
			data, readErr := io.ReadAll(r.Body)
			if readErr != nil {
				t.Fatal(readErr)
			}
			if firstCreate {
				if r.Header.Get("If-None-Match") != "*" {
					t.Errorf("first write If-None-Match = %q", r.Header.Get("If-None-Match"))
				}
				firstCreate = false
				blob = remoteBlob
				revision = "remote-revision"
				w.WriteHeader(http.StatusPreconditionFailed)
				return
			}
			if strings.Trim(r.Header.Get("If-Match"), "\"") != revision {
				t.Errorf("retry If-Match = %q, want %q", r.Header.Get("If-Match"), revision)
			}
			blob = data
			revision = "merged-revision"
			w.Header().Set("X-Clipman-Revision", revision)
			w.WriteHeader(http.StatusOK)
		default:
			w.WriteHeader(http.StatusMethodNotAllowed)
		}
	})
	testServer := httptest.NewServer(handler)
	defer testServer.Close()

	client, err := server.New(testServer.URL, "token", "bucket", "test")
	if err != nil {
		t.Fatal(err)
	}
	client.HTTP = testServer.Client()
	engine := Engine{Client: client, Password: password, Limits: limits, Retries: 2}
	newID := "local-entry"
	_, err = engine.Mutate(context.Background(), func(database *model.Database, now int64) (bool, any, error) {
		entry, outcome := operation.Put(database, "local", "", "", "test", "keep", newID, false, false, now)
		return outcome != "ignored", entry, nil
	})
	if err != nil {
		t.Fatal(err)
	}

	lock.Lock()
	finalBlob := append([]byte(nil), blob...)
	lock.Unlock()
	final, err := clipdb.Decode(finalBlob, password, limits)
	if err != nil {
		t.Fatal(err)
	}
	seen := map[string]bool{}
	for _, entry := range final.Entries {
		seen[entry.ID] = true
	}
	if !seen["remote-entry"] || !seen["local-entry"] || len(final.Entries) != 2 {
		t.Fatalf("merged entries = %#v", final.Entries)
	}
}

func TestReadPropagatesNonNotFoundErrors(t *testing.T) {
	client, err := server.New("http://127.0.0.1:1", "token", "bucket", "test")
	if err != nil {
		t.Fatal(err)
	}
	client.HTTP = &http.Client{Transport: roundTripFunc(func(*http.Request) (*http.Response, error) {
		return nil, errors.New("offline")
	}), Timeout: time.Second}
	engine := Engine{Client: client, Limits: clipdb.DefaultLimits()}
	if _, err := engine.Read(context.Background()); err == nil {
		t.Fatal("expected read error")
	}
}

func TestMutateStateReturnsCommittedStateWithoutSecondDownload(t *testing.T) {
	password := "test-password"
	limits := clipdb.DefaultLimits()
	database := model.NewDatabase(1000)
	blob, err := clipdb.Encode(database, password, nil)
	if err != nil {
		t.Fatal(err)
	}
	getCount := 0
	putCount := 0
	handler := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.Method {
		case http.MethodGet:
			getCount++
			w.Header().Set("X-Clipman-Revision", "before")
			_, _ = w.Write(blob)
		case http.MethodPut:
			putCount++
			w.Header().Set("X-Clipman-Revision", "after")
			w.WriteHeader(http.StatusOK)
		default:
			w.WriteHeader(http.StatusMethodNotAllowed)
		}
	})
	testServer := httptest.NewServer(handler)
	defer testServer.Close()
	client, err := server.New(testServer.URL, "token", "bucket", "test")
	if err != nil {
		t.Fatal(err)
	}
	client.HTTP = testServer.Client()
	engine := Engine{Client: client, Password: password, Limits: limits}
	_, state, err := engine.MutateState(context.Background(), func(database *model.Database, now int64) (bool, any, error) {
		entry, outcome := operation.Put(database, "local", "", "", "test", "keep", "local-entry", false, false, now)
		return outcome != "ignored", entry, nil
	})
	if err != nil {
		t.Fatal(err)
	}
	if getCount != 1 || putCount != 1 {
		t.Fatalf("requests = GET %d, PUT %d; want one of each", getCount, putCount)
	}
	if state.Revision != "after" || !state.Exists || len(state.Blob) == 0 || len(state.Database.Entries) != 1 {
		t.Fatalf("committed state = %#v", state)
	}
}

type roundTripFunc func(*http.Request) (*http.Response, error)

func (fn roundTripFunc) RoundTrip(request *http.Request) (*http.Response, error) { return fn(request) }

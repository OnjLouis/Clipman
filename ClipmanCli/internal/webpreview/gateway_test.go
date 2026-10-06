package webpreview

import (
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestGatewayBoundaries(t *testing.T) {
	calls := 0
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		calls++
		if r.Header.Get("Cookie") != "" || r.Header.Get("X-Clipman-Preview") != "" {
			t.Error("local session header leaked")
		}
		if r.Header.Get("Authorization") != "Bearer test" {
			t.Error("missing token")
		}
		if r.Method == "PUT" && r.Header.Get("If-Match") != `"revision"` {
			t.Error("precondition lost")
		}
		w.Header().Set("ETag", `"revision"`)
		_, _ = io.WriteString(w, "CLIPDB2-encrypted-fixture")
	}))
	defer upstream.Close()
	g, err := New(upstream.URL, "http://127.0.0.1:8123", "local-key", nil)
	if err != nil {
		t.Fatal(err)
	}
	path := "/relay/api/v1/database/" + strings.Repeat("a", 43)
	for _, tc := range []struct {
		name, method, path, host, origin, key, body string
		want                                        int
	}{
		{"read", "GET", path, "127.0.0.1:8123", "", "local-key", "", 200},
		{"write", "PUT", path, "127.0.0.1:8123", "http://127.0.0.1:8123", "local-key", "CLIPDB2-fixture", 200},
		{"no key", "GET", path, "127.0.0.1:8123", "", "", "", 403},
		{"cross site", "PUT", path, "127.0.0.1:8123", "https://evil.example", "local-key", "CLIPDB2-fixture", 403},
		{"rebinding", "GET", path, "evil.example:8123", "", "local-key", "", 403},
		{"delete", "DELETE", path, "127.0.0.1:8123", "", "local-key", "", 405},
		{"plain write", "PUT", path, "127.0.0.1:8123", "http://127.0.0.1:8123", "local-key", "plaintext", 400},
		{"unguarded write", "PUT", path, "127.0.0.1:8123", "http://127.0.0.1:8123", "local-key", "CLIPDB2-fixture", 400},
		{"path escape", "GET", "/relay/other", "127.0.0.1:8123", "", "local-key", "", 404},
	} {
		t.Run(tc.name, func(t *testing.T) {
			r := httptest.NewRequest(tc.method, "http://"+tc.host+tc.path, strings.NewReader(tc.body))
			r.Header.Set("Origin", tc.origin)
			r.Header.Set("X-Clipman-Preview", tc.key)
			r.Header.Set("Authorization", "Bearer test")
			if tc.name != "unguarded write" {
				r.Header.Set("If-Match", `"revision"`)
			}
			w := httptest.NewRecorder()
			g.ServeHTTP(w, r)
			if w.Code != tc.want {
				t.Fatalf("%d, want %d: %s", w.Code, tc.want, w.Body.String())
			}
			if w.Header().Get("Cache-Control") != "no-store" {
				t.Error("cache enabled")
			}
		})
	}
	if calls != 2 {
		t.Fatalf("unexpected forwarded calls: %d", calls)
	}
}

package main

import (
	"context"
	"crypto/rand"
	"embed"
	"encoding/base64"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"os/signal"
	"path/filepath"
	"strings"
	"time"

	"github.com/OnjLouis/Clipman/ClipmanCli/internal/server"
	"github.com/OnjLouis/Clipman/ClipmanCli/internal/webpreview"
)

//go:embed ui/*
var ui embed.FS

func main() {
	upstream := flag.String("upstream", "", "fixed Clipman Server address")
	connection := flag.String("connection-file", "", "optional private connection file (address/authority only)")
	bootstrap := flag.Bool("bootstrap-stdin", false, "read a private connection file from stdin and prefill its token for this local session")
	assets := flag.String("assets", "", "folder containing client.wasm, wasm_exec.js and icon.png")
	port := flag.Int("port", 0, "loopback port, or zero for an available port")
	duration := flag.Duration("duration", 2*time.Hour, "maximum local preview lifetime")
	flag.Parse()
	var opts []server.Option
	var initialToken string
	if *connection != "" || *bootstrap {
		var data []byte
		var err error
		if *bootstrap {
			data, err = io.ReadAll(io.LimitReader(os.Stdin, 32769))
		} else {
			data, err = os.ReadFile(*connection)
		}
		if err != nil {
			fatal("could not read connection file")
		}
		if len(data) > 32768 {
			fatal("connection file is too large")
		}
		address, token, authority, err := server.ConnectionProfile(string(data))
		if err != nil {
			fatal("invalid connection file")
		}
		*upstream = address
		if *bootstrap {
			initialToken = token
		}
		if authority != "" {
			opts = append(opts, server.WithExclusiveCACertPEM([]byte(authority)))
		}
	}
	client, err := server.New(*upstream, "", "", "web-preview", opts...)
	if err != nil {
		fatal("invalid fixed server address")
	}
	if *assets == "" || *duration <= 0 || *duration > 8*time.Hour {
		fatal("assets and a lifetime of at most eight hours are required")
	}
	for _, file := range []string{"client.wasm", "wasm_exec.js", "icon.png"} {
		if info, err := os.Stat(filepath.Join(*assets, file)); err != nil || !info.Mode().IsRegular() {
			fatal("missing browser asset")
		}
	}
	listener, err := net.Listen("tcp4", fmt.Sprintf("127.0.0.1:%d", *port))
	if err != nil {
		fatal("could not bind loopback listener")
	}
	origin := "http://" + listener.Addr().String()
	keyBytes := make([]byte, 32)
	if _, err := rand.Read(keyBytes); err != nil {
		fatal("could not generate local session key")
	}
	key := base64.RawURLEncoding.EncodeToString(keyBytes)
	gateway, err := webpreview.New(client.BaseURL, origin, key, client.HTTP.Transport)
	if err != nil {
		fatal("could not configure relay")
	}
	shutdownRequested := make(chan struct{}, 1)
	mux := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		webpreview.Headers(w)
		if !gateway.Allowed(r) {
			http.Error(w, "request not allowed", 403)
			return
		}
		if strings.HasPrefix(r.URL.Path, "/relay/") {
			gateway.ServeHTTP(w, r)
			return
		}
		if r.URL.Path == "/close-preview" && r.Method == "POST" && r.Header.Get("Origin") == origin && r.Header.Get("X-Clipman-Preview") == key {
			w.WriteHeader(200)
			select {
			case shutdownRequested <- struct{}{}:
			default:
			}
			return
		}
		if r.Method != "GET" || r.URL.RawQuery != "" {
			w.WriteHeader(405)
			return
		}
		if r.URL.Path == "/preview.json" {
			w.Header().Set("Content-Type", "application/json")
			_ = json.NewEncoder(w).Encode(map[string]string{"server": client.BaseURL, "key": key, "token": initialToken})
			return
		}
		files := map[string]string{"/": "index.html", "/app.js": "app.js", "/pagination.js": "pagination.js", "/links.js": "links.js", "/purify.min.js": "purify.min.js", "/rich.js": "rich.js", "/worker.js": "worker.js", "/style.css": "style.css"}
		if file, found := files[r.URL.Path]; found {
			data, _ := ui.ReadFile("ui/" + file)
			contentType := map[string]string{"index.html": "text/html; charset=utf-8", "app.js": "text/javascript", "pagination.js": "text/javascript", "links.js": "text/javascript", "purify.min.js": "text/javascript", "rich.js": "text/javascript", "worker.js": "text/javascript", "style.css": "text/css"}
			w.Header().Set("Content-Type", contentType[file])
			_, _ = w.Write(data)
			return
		}
		if r.URL.Path == "/client.wasm" || r.URL.Path == "/wasm_exec.js" || r.URL.Path == "/icon.png" {
			if r.URL.Path == "/client.wasm" {
				w.Header().Set("Content-Type", "application/wasm")
			}
			http.ServeFile(w, r, filepath.Join(*assets, strings.TrimPrefix(r.URL.Path, "/")))
			return
		}
		w.WriteHeader(404)
	})
	host := &http.Server{Handler: mux, ReadHeaderTimeout: 5 * time.Second, ReadTimeout: 40 * time.Second, WriteTimeout: 60 * time.Second, IdleTimeout: 30 * time.Second, MaxHeaderBytes: 16384}
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt)
	defer stop()
	finished := make(chan struct{})
	go func() {
		defer close(finished)
		timer := time.NewTimer(*duration)
		defer timer.Stop()
		select {
		case <-ctx.Done():
		case <-timer.C:
		case <-shutdownRequested:
		}
		shutdown, cancel := context.WithTimeout(context.Background(), 50*time.Second)
		defer cancel()
		_ = host.Shutdown(shutdown)
	}()
	fmt.Printf("Clipman local browser preview: %s\n", origin)
	if err := host.Serve(listener); err != nil && err != http.ErrServerClosed {
		fatal("preview listener failed")
	}
	<-finished
}

func fatal(message string) { fmt.Fprintln(os.Stderr, message); os.Exit(1) }

// Package webclient adapts the existing CLI engine for an ephemeral browser client.
package webclient

import (
	"bytes"
	"context"
	"errors"
	"io"
	"net/http"
	"net/url"
	"regexp"
	"strings"
	"time"

	"github.com/OnjLouis/Clipman/ClipmanCli/internal/agent"
	"github.com/OnjLouis/Clipman/ClipmanCli/internal/clipdb"
	"github.com/OnjLouis/Clipman/ClipmanCli/internal/identity"
	"github.com/OnjLouis/Clipman/ClipmanCli/internal/model"
	"github.com/OnjLouis/Clipman/ClipmanCli/internal/operation"
	"github.com/OnjLouis/Clipman/ClipmanCli/internal/server"
	"github.com/OnjLouis/Clipman/ClipmanCli/internal/syncengine"
)

const PageSize = 100
const MaxClipBytes = 1 << 20

type Row struct {
	ID        string `json:"id"`
	Text      string `json:"text"`
	Name      string `json:"name"`
	Device    string `json:"device"`
	Group     string `json:"group"`
	Pinned    bool   `json:"pinned"`
	Created   int64  `json:"created"`
	Truncated bool   `json:"truncated"`
	Rich      bool   `json:"rich"`
	RTFOnly   bool   `json:"rtfOnly"`
	Image     bool   `json:"image"`
}

type Page struct {
	Rows   []Row `json:"rows"`
	Total  int   `json:"total"`
	Offset int   `json:"offset"`
	Size   int   `json:"size"`
}

type Session struct {
	engine *syncengine.Engine
	device string
	state  *syncengine.ViewState
}

func Connect(ctx context.Context, endpoint, token, password, device string, transport http.RoundTripper) (*Session, error) {
	if strings.TrimSpace(token) == "" || strings.TrimSpace(password) == "" || strings.TrimSpace(device) == "" {
		return nil, errors.New("server token, history password and device name are required")
	}
	client, err := server.New(endpoint, token, identity.DatabaseID(token, password), "web-preview")
	if err != nil {
		return nil, err
	}
	if transport == nil {
		transport = client.HTTP.Transport
	}
	client.HTTP.Transport = encryptedTransport{base: transport}
	if _, err := client.Head(ctx); err != nil {
		if errors.Is(err, server.ErrNotFound) {
			return nil, errors.New("no existing history for this password; this preview cannot create a new history")
		}
		return nil, err
	}
	s := &Session{engine: &syncengine.Engine{Client: client, Password: password, Token: token, Limits: clipdb.DefaultLimits()}, device: device}
	if err := s.Refresh(ctx); err != nil {
		s.Close()
		return nil, err
	}
	return s, nil
}

// Native readers retain legacy compatibility; browser sessions require the
// authenticated encrypted container on every history and rules download.
type encryptedTransport struct{ base http.RoundTripper }

func (t encryptedTransport) RoundTrip(request *http.Request) (*http.Response, error) {
	response, err := t.base.RoundTrip(request)
	if err != nil || request.Method != http.MethodGet || response.StatusCode != http.StatusOK {
		return response, err
	}
	const encryptedContainerHeader = "CLIPDB2"
	header := make([]byte, len(encryptedContainerHeader))
	if _, err := io.ReadFull(response.Body, header); err != nil || string(header) != encryptedContainerHeader {
		_ = response.Body.Close()
		return nil, errors.New("browser history requires an encrypted Clipman database")
	}
	response.Body = struct {
		io.Reader
		io.Closer
	}{
		Reader: io.MultiReader(bytes.NewReader(header), response.Body), Closer: response.Body,
	}
	return response, nil
}

func (s *Session) Refresh(ctx context.Context) error {
	if s == nil || s.engine == nil {
		return errors.New("history is locked")
	}
	state, err := s.engine.ReadViewReadOnly(ctx, s.device)
	if err != nil {
		return err
	}
	s.state = state
	return nil
}

func (s *Session) Rows() []Row { return s.Page("", 0).Rows }

func (s *Session) Page(query string, offset int) Page {
	return s.PageForArea(query, offset, "all")
}

func (s *Session) PageForArea(query string, offset int, area string) Page {
	result := Page{Rows: []Row{}, Size: PageSize}
	if s == nil || s.state == nil {
		return result
	}
	query = strings.ToLower(strings.TrimSpace(query))
	if offset < 0 {
		offset = 0
	}
	entries := operation.View(*s.state.View, operation.History, true)
	matches := entries[:0]
	for _, e := range entries {
		if area == "rich" && entryRichPayload(e) == nil || area != "rich" && !agent.Eligible(e) {
			continue
		}
		if area == "links" && !isLinkOnlyText(e.Text) || area == "text" && isLinkOnlyText(e.Text) {
			continue
		}
		if query != "" && !strings.Contains(strings.ToLower(e.Text), query) && !strings.Contains(strings.ToLower(e.Name), query) && !strings.Contains(strings.ToLower(e.Group), query) {
			continue
		}
		matches = append(matches, e)
	}
	result.Total = len(matches)
	if offset >= result.Total {
		offset = 0
		if result.Total > 0 {
			offset = (result.Total - 1) / PageSize * PageSize
		}
	}
	result.Offset = offset
	end := min(offset+PageSize, result.Total)
	for _, e := range matches[offset:end] {
		text, truncated := preview(e.Text, 4096)
		name, _ := preview(e.Name, 300)
		device, _ := preview(e.SourceMachine, 200)
		group, _ := preview(e.Group, 200)
		row := Row{ID: e.ID, Text: text, Name: name, Device: device, Group: group, Pinned: e.Pinned, Created: e.CreatedUnixMs, Truncated: truncated, Rich: area == "rich"}
		if row.Rich {
			payload := entryRichPayload(e)
			row.RTFOnly = payload.HtmlFragment == ""
			row.Image = strings.HasPrefix(payload.HtmlFragment, `<img data-clipman-image="1"`)
		}
		result.Rows = append(result.Rows, row)
	}
	return result
}

var trailingLinkRole = regexp.MustCompile(`(?i)^(\S+)\s+link$`)

func isLinkOnlyText(text string) bool {
	text = strings.TrimSpace(text)
	if text == "" || strings.ContainsAny(text, "\r\n") {
		return false
	}
	if parts := trailingLinkRole.FindStringSubmatch(text); parts != nil {
		text = parts[1]
	}
	u, err := url.Parse(text)
	if err != nil || strings.TrimSpace(u.Hostname()) == "" {
		return false
	}
	switch strings.ToLower(u.Scheme) {
	case "http", "https", "clipman":
		return true
	default:
		return false
	}
}

func (s *Session) Copy(id string) (string, error) {
	if s == nil || s.state == nil {
		return "", errors.New("history is locked")
	}
	for _, e := range s.state.View.Entries {
		if e.ID != id || !agent.Eligible(e) {
			continue
		}
		if len(e.Text) > MaxClipBytes {
			return "", errors.New("entry exceeds the preview's 1 MiB clipboard limit")
		}
		return e.Text, nil
	}
	return "", errors.New("entry is no longer available; refresh history")
}

func (s *Session) Add(ctx context.Context, text, name string) error {
	if s == nil || s.engine == nil {
		return errors.New("history is locked")
	}
	if strings.TrimSpace(text) == "" {
		return errors.New("enter text or a link first")
	}
	if len(text) > MaxClipBytes || len(name) > 1024 {
		return errors.New("clip or name exceeds the preview's size limit")
	}
	// Use the normal channel-aware mutation path, not a replacement snapshot.
	state, err := s.engine.MutateView(ctx, s.device, func(db *model.Database) error {
		operation.Put(db, text, name, "", s.device, "ignore", "", false, false, time.Now().UnixMilli())
		return nil
	})
	if err != nil {
		return err
	}
	s.state = state
	return nil
}

func (s *Session) Close() {
	if s == nil {
		return
	}
	if s.engine != nil {
		s.engine.Password = ""
		s.engine.Token = ""
		s.engine.Client.Token = ""
	}
	s.engine, s.state, s.device = nil, nil, ""
}

func preview(text string, limit int) (string, bool) {
	count := 0
	for index := range text {
		if count == limit {
			return text[:index], true
		}
		count++
	}
	return text, false
}

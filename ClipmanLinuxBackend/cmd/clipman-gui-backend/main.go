package main

import (
	"bufio"
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"net/url"
	"os"
	"os/signal"
	"path/filepath"
	"regexp"
	"runtime"
	"sort"
	"strings"
	"sync"
	"syscall"
	"time"
	"unicode/utf8"

	"github.com/OnjLouis/Clipman/ClipmanLinuxBackend/internal/clipdb"
	"github.com/OnjLouis/Clipman/ClipmanLinuxBackend/internal/config"
	"github.com/OnjLouis/Clipman/ClipmanLinuxBackend/internal/identity"
	"github.com/OnjLouis/Clipman/ClipmanLinuxBackend/internal/merge"
	"github.com/OnjLouis/Clipman/ClipmanLinuxBackend/internal/model"
	"github.com/OnjLouis/Clipman/ClipmanLinuxBackend/internal/operation"
	"github.com/OnjLouis/Clipman/ClipmanLinuxBackend/internal/platform"
	"github.com/OnjLouis/Clipman/ClipmanLinuxBackend/internal/server"
	"github.com/OnjLouis/Clipman/ClipmanLinuxBackend/internal/syncengine"
	tmpl "github.com/OnjLouis/Clipman/ClipmanLinuxBackend/internal/template"
)

const protocolVersion = 1

const (
	maxRichHTMLBytes     = 768 * 1024
	maxRichRTFBytes      = 1024 * 1024
	maxRichCombinedBytes = 1792 * 1024
)

var standaloneURL = regexp.MustCompile(`(?i)^(?:(?:https?://|clipman://|www\.)\S+|(?:[a-z0-9](?:[a-z0-9-]*[a-z0-9])?\.)+[a-z]{2,}(?::\d+)?(?:/\S*)?)$`)

type request struct {
	ID     int64           `json:"id"`
	Action string          `json:"action"`
	Params json.RawMessage `json:"params"`
}

type response struct {
	ID     int64  `json:"id,omitempty"`
	OK     bool   `json:"ok"`
	Result any    `json:"result,omitempty"`
	Error  string `json:"error,omitempty"`
}

type session struct {
	mu         sync.Mutex
	configPath string
	cachePath  string
	cfg        config.Config
	password   string
	client     *server.Client
	engine     *syncengine.Engine
	database   model.Database
	filePath   string
	fileDB     model.FileDatabase
	fileLoaded bool
	revision   string
	loaded     bool
	offline    bool
}

var version = "0.1.0-preview"

type entryJSON struct {
	ID                    string        `json:"id"`
	Text                  string        `json:"text"`
	Name                  string        `json:"name"`
	Group                 string        `json:"group"`
	Device                string        `json:"device"`
	CreatedUnixMs         int64         `json:"created_unix_ms"`
	LastUsedUnixMs        int64         `json:"last_used_unix_ms"`
	ModifiedUnixMs        int64         `json:"modified_unix_ms"`
	Pinned                bool          `json:"pinned"`
	IsTemplate            bool          `json:"is_template"`
	ManualOrder           int64         `json:"manual_order"`
	Section               string        `json:"section"`
	Display               string        `json:"display"`
	RichText              *richTextJSON `json:"rich_text,omitempty"`
	RichTextUpdatedUnixMs int64         `json:"rich_text_updated_unix_ms,omitempty"`
}

type richTextJSON struct {
	Version         int    `json:"version"`
	HTMLFragment    string `json:"html_fragment"`
	RTFBase64       string `json:"rtf_base64"`
	PreferredFormat string `json:"preferred_format"`
}

type storedRichText struct {
	Version         int    `json:"Version"`
	HTMLFragment    string `json:"HtmlFragment"`
	RTFBase64       string `json:"RtfBase64"`
	PreferredFormat string `json:"PreferredFormat"`
}

func main() {
	configPath := flag.String("config", "", "Clipman Linux GUI configuration path")
	flag.Parse()
	path, err := platform.ConfigPath(*configPath)
	if err != nil {
		write(response{OK: false, Error: "Cannot locate Clipman configuration: " + err.Error()})
		return
	}
	dir, err := platform.ConfigDir()
	if err != nil {
		write(response{OK: false, Error: "Cannot locate Clipman data directory: " + err.Error()})
		return
	}
	s := &session{configPath: path, cachePath: filepath.Join(dir, "gui-cache.clipdb"), cfg: config.Default()}
	s.loadConfiguration()
	write(response{OK: true, Result: map[string]any{
		"event": "ready", "protocol": protocolVersion, "configured": config.Exists(path),
		"needs_password": s.engine == nil && config.Exists(path), "config_path": path,
	}})

	signals := make(chan os.Signal, 1)
	signal.Notify(signals, syscall.SIGINT, syscall.SIGTERM)
	go func() { <-signals; os.Exit(0) }()

	scanner := bufio.NewScanner(os.Stdin)
	scanner.Buffer(make([]byte, 64*1024), 70<<20)
	for scanner.Scan() {
		var req request
		if err := json.Unmarshal(scanner.Bytes(), &req); err != nil {
			write(response{OK: false, Error: "Invalid backend request"})
			continue
		}
		result, err := s.handle(req.Action, req.Params)
		if err != nil {
			write(response{ID: req.ID, OK: false, Error: friendlyError(err)})
		} else {
			write(response{ID: req.ID, OK: true, Result: result})
		}
		if req.Action == "shutdown" {
			return
		}
	}
}

func (s *session) handle(action string, raw json.RawMessage) (any, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	switch action {
	case "configuration":
		return s.configurationResult(), nil
	case "connection_details":
		var p struct {
			Text string `json:"text"`
		}
		if err := decode(raw, &p); err != nil {
			return nil, err
		}
		address, token, caCertPEM, err := server.ConnectionProfile(p.Text)
		if err != nil {
			return nil, err
		}
		if address == "" || token == "" {
			return nil, errors.New("the selected file does not contain Clipman Server connection details")
		}
		result := map[string]string{"server": address, "token": token, "ca_cert_pem": caCertPEM}
		if caCertPEM != "" {
			authority, _ := server.ParsePrivateAuthority([]byte(caCertPEM), address)
			result["ca_host"] = authority.Host
			result["ca_subject"] = authority.Subject
			result["ca_expires"] = authority.Expires.Format("2 January 2006")
			result["ca_fingerprint"] = authority.Fingerprint
		}
		return result, nil
	case "authority_details":
		var p struct{ Text, Server string }
		if err := decode(raw, &p); err != nil {
			return nil, err
		}
		authority, err := server.ParsePrivateAuthority([]byte(p.Text), p.Server)
		if err != nil {
			return nil, err
		}
		if authority.PEM == "" {
			return nil, errors.New("the selected file does not contain a certificate authority")
		}
		return map[string]string{
			"ca_cert_pem": authority.PEM, "ca_host": authority.Host,
			"ca_subject": authority.Subject, "ca_expires": authority.Expires.Format("2 January 2006"),
			"ca_fingerprint": authority.Fingerprint,
		}, nil
	case "configure":
		return s.configure(raw)
	case "unlock":
		var p struct {
			Password string `json:"password"`
			Remember bool   `json:"remember"`
		}
		if err := decode(raw, &p); err != nil {
			return nil, err
		}
		if strings.TrimSpace(p.Password) == "" {
			return nil, errors.New("history password cannot be blank")
		}
		if err := s.activate(s.cfg, p.Password); err != nil {
			return nil, err
		}
		if p.Remember {
			protected, err := config.ProtectForConfig(p.Password)
			if err != nil {
				return nil, err
			}
			s.cfg.PasswordMode, s.cfg.PasswordProtected, s.cfg.Password = "config", protected, ""
			if err := config.Save(s.configPath, s.cfg); err != nil {
				return nil, err
			}
		}
		return s.refresh(true)
	case "refresh":
		var p struct {
			Force bool `json:"force"`
		}
		if err := decode(raw, &p); err != nil {
			return nil, err
		}
		return s.refresh(p.Force)
	case "put":
		return s.put(raw)
	case "put_after":
		return s.putAfter(raw)
	case "update":
		return s.update(raw)
	case "update_many":
		return s.updateMany(raw)
	case "delete":
		return s.delete(raw)
	case "delete_many":
		return s.deleteMany(raw)
	case "pin":
		return s.pin(raw)
	case "pin_many":
		return s.pinMany(raw)
	case "swap":
		return s.swap(raw)
	case "touch":
		return s.touch(raw)
	case "touch_many":
		return s.touchMany(raw)
	case "resolve_template":
		var p struct {
			ID string `json:"id"`
		}
		if err := decode(raw, &p); err != nil {
			return nil, err
		}
		entry, err := s.find(p.ID)
		if err != nil {
			return nil, err
		}
		return map[string]string{"text": resolved(entry)}, nil
	case "resolve_many":
		var p struct {
			IDs []string `json:"ids"`
		}
		if err := decode(raw, &p); err != nil {
			return nil, err
		}
		texts := make([]string, 0, len(p.IDs))
		for _, id := range p.IDs {
			entry, err := s.find(id)
			if err != nil {
				return nil, err
			}
			texts = append(texts, resolved(entry))
		}
		return map[string][]string{"texts": texts}, nil
	case "resolve_template_text":
		var p struct {
			Text string `json:"text"`
		}
		if err := decode(raw, &p); err != nil {
			return nil, err
		}
		return map[string]string{"text": tmpl.Resolve(p.Text, time.Now())}, nil
	case "file_add":
		return s.addFileEvent(raw)
	case "file_delete":
		return s.deleteFileEvent(raw)
	case "file_delete_many":
		return s.deleteFileEvents(raw)
	case "file_pin":
		return s.pinFileEvent(raw)
	case "file_pin_many":
		return s.pinFileEvents(raw)
	case "file_swap":
		return s.swapFileEvents(raw)
	case "file_clear":
		return s.clearFileEvents()
	case "file_remove_unavailable":
		return s.removeUnavailableFileEvents()
	case "clear_history":
		return s.clearHistory(raw)
	case "push":
		return s.pushEntries(raw)
	case "import":
		return s.importHistory(raw)
	case "export":
		return s.exportHistory(raw)
	case "secrets_list":
		return s.listSecrets(raw)
	case "secret_put":
		return s.putSecret(raw)
	case "secret_get":
		return s.getSecret(raw)
	case "secret_delete":
		return s.deleteSecret(raw)
	case "shutdown":
		return map[string]bool{"stopped": true}, nil
	default:
		return nil, fmt.Errorf("unknown backend action %q", action)
	}
}

func (s *session) loadConfiguration() {
	cfg, err := config.Load(s.configPath)
	if err != nil {
		return
	}
	s.cfg = cfg
	password, ok, err := cfg.ResolvedPassword()
	if err == nil && ok && password != "" {
		_ = s.activate(cfg, password)
	}
}

func (s *session) configurationResult() map[string]any {
	token, _ := s.cfg.ResolvedToken()
	result := map[string]any{
		"configured": config.Exists(s.configPath), "server": s.cfg.Server,
		"token_present": token != "", "machine": s.cfg.Machine,
		"password_saved": strings.EqualFold(s.cfg.PasswordMode, "config") && s.cfg.PasswordProtected != "",
		"unlocked":       s.engine != nil, "config_path": s.configPath,
		"ca_cert_pem": s.cfg.CACertPEM, "ca_host": s.cfg.CAHost,
	}
	if s.cfg.CACertPEM != "" {
		if authority, err := server.ParsePrivateAuthority([]byte(s.cfg.CACertPEM), s.cfg.Server); err == nil {
			result["ca_subject"] = authority.Subject
			result["ca_expires"] = authority.Expires.Format("2 January 2006")
			result["ca_fingerprint"] = authority.Fingerprint
		}
	}
	return result
}

func (s *session) configure(raw json.RawMessage) (any, error) {
	var p struct {
		Server, Token, Password, Machine, CACertPEM, CAHost string
		Remember                                            bool
	}
	if err := decode(raw, &p); err != nil {
		return nil, err
	}
	p.Server = strings.TrimSpace(p.Server)
	p.Token = server.CleanToken(p.Token)
	p.Machine = strings.TrimSpace(p.Machine)
	if p.Token == "" {
		storedToken, err := s.cfg.ResolvedToken()
		if err != nil {
			return nil, err
		}
		if storedToken != "" {
			p.Token = storedToken
		}
	}
	if p.Password == "" {
		p.Password = s.password
	}
	if p.Server == "" || p.Token == "" || p.Password == "" {
		return nil, errors.New("server address, token, and history password are required")
	}
	if p.Machine == "" {
		p.Machine, _ = os.Hostname()
	}
	normalized, err := server.NormalizeURL(p.Server)
	if err != nil {
		return nil, err
	}
	if server.IsInsecureRemoteURL(normalized) {
		return nil, errors.New("plain HTTP is only allowed on localhost, private networks, or VPN addresses; use HTTPS for a public server")
	}
	cfg := config.Default()
	cfg.Server, cfg.Machine, cfg.PinnedFirst = normalized, p.Machine, true
	if strings.TrimSpace(p.CACertPEM) != "" {
		authority, authorityErr := server.ParsePrivateAuthority([]byte(p.CACertPEM), normalized)
		if authorityErr != nil {
			return nil, authorityErr
		}
		if strings.TrimSpace(p.CAHost) != "" && !strings.EqualFold(strings.TrimSpace(p.CAHost), authority.Host) {
			return nil, errors.New("private certificate authority is configured for a different server host")
		}
		cfg.CACertPEM, cfg.CAHost = authority.PEM, authority.Host
	}
	cfg.TokenProtected, err = config.ProtectForConfig(p.Token)
	if err != nil {
		return nil, err
	}
	if p.Remember {
		cfg.PasswordMode = "config"
		cfg.PasswordProtected, err = config.ProtectForConfig(p.Password)
		if err != nil {
			return nil, err
		}
	} else {
		cfg.PasswordMode = "prompt"
	}
	if err := s.activate(cfg, p.Password); err != nil {
		return nil, err
	}
	if err := config.Save(s.configPath, cfg); err != nil {
		return nil, err
	}
	s.cfg = cfg
	return s.refresh(true)
}

func (s *session) activate(cfg config.Config, password string) error {
	previousPassword := s.password
	token, err := cfg.ResolvedToken()
	if err != nil {
		return err
	}
	if strings.TrimSpace(token) == "" {
		return errors.New("server token is missing")
	}
	databaseID := identity.DatabaseID(token, password)
	var options []server.Option
	if cfg.CACertPEM != "" {
		options = append(options, server.WithExclusiveCACertPEM([]byte(cfg.CACertPEM)))
	}
	client, err := server.New(cfg.Server, token, databaseID, "clipman-linux/"+version+" ("+runtime.GOOS+"/"+runtime.GOARCH+")", options...)
	if err != nil {
		return err
	}
	limits := clipdb.Limits{MaxBlobBytes: cfg.Limits.MaxBlobBytes, MaxJSONBytes: cfg.Limits.MaxJSONBytes, MaxEntries: cfg.Limits.MaxEntries, MaxTextBytes: cfg.Limits.MaxTextBytes}
	engine := &syncengine.Engine{Client: client, Password: password, Limits: limits, Retries: 3}
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	if _, err = client.Health(ctx); err != nil {
		return fmt.Errorf("server connection failed: %w", err)
	}
	state, err := engine.Read(ctx)
	if err != nil {
		return fmt.Errorf("history could not be opened; check the history password: %w", err)
	}
	candidate := &session{
		configPath: s.configPath,
		cfg:        cfg,
		password:   password,
		engine:     engine,
	}
	if err := candidate.loadFileHistory(previousPassword); err != nil {
		return fmt.Errorf("file history could not be opened; check the history password: %w", err)
	}
	s.cfg, s.password, s.client, s.engine = cfg, password, client, engine
	s.filePath, s.fileDB, s.fileLoaded = candidate.filePath, candidate.fileDB, candidate.fileLoaded
	s.normalizeFileHistory()
	s.setState(state, false)
	return nil
}

func (s *session) refresh(force bool) (any, error) {
	if s.engine == nil {
		return nil, errors.New("Clipman is not configured or the history password has not been entered")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	if !force && s.loaded && s.revision != "" {
		metadata, err := s.client.Head(ctx)
		if err == nil && metadata.Revision == s.revision {
			s.offline = false
			return s.historyResult(false), nil
		}
	}
	state, err := s.engine.Read(ctx)
	if err != nil {
		if s.loaded {
			s.offline = true
			return s.historyResult(false), nil
		}
		if cache, cacheErr := platform.ReadPrivate(s.cachePath); cacheErr == nil {
			db, decodeErr := clipdb.Decode(cache, s.password, s.engine.Limits)
			if decodeErr == nil {
				s.database, s.loaded, s.offline = db, true, true
				return s.historyResult(true), nil
			}
		}
		return nil, fmt.Errorf("server history is unavailable: %w", err)
	}
	s.setState(state, false)
	return s.historyResult(true), nil
}

func (s *session) setState(state syncengine.State, offline bool) {
	s.database, s.revision, s.loaded, s.offline = state.Database, state.Revision, true, offline
	if len(state.Blob) > 0 {
		_ = platform.SavePrivate(s.cachePath, state.Blob)
	}
}

func (s *session) historyResult(changed bool) map[string]any {
	entries := make([]entryJSON, 0, len(s.database.Entries))
	for _, entry := range s.database.Entries {
		entries = append(entries, exportEntry(entry))
	}
	sort.SliceStable(entries, func(i, j int) bool {
		if entries[i].Pinned != entries[j].Pinned {
			return entries[i].Pinned
		}
		if entries[i].ManualOrder != entries[j].ManualOrder {
			return entries[i].ManualOrder < entries[j].ManualOrder
		}
		return entries[i].CreatedUnixMs < entries[j].CreatedUnixMs
	})
	groupNames := canonicalLabels(s.database.Entries, func(entry model.Entry) string { return entry.Group })
	return map[string]any{"entries": entries, "file_events": s.exportFileEvents(), "groups": groupNames, "revision": s.revision, "changed": changed, "offline": s.offline, "server": s.client.BaseURL, "machine": s.cfg.Machine}
}

type labelStats struct {
	label  string
	count  int
	latest int64
}

func canonicalLabels(entries []model.Entry, selector func(model.Entry) string) []string {
	clusters := map[string]map[string]*labelStats{}
	for _, entry := range entries {
		label := strings.TrimSpace(selector(entry))
		if label == "" {
			continue
		}
		key := strings.ToLower(label)
		if clusters[key] == nil {
			clusters[key] = map[string]*labelStats{}
		}
		stats := clusters[key][label]
		if stats == nil {
			stats = &labelStats{label: label}
			clusters[key][label] = stats
		}
		stats.count++
		latest := entry.ModifiedUnixMs
		if entry.LastUsedUnixMs > latest {
			latest = entry.LastUsedUnixMs
		}
		if entry.CreatedUnixMs > latest {
			latest = entry.CreatedUnixMs
		}
		if latest > stats.latest {
			stats.latest = latest
		}
	}
	result := make([]string, 0, len(clusters))
	for _, spellings := range clusters {
		var winner *labelStats
		for _, candidate := range spellings {
			if winner == nil || candidate.count > winner.count ||
				(candidate.count == winner.count && candidate.latest > winner.latest) ||
				(candidate.count == winner.count && candidate.latest == winner.latest && candidate.label < winner.label) {
				winner = candidate
			}
		}
		result = append(result, winner.label)
	}
	sort.Slice(result, func(i, j int) bool {
		left, right := strings.ToLower(result[i]), strings.ToLower(result[j])
		if left == right {
			return result[i] < result[j]
		}
		return left < right
	})
	return result
}

func canonicalLabelFor(entries []model.Entry, selector func(model.Entry) string, requested string) string {
	requested = strings.TrimSpace(requested)
	if requested == "" {
		return ""
	}
	for _, label := range canonicalLabels(entries, selector) {
		if strings.EqualFold(label, requested) {
			return label
		}
	}
	return requested
}

func (s *session) mutate(fn syncengine.Mutation) (any, error) {
	if s.engine == nil {
		return nil, errors.New("history is locked")
	}
	if s.offline {
		return nil, errors.New("history is read-only while Clipman Server is unavailable")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	result, err := s.engine.Mutate(ctx, fn)
	if err != nil {
		return nil, err
	}
	state, err := s.engine.Read(ctx)
	if err != nil {
		return nil, err
	}
	s.setState(state, false)
	return map[string]any{"operation": result, "history": s.historyResult(true)}, nil
}

func (s *session) put(raw json.RawMessage) (any, error) {
	var p struct {
		Text       string        `json:"text"`
		Name       string        `json:"name"`
		Group      string        `json:"group"`
		Pinned     bool          `json:"pinned"`
		IsTemplate bool          `json:"is_template"`
		Duplicate  string        `json:"duplicate"`
		RichText   *richTextJSON `json:"rich_text"`
	}
	if err := decode(raw, &p); err != nil {
		return nil, err
	}
	if strings.TrimSpace(p.Text) == "" {
		return nil, errors.New("clipboard text cannot be empty")
	}
	if !utf8.ValidString(p.Text) {
		return nil, errors.New("clipboard text is not valid UTF-8")
	}
	if p.Duplicate == "" {
		p.Duplicate = "move"
	}
	richText := normalizeRichText(p.RichText)
	id := merge.NewID()
	return s.mutate(func(db *model.Database, now int64) (bool, any, error) {
		entry, outcome := operation.Put(db, p.Text, p.Name, p.Group, s.cfg.Machine, p.Duplicate, id, p.Pinned, p.IsTemplate, now)
		if richText != nil && outcome != "ignored" {
			for index := range db.Entries {
				if strings.EqualFold(db.Entries[index].ID, entry.ID) {
					setRichText(&db.Entries[index], richText, now)
					entry = db.Entries[index]
					break
				}
			}
		}
		return outcome != "ignored", map[string]any{"entry": exportEntry(entry), "outcome": outcome}, nil
	})
}

func (s *session) update(raw json.RawMessage) (any, error) {
	var p struct {
		ID         string `json:"id"`
		Text       string `json:"text"`
		Name       string `json:"name"`
		Group      string `json:"group"`
		Pinned     bool   `json:"pinned"`
		IsTemplate bool   `json:"is_template"`
	}
	if err := decode(raw, &p); err != nil {
		return nil, err
	}
	if strings.TrimSpace(p.Text) == "" {
		return nil, errors.New("clipboard text cannot be empty")
	}
	return s.mutate(func(db *model.Database, now int64) (bool, any, error) {
		group := canonicalLabelFor(db.Entries, func(entry model.Entry) string { return entry.Group }, p.Group)
		for i := range db.Entries {
			if strings.EqualFold(db.Entries[i].ID, p.ID) {
				e := &db.Entries[i]
				textChanged := e.Text != p.Text
				changed := textChanged || e.Name != strings.TrimSpace(p.Name) || e.Group != group || e.Pinned != p.Pinned || e.IsTemplate != p.IsTemplate
				e.Text, e.Name, e.Group, e.Pinned, e.IsTemplate = p.Text, strings.TrimSpace(p.Name), group, p.Pinned, p.IsTemplate
				if changed {
					e.LastUsedUnixMs, e.ModifiedUnixMs, e.SourceMachine, db.UpdatedUnixMs = now, now, s.cfg.Machine, now
				}
				if textChanged {
					clearRichText(e, now)
				}
				return changed, exportEntry(*e), nil
			}
		}
		return false, nil, errors.New("entry was changed or deleted by another client")
	})
}

type entryUpdate struct {
	ID         string `json:"id"`
	Text       string `json:"text"`
	Name       string `json:"name"`
	Group      string `json:"group"`
	Pinned     bool   `json:"pinned"`
	IsTemplate bool   `json:"is_template"`
}

func (s *session) updateMany(raw json.RawMessage) (any, error) {
	var p struct {
		Entries []entryUpdate `json:"entries"`
	}
	if err := decode(raw, &p); err != nil {
		return nil, err
	}
	if len(p.Entries) == 0 {
		return nil, errors.New("select at least one clipboard entry")
	}
	updates := make(map[string]entryUpdate, len(p.Entries))
	for _, item := range p.Entries {
		if strings.TrimSpace(item.ID) == "" || strings.TrimSpace(item.Text) == "" {
			return nil, errors.New("clipboard text cannot be empty")
		}
		updates[strings.ToLower(item.ID)] = item
	}
	return s.mutate(func(db *model.Database, now int64) (bool, any, error) {
		changed, found := false, 0
		for index := range db.Entries {
			item, ok := updates[strings.ToLower(db.Entries[index].ID)]
			if !ok {
				continue
			}
			found++
			entry := &db.Entries[index]
			name := strings.TrimSpace(item.Name)
			group := canonicalLabelFor(db.Entries, func(entry model.Entry) string { return entry.Group }, item.Group)
			textChanged := entry.Text != item.Text
			itemChanged := textChanged || entry.Name != name || entry.Group != group || entry.Pinned != item.Pinned || entry.IsTemplate != item.IsTemplate
			entry.Text, entry.Name, entry.Group, entry.Pinned, entry.IsTemplate = item.Text, name, group, item.Pinned, item.IsTemplate
			if itemChanged {
				entry.LastUsedUnixMs, entry.ModifiedUnixMs, entry.SourceMachine = now, now, s.cfg.Machine
				changed = true
			}
			if textChanged {
				clearRichText(entry, now)
			}
		}
		if found != len(updates) {
			return false, nil, errors.New("one or more entries were changed or deleted by another client")
		}
		if changed {
			db.UpdatedUnixMs = now
		}
		return changed, map[string]int{"updated": found}, nil
	})
}

func (s *session) delete(raw json.RawMessage) (any, error) {
	var p struct {
		ID string `json:"id"`
	}
	if err := decode(raw, &p); err != nil {
		return nil, err
	}
	entry, err := s.find(p.ID)
	if err != nil {
		return nil, err
	}
	if entry.Pinned {
		return nil, errors.New("unpin this entry before deleting it")
	}
	return s.mutate(func(db *model.Database, now int64) (bool, any, error) {
		removed, e := operation.Delete(db, p.ID, s.cfg.Machine, now)
		return e == nil, exportEntry(removed), e
	})
}

func (s *session) deleteMany(raw json.RawMessage) (any, error) {
	var p struct {
		IDs []string `json:"ids"`
	}
	if err := decode(raw, &p); err != nil {
		return nil, err
	}
	ids := normalizedIDs(p.IDs)
	if len(ids) == 0 {
		return nil, errors.New("select at least one clipboard entry")
	}
	for _, entry := range s.database.Entries {
		if ids[strings.ToLower(entry.ID)] && entry.Pinned {
			return nil, errors.New("unpin selected pinned entries before deleting them")
		}
	}
	return s.mutate(func(db *model.Database, now int64) (bool, any, error) {
		removed := 0
		for id := range ids {
			if _, err := operation.Delete(db, id, s.cfg.Machine, now); err != nil {
				return false, nil, errors.New("one or more entries were changed or deleted by another client")
			}
			removed++
		}
		if removed > 0 {
			db.UpdatedUnixMs = now
		}
		return removed > 0, map[string]int{"deleted": removed}, nil
	})
}

func (s *session) pin(raw json.RawMessage) (any, error) {
	var p struct {
		ID     string `json:"id"`
		Pinned bool   `json:"pinned"`
	}
	if err := decode(raw, &p); err != nil {
		return nil, err
	}
	return s.mutate(func(db *model.Database, now int64) (bool, any, error) {
		for i := range db.Entries {
			if strings.EqualFold(db.Entries[i].ID, p.ID) {
				if db.Entries[i].Pinned == p.Pinned {
					return false, exportEntry(db.Entries[i]), nil
				}
				db.Entries[i].Pinned, db.Entries[i].LastUsedUnixMs, db.Entries[i].ModifiedUnixMs, db.UpdatedUnixMs = p.Pinned, now, now, now
				return true, exportEntry(db.Entries[i]), nil
			}
		}
		return false, nil, errors.New("entry was changed or deleted by another client")
	})
}

func (s *session) pinMany(raw json.RawMessage) (any, error) {
	var p struct {
		IDs    []string `json:"ids"`
		Pinned bool     `json:"pinned"`
	}
	if err := decode(raw, &p); err != nil {
		return nil, err
	}
	ids := normalizedIDs(p.IDs)
	if len(ids) == 0 {
		return nil, errors.New("select at least one clipboard entry")
	}
	return s.mutate(func(db *model.Database, now int64) (bool, any, error) {
		changed, found := false, 0
		for index := range db.Entries {
			if !ids[strings.ToLower(db.Entries[index].ID)] {
				continue
			}
			found++
			if db.Entries[index].Pinned != p.Pinned {
				db.Entries[index].Pinned = p.Pinned
				db.Entries[index].LastUsedUnixMs = now
				db.Entries[index].ModifiedUnixMs = now
				changed = true
			}
		}
		if found != len(ids) {
			return false, nil, errors.New("one or more entries were changed or deleted by another client")
		}
		if changed {
			db.UpdatedUnixMs = now
		}
		return changed, map[string]int{"updated": found}, nil
	})
}

func normalizedIDs(values []string) map[string]bool {
	result := make(map[string]bool, len(values))
	for _, value := range values {
		if id := strings.ToLower(strings.TrimSpace(value)); id != "" {
			result[id] = true
		}
	}
	return result
}

func (s *session) swap(raw json.RawMessage) (any, error) {
	var p struct {
		ID      string `json:"id"`
		OtherID string `json:"other_id"`
	}
	if err := decode(raw, &p); err != nil {
		return nil, err
	}
	return s.mutate(func(db *model.Database, now int64) (bool, any, error) {
		first, second := -1, -1
		for i := range db.Entries {
			if strings.EqualFold(db.Entries[i].ID, p.ID) {
				first = i
			}
			if strings.EqualFold(db.Entries[i].ID, p.OtherID) {
				second = i
			}
		}
		if first < 0 || second < 0 {
			return false, nil, errors.New("entry was changed or deleted by another client")
		}
		if db.Entries[first].Pinned != db.Entries[second].Pinned {
			return false, nil, errors.New("pinned and normal entries cannot be moved across their separator")
		}
		db.Entries[first].ManualOrder, db.Entries[second].ManualOrder = db.Entries[second].ManualOrder, db.Entries[first].ManualOrder
		db.Entries[first].LastUsedUnixMs, db.Entries[second].LastUsedUnixMs, db.UpdatedUnixMs = now, now, now
		db.Entries[first].ModifiedUnixMs, db.Entries[second].ModifiedUnixMs = now, now
		return true, map[string]string{"id": p.ID, "other_id": p.OtherID}, nil
	})
}

func (s *session) touch(raw json.RawMessage) (any, error) {
	var p struct {
		ID string `json:"id"`
	}
	if err := decode(raw, &p); err != nil {
		return nil, err
	}
	return s.mutate(func(db *model.Database, now int64) (bool, any, error) {
		entry, e := operation.Touch(db, p.ID, now)
		return e == nil, exportEntry(entry), e
	})
}

func (s *session) touchMany(raw json.RawMessage) (any, error) {
	var p struct {
		IDs []string `json:"ids"`
	}
	if err := decode(raw, &p); err != nil {
		return nil, err
	}
	ids := normalizedIDs(p.IDs)
	if len(ids) == 0 {
		return nil, errors.New("select at least one clipboard entry")
	}
	return s.mutate(func(db *model.Database, now int64) (bool, any, error) {
		found := 0
		for index := range db.Entries {
			if !ids[strings.ToLower(db.Entries[index].ID)] {
				continue
			}
			found++
			db.Entries[index].LastUsedUnixMs = now
		}
		if found != len(ids) {
			return false, nil, errors.New("one or more entries were changed or deleted by another client")
		}
		db.UpdatedUnixMs = now
		return true, map[string]int{"updated": found}, nil
	})
}

func (s *session) find(id string) (model.Entry, error) {
	for _, entry := range s.database.Entries {
		if strings.EqualFold(entry.ID, id) {
			return entry, nil
		}
	}
	return model.Entry{}, errors.New("entry was changed or deleted by another client")
}

func resolved(entry model.Entry) string {
	if entry.IsTemplate {
		return tmpl.Resolve(entry.Text, time.Now())
	}
	return entry.Text
}

func exportEntry(entry model.Entry) entryJSON {
	display := strings.TrimSpace(entry.Name)
	if display == "" {
		display = strings.TrimSpace(strings.Split(strings.ReplaceAll(entry.Text, "\r\n", "\n"), "\n")[0])
	}
	if display == "" {
		display = "Empty entry"
	}
	richText, richTextUpdated := richTextFromEntry(entry)
	return entryJSON{ID: entry.ID, Text: entry.Text, Name: entry.Name, Group: entry.Group, Device: entry.SourceMachine, CreatedUnixMs: entry.CreatedUnixMs, LastUsedUnixMs: entry.LastUsedUnixMs, ModifiedUnixMs: entry.ModifiedUnixMs, Pinned: entry.Pinned, IsTemplate: entry.IsTemplate, ManualOrder: entry.ManualOrder, Section: section(entry.Text), Display: display, RichText: richText, RichTextUpdatedUnixMs: richTextUpdated}
}

func normalizeRichText(value *richTextJSON) *richTextJSON {
	if value == nil {
		return nil
	}
	html := value.HTMLFragment
	if len([]byte(html)) > maxRichHTMLBytes {
		html = ""
	}
	rtf := value.RTFBase64
	rtfBytes, err := base64.StdEncoding.DecodeString(rtf)
	if err != nil || len(rtfBytes) > maxRichRTFBytes {
		rtf, rtfBytes = "", nil
	}
	if len([]byte(html))+len(rtfBytes) > maxRichCombinedBytes {
		if html != "" {
			rtf, rtfBytes = "", nil
		} else {
			return nil
		}
	}
	if html == "" && len(rtfBytes) == 0 {
		return nil
	}
	preferred := strings.ToLower(strings.TrimSpace(value.PreferredFormat))
	if (preferred == "html" && html == "") ||
		(preferred == "rtf" && len(rtfBytes) == 0) ||
		(preferred != "html" && preferred != "rtf") {
		if html != "" {
			preferred = "html"
		} else {
			preferred = "rtf"
		}
	}
	return &richTextJSON{Version: 1, HTMLFragment: html, RTFBase64: rtf, PreferredFormat: strings.ToUpper(preferred[:1]) + preferred[1:]}
}

func richTextFromEntry(entry model.Entry) (*richTextJSON, int64) {
	if entry.Extra == nil {
		return nil, 0
	}
	var stored storedRichText
	if raw := entry.Extra["RichText"]; len(raw) == 0 || json.Unmarshal(raw, &stored) != nil {
		return nil, 0
	}
	normalized := normalizeRichText(&richTextJSON{Version: stored.Version, HTMLFragment: stored.HTMLFragment, RTFBase64: stored.RTFBase64, PreferredFormat: stored.PreferredFormat})
	if normalized == nil {
		return nil, 0
	}
	var updated int64
	_ = json.Unmarshal(entry.Extra["RichTextUpdatedUnixMs"], &updated)
	return normalized, updated
}

func setRichText(entry *model.Entry, value *richTextJSON, now int64) {
	if entry.Extra == nil {
		entry.Extra = map[string]json.RawMessage{}
	}
	stored := storedRichText{Version: 1, HTMLFragment: value.HTMLFragment, RTFBase64: value.RTFBase64, PreferredFormat: value.PreferredFormat}
	entry.Extra["RichText"], _ = json.Marshal(stored)
	entry.Extra["RichTextUpdatedUnixMs"], _ = json.Marshal(now)
}

func clearRichText(entry *model.Entry, now int64) {
	if entry.Extra == nil {
		entry.Extra = map[string]json.RawMessage{}
	}
	delete(entry.Extra, "RichText")
	entry.Extra["RichTextUpdatedUnixMs"], _ = json.Marshal(now)
}

func section(text string) string {
	trimmed := strings.TrimSpace(text)
	if strings.ContainsAny(trimmed, " \t\r\n") || !standaloneURL.MatchString(trimmed) {
		return "text"
	}
	value := trimmed
	if strings.HasPrefix(strings.ToLower(value), "www.") || !strings.Contains(value, "://") {
		value = "https://" + value
	}
	parsed, err := url.Parse(value)
	if err != nil || parsed.Scheme == "" {
		return "text"
	}
	return "links"
}

func decode(raw json.RawMessage, target any) error {
	if len(raw) == 0 {
		raw = []byte("{}")
	}
	if err := json.Unmarshal(raw, target); err != nil {
		return errors.New("invalid request parameters")
	}
	return nil
}

func friendlyError(err error) string {
	switch {
	case errors.Is(err, server.ErrUnauthorized):
		return "Clipman Server rejected the token. Check the server connection details."
	case errors.Is(err, server.ErrConflict):
		return "The history changed on another device. Please try again."
	case errors.Is(err, context.DeadlineExceeded):
		return "Clipman Server did not respond before the request timed out."
	default:
		return err.Error()
	}
}

func write(value response) {
	data, _ := json.Marshal(value)
	fmt.Println(string(data))
}

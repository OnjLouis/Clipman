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
	"github.com/OnjLouis/Clipman/ClipmanLinuxBackend/internal/rules"
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
	// view is the last successful channel-aware read or mutation. It is nil
	// only before the first successful ReadView/MutateView call (e.g. right
	// after an offline bootstrap from the local disk cache). With sync rules
	// absent or disabled it still holds a single-channel (core-only) view, so
	// refresh's HEAD short-circuit and the "channels" response field work
	// uniformly whether or not rules are in use.
	view *syncengine.ViewState
}

var version = "0.1.0-preview"
var responseWriteMu sync.Mutex

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
		if req.Action == "fetch_website_title" {
			go respond(s, req)
			continue
		}
		respond(s, req)
		if req.Action == "shutdown" {
			return
		}
	}
}

func respond(s *session, req request) {
	result, err := s.handle(req.Action, req.Params)
	if err != nil {
		write(response{ID: req.ID, OK: false, Error: friendlyError(err)})
	} else {
		write(response{ID: req.ID, OK: true, Result: result})
	}
}

func (s *session) handle(action string, raw json.RawMessage) (any, error) {
	switch action {
	case "fetch_website_title":
		var p struct {
			URL string `json:"url"`
		}
		if err := decode(raw, &p); err != nil {
			return nil, err
		}
		title, err := fetchWebsiteTitle(p.URL)
		if err != nil {
			return nil, err
		}
		return map[string]string{"title": title}, nil
	case "prepare_image":
		var p struct {
			MIME       string `json:"mime"`
			Filename   string `json:"filename"`
			DataBase64 string `json:"data_base64"`
		}
		if err := decode(raw, &p); err != nil {
			return nil, err
		}
		return prepareEmbeddedImage(p.MIME, p.Filename, p.DataBase64)
	}
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
	case "merge_capture":
		return s.mergeCapture(raw)
	case "put_after":
		return s.putAfter(raw)
	case "update":
		return s.update(raw)
	case "set_name_if_blank":
		return s.setNameIfBlank(raw)
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
	case "file_merge_capture":
		return s.mergeFileCapture(raw)
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
	case "rules_get":
		return s.rulesGet()
	case "rules_set":
		return s.rulesSet(raw)
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
	client.MaxBlobBytes = limits.MaxBlobBytes
	engine := &syncengine.Engine{Client: client, Password: password, Limits: limits, Retries: 3, Token: token}
	engine.CachedRules = s.initialCachedRules(password)
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	if _, err = client.Health(ctx); err != nil {
		return fmt.Errorf("server connection failed: %w", err)
	}
	view, err := engine.ReadView(ctx, cfg.Machine)
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
	s.setViewState(view)
	s.cacheRulesDocument(view.Rules)
	s.selfRegisterDevice(ctx, view)
	return nil
}

func (s *session) refresh(force bool) (any, error) {
	if s.engine == nil {
		return nil, errors.New("Clipman is not configured or the history password has not been entered")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	if !force && s.loaded && s.view != nil && s.viewUnchanged(ctx) {
		s.offline = false
		changed := s.retryPendingWrites(ctx)
		return s.historyResult(changed), nil
	}
	view, err := s.engine.ReadView(ctx, s.cfg.Machine)
	if err != nil {
		if s.loaded {
			s.offline = true
			return s.historyResult(false), nil
		}
		if cache, cacheErr := platform.ReadPrivateBounded(s.cachePath, s.engine.Limits.MaxBlobBytes); cacheErr == nil {
			db, decodeErr := clipdb.Decode(cache, s.password, s.engine.Limits)
			if decodeErr == nil {
				s.database, s.loaded, s.offline = db, true, true
				return s.historyResult(true), nil
			}
		}
		return nil, fmt.Errorf("server history is unavailable: %w", err)
	}
	s.setViewState(view)
	s.cacheRulesDocument(view.Rules)
	s.retryPendingWrites(ctx)
	return s.historyResult(true), nil
}

// viewUnchanged implements the session-layer half of the spec section 5
// download short-circuit: HEAD the rules bucket (if addressable) and every
// channel in the last-known view, and report true only when every revision
// still matches. A rules HEAD that 404s is "unchanged" exactly when the last
// view also saw no rules revision (rules absent, or a local cache in effect);
// any ambiguity or transport error is treated as "changed" so the caller
// always falls back to a full, correct ReadView.
func (s *session) viewUnchanged(ctx context.Context) bool {
	if s.view == nil {
		return false
	}
	token := s.engine.Token
	if rulesID := identity.SyncRulesDatabaseID(token, s.password); rulesID != "" {
		metadata, err := s.bucketClient(rulesID).Head(ctx)
		switch {
		case errors.Is(err, server.ErrNotFound):
			if s.view.RulesRevision != "" {
				return false
			}
		case err != nil:
			return false
		default:
			if s.view.RulesRevision == "" || metadata.Revision != s.view.RulesRevision {
				return false
			}
		}
	}
	for _, channel := range s.view.Channels {
		databaseID := s.client.DatabaseID
		if channel.Key != "" {
			databaseID = identity.ChannelDatabaseID(token, s.password, channel.Key)
			if databaseID == "" {
				return false
			}
		}
		metadata, err := s.bucketClient(databaseID).Head(ctx)
		switch {
		case errors.Is(err, server.ErrNotFound):
			// A channel bucket is not created until its first mutation
			// (readChannel leaves Revision blank for one that does not exist
			// yet), so a 404 here matches the last view exactly when it also
			// saw no revision.
			if channel.Revision != "" {
				return false
			}
		case err != nil:
			return false
		default:
			if channel.Revision == "" || metadata.Revision != channel.Revision {
				return false
			}
		}
	}
	return true
}

// setViewState records a channel-aware read or mutation as the session's
// current state. The local offline-fallback cache is re-encoded from the
// merged view rather than reusing a channel's raw blob (ChannelState keeps
// that unexported), reusing the previous cache file's container so this does
// not force a fresh PBKDF2 derivation on every call.
func (s *session) setViewState(view *syncengine.ViewState) {
	s.view = view
	s.database = *view.View
	s.revision = view.Channels[0].Revision
	s.loaded, s.offline = true, false
	existing, _ := platform.ReadPrivate(s.cachePath)
	if blob, err := clipdb.Encode(s.database, s.password, existing); err == nil {
		_ = platform.SavePrivate(s.cachePath, blob)
	}
}

// bucketClient addresses another bucket on the same server with the same
// credentials and transport as the session's configured client.
func (s *session) bucketClient(databaseID string) *server.Client {
	clone := *s.client
	clone.DatabaseID = databaseID
	return &clone
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
	result := map[string]any{"entries": entries, "file_events": s.exportFileEvents(), "groups": groupNames, "revision": s.revision, "changed": changed, "offline": s.offline, "server": s.client.BaseURL, "machine": s.cfg.Machine}
	if s.view != nil {
		channels := make([]map[string]string, 0, len(s.view.Channels))
		for _, channel := range s.view.Channels {
			key := channel.Key
			if key == "" {
				key = "core"
			}
			channels = append(channels, map[string]string{"key": key, "revision": channel.Revision})
		}
		result["channels"] = channels
	}
	return result
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

// mutate adapts the existing per-operation Mutation closures (which report a
// changed flag, an operation-specific result, and an error) onto
// Engine.MutateView. WriteThroughError needs particular care here (see its
// doc comment in internal/syncengine/channels.go): the undelivered entries
// are always parked to pending-writes.json regardless of outcome, but the
// save is reported as successful, with the added "pendingChannels" field,
// only when Committed is true. When Committed is false a subscribed-channel
// upload also failed, so this must surface as a failed save even though some
// entries were parked - reporting success here would silently drop the rest
// of the user's change.
func (s *session) mutate(fn syncengine.Mutation) (any, error) {
	if s.engine == nil {
		return nil, errors.New("history is locked")
	}
	if s.offline {
		return nil, errors.New("history is read-only while Clipman Server is unavailable")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	var result any
	view, err := s.engine.MutateView(ctx, s.cfg.Machine, func(db *model.Database) error {
		_, r, mutErr := fn(db, time.Now().UnixMilli())
		result = r
		return mutErr
	})
	if err != nil {
		var pending *syncengine.WriteThroughError
		if errors.As(err, &pending) {
			s.recordPendingWrites(pending.Pending)
			if pending.Committed && view != nil {
				s.setViewState(view)
				return map[string]any{
					"operation":       result,
					"history":         s.historyResult(true),
					"pendingChannels": pendingChannelKeys(pending.Pending),
				}, nil
			}
		}
		return nil, err
	}
	s.setViewState(view)
	return map[string]any{"operation": result, "history": s.historyResult(true)}, nil
}

func pendingChannelKeys(pending map[string][]model.Entry) []string {
	keys := make([]string, 0, len(pending))
	for key := range pending {
		keys = append(keys, key)
	}
	sort.Strings(keys)
	return keys
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
		if err := validateEmbeddedImageBudget(db, p.Text, p.IsTemplate, p.Duplicate, richText); err != nil {
			return false, nil, err
		}
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

func (s *session) mergeCapture(raw json.RawMessage) (any, error) {
	var p struct {
		BaseID    string `json:"base_id"`
		BaseText  string `json:"base_text"`
		FirstID   string `json:"first_id"`
		FirstText string `json:"first_text"`
		Text      string `json:"text"`
		Group     string `json:"group"`
	}
	if err := decode(raw, &p); err != nil {
		return nil, err
	}
	if strings.TrimSpace(p.Text) == "" || !utf8.ValidString(p.Text) {
		return nil, errors.New("merged clipboard text cannot be empty or invalid UTF-8")
	}
	return s.mutate(func(db *model.Database, now int64) (bool, any, error) {
		baseIndex, firstIndex := -1, -1
		for index := range db.Entries {
			if strings.EqualFold(db.Entries[index].ID, p.BaseID) {
				baseIndex = index
			}
			if strings.EqualFold(db.Entries[index].ID, p.FirstID) {
				firstIndex = index
			}
		}
		newestMatchingText := func(text string) int {
			found := -1
			for index := range db.Entries {
				entry := db.Entries[index]
				if entry.Pinned || entry.Text != text {
					continue
				}
				if found < 0 || entry.LastUsedUnixMs > db.Entries[found].LastUsedUnixMs {
					found = index
				}
			}
			return found
		}
		if strings.TrimSpace(p.BaseID) == "" {
			baseIndex = newestMatchingText(p.BaseText)
		}
		if strings.TrimSpace(p.FirstID) == "" {
			firstIndex = newestMatchingText(p.FirstText)
		}
		targetIndex := -1
		if baseIndex >= 0 && !db.Entries[baseIndex].Pinned {
			targetIndex = baseIndex
		} else if firstIndex >= 0 && !db.Entries[firstIndex].Pinned {
			targetIndex = firstIndex
		}
		var saved model.Entry
		if targetIndex >= 0 {
			target := &db.Entries[targetIndex]
			target.Text, target.SourceMachine = p.Text, s.cfg.Machine
			target.LastUsedUnixMs, target.ModifiedUnixMs, target.IsTemplate = now, now, false
			if strings.TrimSpace(target.Group) == "" && strings.TrimSpace(p.Group) != "" {
				target.Group = canonicalLabelFor(db.Entries, func(entry model.Entry) string { return entry.Group }, p.Group)
			}
			clearRichText(target, now)
			saved = *target
		} else {
			entry, _ := operation.Put(db, p.Text, "", p.Group, s.cfg.Machine, "keep", merge.NewID(), false, false, now)
			saved = entry
		}
		for index := range db.Entries {
			entry := db.Entries[index]
			matchesFirst := strings.TrimSpace(p.FirstID) != "" && strings.EqualFold(entry.ID, p.FirstID)
			if strings.TrimSpace(p.FirstID) == "" {
				matchesFirst = index == firstIndex
			}
			if matchesFirst && !strings.EqualFold(entry.ID, saved.ID) && !entry.Pinned {
				merge.AddDeleted(db, entry, s.cfg.Machine, now)
				break
			}
		}
		db.UpdatedUnixMs = now
		return true, map[string]any{"entry": exportEntry(saved), "outcome": "merged"}, nil
	})
}

func (s *session) setNameIfBlank(raw json.RawMessage) (any, error) {
	var p struct {
		ID           string `json:"id"`
		ExpectedText string `json:"expected_text"`
		Name         string `json:"name"`
	}
	if err := decode(raw, &p); err != nil {
		return nil, err
	}
	name := sanitizeWebsiteTitle(p.Name)
	if name == "" {
		return nil, errors.New("the website did not provide a usable title")
	}
	return s.mutate(func(db *model.Database, now int64) (bool, any, error) {
		for index := range db.Entries {
			entry := &db.Entries[index]
			if !strings.EqualFold(entry.ID, p.ID) {
				continue
			}
			if entry.Text != p.ExpectedText {
				return false, nil, errors.New("the link changed while its website title was being requested")
			}
			if strings.TrimSpace(entry.Name) != "" {
				return false, nil, errors.New("the link was named by another client while its website title was being requested")
			}
			entry.Name, entry.LastUsedUnixMs, entry.ModifiedUnixMs, entry.SourceMachine = name, now, now, s.cfg.Machine
			db.UpdatedUnixMs = now
			return true, exportEntry(*entry), nil
		}
		return false, nil, errors.New("the link was changed or deleted while its website title was being requested")
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
	if strings.Contains(html, `data-clipman-image=`) {
		if _, err := parseEmbeddedImageWrapper(html); err != nil {
			html = ""
		}
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
	if !websiteTitleURLWithinLimit(trimmed) || strings.ContainsAny(trimmed, " \t\r\n") || !standaloneURL.MatchString(trimmed) {
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

// --- sync rules: cache, pending write-through store, session handlers ------

// pendingWritesFile and rulesCacheFile live beside the offline history cache
// (gui-cache.clipdb), in the same private per-user data directory.
func (s *session) pendingWritesFile() string {
	return filepath.Join(filepath.Dir(s.cachePath), "pending-writes.json")
}
func (s *session) rulesCacheFile() string {
	return filepath.Join(filepath.Dir(s.cachePath), "rules-cache.json")
}

// initialCachedRules loads the on-disk rules cache for seeding a fresh
// Engine.CachedRules at activation. The gui-cache.clipdb beside it holds an
// encrypted container, so the rules cache is stored the same way (via
// clipdb.EncodeRaw/DecodeRaw with the session password) rather than as
// plaintext JSON. A read-only (future-version) document is withheld, per
// rules.ReadOnly's contract: it must never arm the engine's 404 re-upload
// fallback, which would rewrite a document this client only partly
// understands.
func (s *session) initialCachedRules(password string) *rules.Document {
	blob, err := platform.ReadPrivate(s.rulesCacheFile())
	if err != nil {
		return nil
	}
	payload, _, err := clipdb.DecodeRaw(blob, password)
	if err != nil {
		return nil
	}
	doc, err := rules.Parse(payload)
	if err != nil || rules.ReadOnly(doc) {
		return nil
	}
	return doc
}

// cacheRulesDocument persists the last-seen rules document to disk and arms
// Engine.CachedRules with it, withholding a read-only document from the
// cache guard for the same reason initialCachedRules does.
func (s *session) cacheRulesDocument(doc *rules.Document) {
	if doc == nil {
		return
	}
	if rules.ReadOnly(doc) {
		s.engine.CachedRules = nil
	} else {
		s.engine.CachedRules = doc
	}
	payload, err := rules.Serialize(doc)
	if err != nil {
		return
	}
	existing, _ := platform.ReadPrivate(s.rulesCacheFile())
	var salt []byte
	if len(existing) > 0 {
		if _, existingSalt, decodeErr := clipdb.DecodeRaw(existing, s.password); decodeErr == nil {
			salt = existingSalt
		}
	}
	blob, err := clipdb.EncodeRaw(payload, s.password, salt)
	if err != nil {
		return
	}
	_ = platform.SavePrivate(s.rulesCacheFile(), blob)
}

// rulesSalt returns the PBKDF2 salt a rules-bucket write should reuse: from
// existingBlob when supplied, otherwise from the core database, so channel
// and rules blobs share one derivation (spec section 5, "Salt sharing").
func (s *session) rulesSalt(ctx context.Context, existingBlob []byte) []byte {
	if len(existingBlob) > 0 {
		if _, salt, err := clipdb.DecodeRaw(existingBlob, s.password); err == nil {
			return salt
		}
	}
	if download, err := s.client.Get(ctx); err == nil {
		if _, salt, err := clipdb.DecodeRaw(download.Data, s.password); err == nil {
			return salt
		}
	}
	return nil
}

// fetchRulesDocument downloads and decodes the rules document directly,
// without touching history, for rules-get/rules-set and self-registration.
// It intentionally returns the server's document as-is, not run through
// Engine.CachedRules/MergeDocuments (readRules's edit-vs-display split, also
// used by the CLI): rules-set's own conflict handling merges against exactly
// what the server holds, and self-registration's CAS must be based on the
// same. Do not "fix" this to fold in the local cache.
func (s *session) fetchRulesDocument(ctx context.Context) (doc *rules.Document, revision string, blob []byte, exists bool, err error) {
	rulesID := identity.SyncRulesDatabaseID(s.engine.Token, s.password)
	if rulesID == "" {
		return nil, "", nil, false, errors.New("cannot address the sync rules bucket without a server token and history password")
	}
	download, err := s.bucketClient(rulesID).Get(ctx)
	if errors.Is(err, server.ErrNotFound) {
		return nil, "", nil, false, nil
	}
	if err != nil {
		return nil, "", nil, false, err
	}
	payload, _, err := clipdb.DecodeRaw(download.Data, s.password)
	if err != nil {
		return nil, "", nil, false, err
	}
	parsed, err := rules.Parse(payload)
	if err != nil {
		return nil, "", nil, false, err
	}
	return parsed, download.Revision, download.Data, true, nil
}

func cloneRulesDocument(doc *rules.Document) *rules.Document {
	clone := *doc
	clone.Channels = append([]rules.Channel{}, doc.Channels...)
	for i := range clone.Channels {
		clone.Channels[i].Route.Groups = append([]string{}, doc.Channels[i].Route.Groups...)
		clone.Channels[i].Route.SourceDevices = append([]string{}, doc.Channels[i].Route.SourceDevices...)
	}
	clone.Devices = append([]rules.Device{}, doc.Devices...)
	for i := range clone.Devices {
		clone.Devices[i].Channels = append([]string{}, doc.Devices[i].Channels...)
	}
	return &clone
}

// nextRulesTimestamp returns a millisecond timestamp guaranteed to be greater
// than prev, so an edit's UpdatedUnixMs strictly advances even when the wall
// clock has not visibly moved since the document was last written.
func nextRulesTimestamp(prev int64) int64 {
	now := time.Now().UnixMilli()
	if now <= prev {
		return prev + 1
	}
	return now
}

// selfRegisterDevice implements spec section 4's registry behavior: after a
// successful activation with rules enabled, a device missing from Devices
// adds itself with Channels ["*"] via one best-effort compare-and-swap.
// Failure here must never fail activation. It re-fetches the rules document
// directly rather than reusing view.Rules, because view.RulesRevision can be
// blank (the local cache won the last-writer-wins merge, so it is not what
// the server holds and an If-Match against it would be meaningless).
func (s *session) selfRegisterDevice(ctx context.Context, view *syncengine.ViewState) {
	if view == nil || view.Rules == nil || !view.Rules.Enabled || rules.ReadOnly(view.Rules) {
		return
	}
	machine := strings.TrimSpace(s.cfg.Machine)
	for _, device := range view.Rules.Devices {
		if strings.EqualFold(strings.TrimSpace(device.Name), machine) {
			return
		}
	}
	doc, revision, blob, exists, err := s.fetchRulesDocument(ctx)
	if err != nil || !exists || doc == nil || !doc.Enabled || rules.ReadOnly(doc) {
		return
	}
	for _, device := range doc.Devices {
		if strings.EqualFold(strings.TrimSpace(device.Name), machine) {
			return // already registered by a racing writer
		}
	}
	candidate := cloneRulesDocument(doc)
	candidate.Devices = append(candidate.Devices, rules.Device{Name: s.cfg.Machine, Channels: []string{"*"}})
	candidate.UpdatedUnixMs = nextRulesTimestamp(doc.UpdatedUnixMs)
	candidate.UpdatedBy = s.cfg.Machine
	payload, err := rules.Serialize(candidate)
	if err != nil {
		return
	}
	encoded, err := clipdb.EncodeRaw(payload, s.password, s.rulesSalt(ctx, blob))
	if err != nil {
		return
	}
	rulesID := identity.SyncRulesDatabaseID(s.engine.Token, s.password)
	if _, err := s.bucketClient(rulesID).Put(ctx, encoded, revision, false); err != nil {
		return
	}
	s.cacheRulesDocument(candidate)
}

// rulesGet implements the "rules_get" backend request:
// {"rules": <document or null>, "readOnly": bool, "revision": "..."}.
func (s *session) rulesGet() (any, error) {
	if s.engine == nil {
		return nil, errors.New("history is locked")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	doc, revision, _, exists, err := s.fetchRulesDocument(ctx)
	if err != nil {
		return nil, err
	}
	if !exists {
		doc, revision = s.engine.CachedRules, ""
	} else {
		s.cacheRulesDocument(doc)
	}
	return map[string]any{"rules": doc, "readOnly": rules.ReadOnly(doc), "revision": revision}, nil
}

// rulesSet implements the "rules_set" backend request: validate, refuse a
// read-only document, upload with If-Match against the caller-supplied
// revision (from the last rules-get), and LWW-merge and retry on a 409 (spec
// section 4, Concurrency). It responds with the document actually stored.
func (s *session) rulesSet(raw json.RawMessage) (any, error) {
	if s.engine == nil {
		return nil, errors.New("history is locked")
	}
	var p struct {
		Rules    rules.Document `json:"rules"`
		Revision string         `json:"revision"`
	}
	if err := decode(raw, &p); err != nil {
		return nil, err
	}
	doc := p.Rules
	if err := rules.Validate(&doc); err != nil {
		return nil, err
	}
	if rules.ReadOnly(&doc) {
		return nil, errors.New("this sync rules document uses a newer format and cannot be edited here")
	}
	rulesID := identity.SyncRulesDatabaseID(s.engine.Token, s.password)
	if rulesID == "" {
		return nil, errors.New("cannot address the sync rules bucket without a server token and history password")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	client := s.bucketClient(rulesID)
	// Always advance past the caller-supplied timestamp (the revision this
	// edit was based on), never merely fill a blank one: doc.UpdatedUnixMs
	// otherwise stays pinned to the stale value the client fetched, so a 409
	// below would compare that stale stamp against whatever the server
	// already holds (which is, by definition, newer than what this client
	// last saw) and MergeDocuments would silently prefer the remote copy,
	// discarding this edit while still reporting success.
	doc.UpdatedUnixMs = nextRulesTimestamp(doc.UpdatedUnixMs)
	doc.UpdatedBy = s.cfg.Machine
	revision := p.Revision
	createOnly := revision == ""
	var existingBlob []byte
	for attempt := 0; attempt < 3; attempt++ {
		payload, err := rules.Serialize(&doc)
		if err != nil {
			return nil, err
		}
		blob, err := clipdb.EncodeRaw(payload, s.password, s.rulesSalt(ctx, existingBlob))
		if err != nil {
			return nil, err
		}
		metadata, putErr := client.Put(ctx, blob, revision, createOnly)
		if putErr == nil {
			s.cacheRulesDocument(&doc)
			return map[string]any{"rules": doc, "readOnly": false, "revision": metadata.Revision}, nil
		}
		if !errors.Is(putErr, server.ErrConflict) {
			return nil, putErr
		}
		remote, remoteRevision, remoteBlob, exists, fetchErr := s.fetchRulesDocument(ctx)
		if fetchErr != nil {
			return nil, fetchErr
		}
		if !exists {
			revision, createOnly, existingBlob = "", true, nil
			continue
		}
		merged := rules.MergeDocuments(&doc, remote)
		doc = *merged
		revision, createOnly, existingBlob = remoteRevision, false, remoteBlob
	}
	return nil, errors.New("sync rules changed on the server repeatedly; try again")
}

// --- write-through pending store (spec section 6) ---------------------------

func (s *session) loadPendingWrites() map[string][]model.Entry {
	data, err := platform.ReadPrivate(s.pendingWritesFile())
	if err != nil {
		return nil
	}
	var pending map[string][]model.Entry
	if json.Unmarshal(data, &pending) != nil {
		return nil
	}
	return pending
}

func (s *session) savePendingWrites(pending map[string][]model.Entry) {
	nonEmpty := false
	for _, entries := range pending {
		if len(entries) > 0 {
			nonEmpty = true
			break
		}
	}
	if !nonEmpty {
		_ = os.Remove(s.pendingWritesFile())
		return
	}
	data, err := json.Marshal(pending)
	if err != nil {
		return
	}
	_ = platform.SavePrivate(s.pendingWritesFile(), data)
}

// recordPendingWrites merges newly failed write-through entries into whatever
// is already parked on disk, keyed by entry id so a repeated failure does not
// duplicate an entry already waiting for the same channel.
func (s *session) recordPendingWrites(newPending map[string][]model.Entry) {
	if len(newPending) == 0 {
		return
	}
	existing := s.loadPendingWrites()
	if existing == nil {
		existing = map[string][]model.Entry{}
	}
	for key, entries := range newPending {
		existing[key] = mergeEntriesByID(existing[key], entries)
	}
	s.savePendingWrites(existing)
}

func mergeEntriesByID(existing, incoming []model.Entry) []model.Entry {
	byID := make(map[string]model.Entry, len(existing)+len(incoming))
	order := make([]string, 0, len(existing)+len(incoming))
	add := func(e model.Entry) {
		if _, ok := byID[e.ID]; !ok {
			order = append(order, e.ID)
		}
		byID[e.ID] = e
	}
	for _, e := range existing {
		add(e)
	}
	for _, e := range incoming {
		add(e)
	}
	result := make([]model.Entry, 0, len(order))
	for _, id := range order {
		result = append(result, byID[id])
	}
	return result
}

// retryPendingWrites is called at the start of every successful refresh: any
// entry left over from a failed write-through is retried, and cleared from
// the pending store on success. It is entirely best effort; a channel that
// still cannot be reached simply stays pending for the next attempt.
//
// Every parked entry is re-routed against the CURRENT rules document before
// retrying, rather than resent to the channel key it was originally parked
// under: that channel may since have been removed, and delivering it there
// regardless would resurrect a bucket that no longer belongs in the document.
// An entry that no longer routes anywhere (core) is delivered through a
// normal mutation instead of a channel write-through, so it lands in the
// local view like any other capture. It returns whether anything was
// delivered, so callers can report the refresh as having changed state.
func (s *session) retryPendingWrites(ctx context.Context) bool {
	pending := s.loadPendingWrites()
	if len(pending) == 0 {
		return false
	}
	var currentDoc *rules.Document
	if s.view != nil {
		currentDoc = s.view.Rules
	}
	regrouped := map[string][]model.Entry{}
	for _, entries := range pending {
		for _, entry := range entries {
			target := rules.RouteEntry(currentDoc, &entry)
			regrouped[target] = append(regrouped[target], entry)
		}
	}
	remaining := map[string][]model.Entry{}
	changed := false
	for target, entries := range regrouped {
		if len(entries) == 0 {
			continue
		}
		if target == "" {
			if failed := s.retryToCore(ctx, entries); len(failed) > 0 {
				remaining[""] = append(remaining[""], failed...)
			} else {
				changed = true
			}
			continue
		}
		if err := s.writeThroughToChannel(ctx, target, entries); err != nil {
			remaining[target] = append(remaining[target], entries...)
			continue
		}
		changed = true
	}
	s.savePendingWrites(remaining)
	return changed
}

// retryToCore delivers pending entries that now route to core (their channel
// was removed, or never routed anywhere in the first place) through a normal
// mutation, so they land in the local view instead of a channel bucket. It
// returns the entries that still could not be delivered.
func (s *session) retryToCore(ctx context.Context, entries []model.Entry) []model.Entry {
	view, err := s.engine.MutateView(ctx, s.cfg.Machine, func(database *model.Database) error {
		existing := make(map[string]bool, len(database.Entries))
		for _, e := range database.Entries {
			existing[strings.ToLower(strings.TrimSpace(e.ID))] = true
		}
		for _, entry := range entries {
			if existing[strings.ToLower(strings.TrimSpace(entry.ID))] {
				continue
			}
			database.Entries = append(database.Entries, entry)
		}
		return nil
	})
	if err != nil {
		var pending *syncengine.WriteThroughError
		if errors.As(err, &pending) {
			s.recordPendingWrites(pending.Pending)
			if pending.Committed && view != nil {
				s.setViewState(view)
				return nil
			}
		}
		return entries
	}
	s.setViewState(view)
	return nil
}

// writeThroughToChannel performs the one-shot fetch-merge-put of spec section
// 6 against a channel bucket directly, mirroring the engine's unexported
// writeThrough using only the session's public surface (Client, Password,
// Limits) since that method is not exported for reuse here.
func (s *session) writeThroughToChannel(ctx context.Context, key string, entries []model.Entry) error {
	databaseID := identity.ChannelDatabaseID(s.engine.Token, s.password, key)
	if databaseID == "" {
		return fmt.Errorf("cannot address the %q channel without a server token and history password", key)
	}
	client := s.bucketClient(databaseID)
	download, err := client.Get(ctx)
	now := time.Now().UnixMilli()
	var database model.Database
	var revision string
	var existingBlob []byte
	createOnly := false
	switch {
	case errors.Is(err, server.ErrNotFound):
		database = model.NewDatabase(now)
		createOnly = true
	case err != nil:
		return err
	default:
		decoded, decodeErr := clipdb.Decode(download.Data, s.password, s.engine.Limits)
		if decodeErr != nil {
			return decodeErr
		}
		database = decoded
		revision = download.Revision
		existingBlob = download.Data
	}
	merge.Normalize(&database, now)
	database.Deleted = dropMarkersForResident(database.Deleted, entries)
	source := model.NewDatabase(now)
	source.Entries = append(source.Entries, entries...)
	merge.Merge(&database, source, now)
	if len(existingBlob) == 0 {
		existingBlob = s.fetchCoreBlobBestEffort(ctx)
	}
	encoded, err := clipdb.Encode(database, s.password, existingBlob)
	if err != nil {
		return err
	}
	_, err = client.Put(ctx, encoded, revision, createOnly)
	return err
}

// fetchCoreBlobBestEffort best-effort downloads the raw core blob, purely
// so a newly-created channel bucket can share its PBKDF2 salt. A failure here
// is not fatal: the caller falls back to a fresh salt.
func (s *session) fetchCoreBlobBestEffort(ctx context.Context) []byte {
	download, err := s.client.Get(ctx)
	if err != nil {
		return nil
	}
	return download.Data
}

// dropMarkersForResident removes a tombstone naming an entry that is about to
// be written back into the same channel, mirroring the engine's own
// dropMarkersForEntries so a stale relocation marker cannot immediately
// delete the entry it names again.
func dropMarkersForResident(markers []model.DeletedEntry, entries []model.Entry) []model.DeletedEntry {
	if len(markers) == 0 || len(entries) == 0 {
		return markers
	}
	resident := make(map[string]bool, len(entries))
	for _, e := range entries {
		resident[strings.ToLower(strings.TrimSpace(e.ID))] = true
	}
	kept := make([]model.DeletedEntry, 0, len(markers))
	for _, m := range markers {
		if resident[strings.ToLower(strings.TrimSpace(m.ID))] {
			continue
		}
		kept = append(kept, m)
	}
	return kept
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
	responseWriteMu.Lock()
	defer responseWriteMu.Unlock()
	data, _ := json.Marshal(value)
	fmt.Println(string(data))
}

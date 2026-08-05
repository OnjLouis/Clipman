package main

import (
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"
	"unicode"
	"unicode/utf8"

	"github.com/OnjLouis/Clipman/ClipmanLinuxBackend/internal/clipdb"
	"github.com/OnjLouis/Clipman/ClipmanLinuxBackend/internal/merge"
	"github.com/OnjLouis/Clipman/ClipmanLinuxBackend/internal/model"
	"github.com/OnjLouis/Clipman/ClipmanLinuxBackend/internal/platform"
)

const maxFileEvents = 200

type fileEventJSON struct {
	ID             string   `json:"id"`
	CapturedUnixMs int64    `json:"captured_unix_ms"`
	Source         string   `json:"source"`
	Operation      string   `json:"operation"`
	Device         string   `json:"device"`
	ContainsText   bool     `json:"contains_text"`
	FileCount      int      `json:"file_count"`
	Files          []string `json:"files"`
	Formats        []string `json:"formats"`
	Pinned         bool     `json:"pinned"`
	ManualOrder    int64    `json:"manual_order"`
	Display        string   `json:"display"`
}

func (s *session) loadFileHistory(previousPassword ...string) error {
	s.filePath = filepath.Join(filepath.Dir(s.configPath), safeDeviceName(s.cfg.Machine)+"-file-history.clipdb")
	blob, err := platform.ReadPrivateBounded(s.filePath, s.codecLimits().MaxBlobBytes)
	if os.IsNotExist(err) {
		s.fileDB = model.NewFileDatabase(time.Now().UnixMilli())
		s.fileLoaded = true
		return nil
	}
	if err != nil {
		return err
	}
	database, err := clipdb.DecodeFileHistory(blob, s.password, s.codecLimits())
	if err != nil && len(previousPassword) > 0 && previousPassword[0] != "" && previousPassword[0] != s.password {
		database, err = clipdb.DecodeFileHistory(blob, previousPassword[0], s.codecLimits())
		if err == nil {
			rekeyed, encodeErr := clipdb.EncodeFileHistoryWithLimits(database, s.password, blob, s.codecLimits())
			if encodeErr != nil {
				return encodeErr
			}
			if saveErr := platform.SavePrivate(s.filePath, rekeyed); saveErr != nil {
				return saveErr
			}
		}
	}
	if err != nil {
		return err
	}
	s.fileDB = database
	s.normalizeFileHistory()
	s.fileLoaded = true
	return nil
}

func (s *session) saveFileHistory() error {
	if !s.fileLoaded {
		return errors.New("file history is not available")
	}
	s.fileDB.UpdatedUnixMs = time.Now().UnixMilli()
	existing, err := platform.ReadPrivateBounded(s.filePath, s.codecLimits().MaxBlobBytes)
	if err != nil && !os.IsNotExist(err) {
		return err
	}
	blob, err := clipdb.EncodeFileHistoryWithLimits(s.fileDB, s.password, existing, s.codecLimits())
	if err != nil {
		return err
	}
	return platform.SavePrivate(s.filePath, blob)
}

func (s *session) codecLimits() clipdb.Limits {
	if s.engine == nil {
		return clipdb.DefaultLimits()
	}
	return s.engine.Limits
}

func (s *session) addFileEvent(raw json.RawMessage) (any, error) {
	var p struct {
		Files        []string `json:"files"`
		Formats      []string `json:"formats"`
		Source       string   `json:"source"`
		Operation    string   `json:"operation"`
		ContainsText bool     `json:"contains_text"`
	}
	if err := decode(raw, &p); err != nil {
		return nil, err
	}
	files := cleanFilePaths(p.Files)
	if len(files) == 0 {
		return nil, errors.New("file clipboard data does not contain a local file path")
	}
	now := time.Now().UnixMilli()
	event := model.FileEvent{
		ID: merge.NewID(), CapturedUnixMs: now, Source: strings.TrimSpace(p.Source),
		Operation: strings.TrimSpace(p.Operation), SourceMachine: s.cfg.Machine,
		ContainsText: p.ContainsText, FileCount: len(files), Files: files,
		Formats: cleanStrings(p.Formats), ManualOrder: 1,
	}
	if event.Source == "" {
		event.Source = "Files"
	}
	if event.Operation == "" {
		event.Operation = "Copy"
	}
	for index := range s.fileDB.Events {
		if sameFileSet(s.fileDB.Events[index].Files, event.Files) {
			event.Pinned = s.fileDB.Events[index].Pinned
			event.ManualOrder = s.fileDB.Events[index].ManualOrder
			s.fileDB.Events = append(s.fileDB.Events[:index], s.fileDB.Events[index+1:]...)
			break
		}
	}
	if !event.Pinned {
		for index := range s.fileDB.Events {
			if !s.fileDB.Events[index].Pinned && s.fileDB.Events[index].ManualOrder > 0 {
				s.fileDB.Events[index].ManualOrder++
			}
		}
		event.ManualOrder = 1
	}
	s.fileDB.Events = append([]model.FileEvent{event}, s.fileDB.Events...)
	s.normalizeFileHistory()
	s.trimFileHistory()
	if err := s.saveFileHistory(); err != nil {
		return nil, err
	}
	return s.fileHistoryResult(true), nil
}

func (s *session) mergeFileCapture(raw json.RawMessage) (any, error) {
	var p struct {
		BaseID       string   `json:"base_id"`
		BaseFiles    []string `json:"base_files"`
		FirstID      string   `json:"first_id"`
		FirstFiles   []string `json:"first_files"`
		Files        []string `json:"files"`
		Formats      []string `json:"formats"`
		Source       string   `json:"source"`
		Operation    string   `json:"operation"`
		ContainsText bool     `json:"contains_text"`
	}
	if err := decode(raw, &p); err != nil {
		return nil, err
	}
	files := cleanFilePaths(p.Files)
	if len(files) == 0 {
		return nil, errors.New("merged file clipboard data does not contain a local file path")
	}
	baseIndex, firstIndex := -1, -1
	for index := range s.fileDB.Events {
		if strings.EqualFold(s.fileDB.Events[index].ID, p.BaseID) {
			baseIndex = index
		}
		if strings.EqualFold(s.fileDB.Events[index].ID, p.FirstID) {
			firstIndex = index
		}
	}
	matchingFiles := func(paths []string) int {
		clean := cleanFilePaths(paths)
		found := -1
		for index := range s.fileDB.Events {
			event := s.fileDB.Events[index]
			if event.Pinned || !strings.EqualFold(event.Operation, p.Operation) || !sameFileSet(event.Files, clean) {
				continue
			}
			if found < 0 || event.CapturedUnixMs > s.fileDB.Events[found].CapturedUnixMs {
				found = index
			}
		}
		return found
	}
	if strings.TrimSpace(p.BaseID) == "" {
		baseIndex = matchingFiles(p.BaseFiles)
	}
	if strings.TrimSpace(p.FirstID) == "" {
		firstIndex = matchingFiles(p.FirstFiles)
	}
	targetIndex := -1
	if baseIndex >= 0 && !s.fileDB.Events[baseIndex].Pinned {
		targetIndex = baseIndex
	} else if firstIndex >= 0 && !s.fileDB.Events[firstIndex].Pinned {
		targetIndex = firstIndex
	}
	now := time.Now().UnixMilli()
	var saved model.FileEvent
	if targetIndex >= 0 {
		target := &s.fileDB.Events[targetIndex]
		target.CapturedUnixMs, target.Source, target.Operation = now, strings.TrimSpace(p.Source), strings.TrimSpace(p.Operation)
		target.SourceMachine, target.ContainsText = s.cfg.Machine, p.ContainsText
		target.Files, target.FileCount, target.Formats = files, len(files), cleanStrings(p.Formats)
		if target.Source == "" {
			target.Source = "Files"
		}
		if target.Operation == "" {
			target.Operation = "Copy"
		}
		saved = *target
	} else {
		saved = model.FileEvent{
			ID: merge.NewID(), CapturedUnixMs: now, Source: strings.TrimSpace(p.Source), Operation: strings.TrimSpace(p.Operation),
			SourceMachine: s.cfg.Machine, ContainsText: p.ContainsText, FileCount: len(files), Files: files,
			Formats: cleanStrings(p.Formats), ManualOrder: 1,
		}
		if saved.Source == "" {
			saved.Source = "Files"
		}
		if saved.Operation == "" {
			saved.Operation = "Copy"
		}
		s.fileDB.Events = append([]model.FileEvent{saved}, s.fileDB.Events...)
	}
	for index := range s.fileDB.Events {
		event := s.fileDB.Events[index]
		matchesFirst := strings.TrimSpace(p.FirstID) != "" && strings.EqualFold(event.ID, p.FirstID)
		if strings.TrimSpace(p.FirstID) == "" {
			matchesFirst = index == firstIndex
		}
		if matchesFirst && !strings.EqualFold(event.ID, saved.ID) && !event.Pinned {
			s.fileDB.Events = append(s.fileDB.Events[:index], s.fileDB.Events[index+1:]...)
			break
		}
	}
	s.normalizeFileHistory()
	s.trimFileHistory()
	if err := s.saveFileHistory(); err != nil {
		return nil, err
	}
	return s.fileHistoryResult(true), nil
}

func (s *session) deleteFileEvent(raw json.RawMessage) (any, error) {
	id, err := fileEventID(raw)
	if err != nil {
		return nil, err
	}
	for index, event := range s.fileDB.Events {
		if strings.EqualFold(event.ID, id) {
			if event.Pinned {
				return nil, errors.New("unpin this file event before deleting it")
			}
			s.fileDB.Events = append(s.fileDB.Events[:index], s.fileDB.Events[index+1:]...)
			if err := s.saveFileHistory(); err != nil {
				return nil, err
			}
			return s.fileHistoryResult(true), nil
		}
	}
	return nil, errors.New("file event was changed or deleted")
}

func (s *session) deleteFileEvents(raw json.RawMessage) (any, error) {
	var p struct {
		IDs []string `json:"ids"`
	}
	if err := decode(raw, &p); err != nil {
		return nil, err
	}
	ids := normalizedIDs(p.IDs)
	if len(ids) == 0 {
		return nil, errors.New("select at least one file-history event")
	}
	for _, event := range s.fileDB.Events {
		if ids[strings.ToLower(event.ID)] && event.Pinned {
			return nil, errors.New("unpin selected pinned file events before deleting them")
		}
	}
	kept := s.fileDB.Events[:0]
	removed := 0
	for _, event := range s.fileDB.Events {
		if ids[strings.ToLower(event.ID)] {
			removed++
			continue
		}
		kept = append(kept, event)
	}
	if removed != len(ids) {
		return nil, errors.New("one or more file events were changed or deleted")
	}
	s.fileDB.Events = kept
	if err := s.saveFileHistory(); err != nil {
		return nil, err
	}
	return s.fileHistoryResult(true), nil
}

func (s *session) pinFileEvent(raw json.RawMessage) (any, error) {
	id, err := fileEventID(raw)
	if err != nil {
		return nil, err
	}
	for index := range s.fileDB.Events {
		if strings.EqualFold(s.fileDB.Events[index].ID, id) {
			s.fileDB.Events[index].Pinned = !s.fileDB.Events[index].Pinned
			if s.fileDB.Events[index].ManualOrder <= 0 {
				s.fileDB.Events[index].ManualOrder = s.nextFileManualOrder()
			}
			if err := s.saveFileHistory(); err != nil {
				return nil, err
			}
			return s.fileHistoryResult(true), nil
		}
	}
	return nil, errors.New("file event was changed or deleted")
}

func (s *session) pinFileEvents(raw json.RawMessage) (any, error) {
	var p struct {
		IDs    []string `json:"ids"`
		Pinned bool     `json:"pinned"`
	}
	if err := decode(raw, &p); err != nil {
		return nil, err
	}
	ids := normalizedIDs(p.IDs)
	if len(ids) == 0 {
		return nil, errors.New("select at least one file-history event")
	}
	found, changed := 0, false
	for index := range s.fileDB.Events {
		if !ids[strings.ToLower(s.fileDB.Events[index].ID)] {
			continue
		}
		found++
		if s.fileDB.Events[index].Pinned != p.Pinned {
			s.fileDB.Events[index].Pinned = p.Pinned
			changed = true
		}
		if s.fileDB.Events[index].ManualOrder <= 0 {
			s.fileDB.Events[index].ManualOrder = s.nextFileManualOrder()
		}
	}
	if found != len(ids) {
		return nil, errors.New("one or more file events were changed or deleted")
	}
	if changed {
		if err := s.saveFileHistory(); err != nil {
			return nil, err
		}
	}
	return s.fileHistoryResult(changed), nil
}

func (s *session) swapFileEvents(raw json.RawMessage) (any, error) {
	var p struct {
		ID      string `json:"id"`
		OtherID string `json:"other_id"`
	}
	if err := decode(raw, &p); err != nil {
		return nil, err
	}
	first, second := -1, -1
	for index := range s.fileDB.Events {
		if strings.EqualFold(s.fileDB.Events[index].ID, p.ID) {
			first = index
		}
		if strings.EqualFold(s.fileDB.Events[index].ID, p.OtherID) {
			second = index
		}
	}
	if first < 0 || second < 0 {
		return nil, errors.New("file event was changed or deleted")
	}
	if s.fileDB.Events[first].Pinned != s.fileDB.Events[second].Pinned {
		return nil, errors.New("pinned and normal file events cannot cross their separator")
	}
	s.fileDB.Events[first].ManualOrder, s.fileDB.Events[second].ManualOrder = s.fileDB.Events[second].ManualOrder, s.fileDB.Events[first].ManualOrder
	if err := s.saveFileHistory(); err != nil {
		return nil, err
	}
	return s.fileHistoryResult(true), nil
}

func (s *session) clearFileEvents() (any, error) {
	kept := s.fileDB.Events[:0]
	removed := 0
	for _, event := range s.fileDB.Events {
		if event.Pinned {
			kept = append(kept, event)
		} else {
			removed++
		}
	}
	s.fileDB.Events = kept
	if removed > 0 {
		if err := s.saveFileHistory(); err != nil {
			return nil, err
		}
	}
	result := s.fileHistoryResult(removed > 0)
	result["removed"] = removed
	return result, nil
}

func (s *session) removeUnavailableFileEvents() (any, error) {
	kept := s.fileDB.Events[:0]
	removed := 0
	for _, event := range s.fileDB.Events {
		unavailable := len(event.Files) == 0
		if !unavailable {
			unavailable = true
			for _, path := range event.Files {
				if _, err := os.Stat(path); err == nil {
					unavailable = false
					break
				}
			}
		}
		if unavailable && !event.Pinned {
			removed++
		} else {
			kept = append(kept, event)
		}
	}
	s.fileDB.Events = kept
	if removed > 0 {
		if err := s.saveFileHistory(); err != nil {
			return nil, err
		}
	}
	result := s.fileHistoryResult(removed > 0)
	result["removed"] = removed
	return result, nil
}

func (s *session) exportFileEvents() []fileEventJSON {
	events := append([]model.FileEvent(nil), s.fileDB.Events...)
	sort.SliceStable(events, func(i, j int) bool {
		if events[i].Pinned != events[j].Pinned {
			return events[i].Pinned
		}
		if events[i].ManualOrder != events[j].ManualOrder {
			return events[i].ManualOrder < events[j].ManualOrder
		}
		return events[i].CapturedUnixMs > events[j].CapturedUnixMs
	})
	result := make([]fileEventJSON, 0, len(events))
	for _, event := range events {
		result = append(result, exportFileEvent(event))
	}
	return result
}

func (s *session) fileHistoryResult(changed bool) map[string]any {
	return map[string]any{"file_events": s.exportFileEvents(), "file_history_changed": changed, "file_history_path": s.filePath}
}

func (s *session) normalizeFileHistory() {
	if s.fileDB.Version < 1 {
		s.fileDB.Version = 1
	}
	var next int64 = 1
	for index := range s.fileDB.Events {
		event := &s.fileDB.Events[index]
		if event.ID == "" {
			event.ID = merge.NewID()
		}
		if event.CapturedUnixMs <= 0 {
			event.CapturedUnixMs = time.Now().UnixMilli()
		}
		if event.SourceMachine == "" {
			event.SourceMachine = s.cfg.Machine
		}
		event.Files = cleanFilePaths(event.Files)
		event.Formats = cleanStrings(event.Formats)
		event.FileCount = len(event.Files)
		if event.ManualOrder <= 0 {
			event.ManualOrder = next
		}
		if event.ManualOrder >= next {
			next = event.ManualOrder + 1
		}
	}
}

func (s *session) trimFileHistory() {
	if len(s.fileDB.Events) <= maxFileEvents {
		return
	}
	normal := make([]model.FileEvent, 0)
	for _, event := range s.fileDB.Events {
		if !event.Pinned {
			normal = append(normal, event)
		}
	}
	sort.SliceStable(normal, func(i, j int) bool { return normal[i].ManualOrder < normal[j].ManualOrder })
	remove := len(s.fileDB.Events) - maxFileEvents
	ids := map[string]bool{}
	for index := len(normal) - 1; index >= 0 && remove > 0; index-- {
		ids[normal[index].ID] = true
		remove--
	}
	kept := s.fileDB.Events[:0]
	for _, event := range s.fileDB.Events {
		if !ids[event.ID] {
			kept = append(kept, event)
		}
	}
	s.fileDB.Events = kept
}

func (s *session) nextFileManualOrder() int64 {
	var next int64 = 1
	for _, event := range s.fileDB.Events {
		if event.ManualOrder >= next {
			next = event.ManualOrder + 1
		}
	}
	return next
}

func fileEventID(raw json.RawMessage) (string, error) {
	var p struct {
		ID string `json:"id"`
	}
	if err := decode(raw, &p); err != nil {
		return "", err
	}
	if strings.TrimSpace(p.ID) == "" {
		return "", errors.New("file event ID is required")
	}
	return p.ID, nil
}

func exportFileEvent(event model.FileEvent) fileEventJSON {
	name := "File event"
	if len(event.Files) > 0 {
		name = filepath.Base(event.Files[0])
		if name == "." || name == string(filepath.Separator) || name == "" {
			name = event.Files[0]
		}
	}
	return fileEventJSON{ID: event.ID, CapturedUnixMs: event.CapturedUnixMs, Source: event.Source, Operation: event.Operation, Device: event.SourceMachine, ContainsText: event.ContainsText, FileCount: len(event.Files), Files: event.Files, Formats: event.Formats, Pinned: event.Pinned, ManualOrder: event.ManualOrder, Display: name}
}

func cleanFilePaths(values []string) []string {
	seen := map[string]bool{}
	result := make([]string, 0, len(values))
	for _, value := range values {
		value = strings.TrimSpace(value)
		if value == "" || !utf8.ValidString(value) || strings.IndexByte(value, 0) >= 0 {
			continue
		}
		value = filepath.Clean(value)
		if !filepath.IsAbs(value) || seen[value] {
			continue
		}
		seen[value] = true
		result = append(result, value)
	}
	return result
}

func cleanStrings(values []string) []string {
	seen := map[string]bool{}
	result := make([]string, 0, len(values))
	for _, value := range values {
		value = strings.TrimSpace(value)
		if value == "" || seen[value] {
			continue
		}
		seen[value] = true
		result = append(result, value)
	}
	return result
}

func sameFileSet(left, right []string) bool {
	if len(left) == 0 || len(left) != len(right) {
		return false
	}
	a, b := append([]string(nil), left...), append([]string(nil), right...)
	sort.Slice(a, func(i, j int) bool { return strings.ToLower(a[i]) < strings.ToLower(a[j]) })
	sort.Slice(b, func(i, j int) bool { return strings.ToLower(b[i]) < strings.ToLower(b[j]) })
	for index := range a {
		if !strings.EqualFold(a[index], b[index]) {
			return false
		}
	}
	return true
}

func safeDeviceName(value string) string {
	var out strings.Builder
	for _, character := range strings.TrimSpace(value) {
		if unicode.IsLetter(character) || unicode.IsDigit(character) || character == '-' || character == '_' {
			out.WriteRune(character)
		} else if out.Len() == 0 || !strings.HasSuffix(out.String(), "_") {
			out.WriteByte('_')
		}
	}
	name := strings.Trim(out.String(), "_.-")
	if name == "" {
		return "linux"
	}
	return name
}

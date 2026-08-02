package main

import (
	"crypto/subtle"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"

	"github.com/OnjLouis/Clipman/ClipmanLinuxBackend/internal/clipdb"
	"github.com/OnjLouis/Clipman/ClipmanLinuxBackend/internal/merge"
	"github.com/OnjLouis/Clipman/ClipmanLinuxBackend/internal/model"
	"github.com/OnjLouis/Clipman/ClipmanLinuxBackend/internal/operation"
	"github.com/OnjLouis/Clipman/ClipmanLinuxBackend/internal/platform"
)

func passwordMatches(first, second string) bool {
	return subtle.ConstantTimeCompare([]byte(first), []byte(second)) == 1
}

func (s *session) clearHistory(raw json.RawMessage) (any, error) {
	var p struct {
		Password string `json:"password"`
	}
	if err := decode(raw, &p); err != nil {
		return nil, err
	}
	if !passwordMatches(p.Password, s.password) {
		return nil, errors.New("the history password did not match; clipboard history was not cleared")
	}
	return s.mutate(func(db *model.Database, now int64) (bool, any, error) {
		removed := len(db.Entries)
		for _, entry := range append([]model.Entry(nil), db.Entries...) {
			merge.AddDeleted(db, entry, s.cfg.Machine, now)
		}
		db.Entries = []model.Entry{}
		db.UpdatedUnixMs = now
		return removed > 0, map[string]int{"removed": removed}, nil
	})
}

func (s *session) pushEntries(raw json.RawMessage) (any, error) {
	var p struct {
		IDs []string `json:"ids"`
	}
	if err := decode(raw, &p); err != nil {
		return nil, err
	}
	ids := make(map[string]bool, len(p.IDs))
	for _, id := range p.IDs {
		if id = strings.TrimSpace(id); id != "" {
			ids[strings.ToLower(id)] = true
		}
	}
	if len(ids) == 0 {
		return nil, errors.New("select at least one clipboard entry to push")
	}
	return s.mutate(func(db *model.Database, now int64) (bool, any, error) {
		pushed := 0
		for i := range db.Entries {
			if !ids[strings.ToLower(db.Entries[i].ID)] {
				continue
			}
			stamp := now + int64(pushed)
			db.Entries[i].SourceMachine = s.cfg.Machine
			db.Entries[i].CreatedUnixMs = stamp
			db.Entries[i].LastUsedUnixMs = stamp
			pushed++
		}
		if pushed == 0 {
			return false, nil, errors.New("the selected clipboard entry was changed or deleted by another client")
		}
		db.UpdatedUnixMs = now + int64(pushed-1)
		return true, map[string]int{"pushed": pushed}, nil
	})
}

func (s *session) importHistory(raw json.RawMessage) (any, error) {
	var p struct {
		Path     string `json:"path"`
		Password string `json:"password"`
		Replace  bool   `json:"replace"`
	}
	if err := decode(raw, &p); err != nil {
		return nil, err
	}
	path, err := cleanTransferPath(p.Path, false)
	if err != nil {
		return nil, err
	}
	blob, err := platform.ReadFileBounded(path, s.engine.Limits.MaxBlobBytes)
	if err != nil {
		return nil, fmt.Errorf("could not read the import file: %w", err)
	}
	imported, err := clipdb.Decode(blob, p.Password, s.engine.Limits)
	if err != nil {
		return nil, fmt.Errorf("the import file could not be opened; check its password: %w", err)
	}
	return s.mutate(func(db *model.Database, now int64) (bool, any, error) {
		count := applyImport(db, imported, p.Replace, s.cfg.Machine, now)
		return count > 0 || p.Replace, map[string]int{"imported": count}, nil
	})
}

func applyImport(target *model.Database, imported model.Database, replace bool, machine string, now int64) int {
	if replace {
		for _, entry := range append([]model.Entry(nil), target.Entries...) {
			merge.AddDeleted(target, entry, machine, now)
		}
		target.Entries = []model.Entry{}
	}
	sort.SliceStable(imported.Entries, func(i, j int) bool {
		return imported.Entries[i].ManualOrder < imported.Entries[j].ManualOrder
	})
	count := 0
	for _, source := range imported.Entries {
		if strings.TrimSpace(source.Text) == "" {
			continue
		}
		entry, outcome := operation.Put(target, source.Text, source.Name, source.Group, machine, "move", merge.NewID(), source.Pinned, source.IsTemplate, now+int64(count))
		if outcome == "created" {
			for i := range target.Entries {
				if target.Entries[i].ID != entry.ID {
					continue
				}
				if source.CreatedUnixMs > 0 {
					target.Entries[i].CreatedUnixMs = source.CreatedUnixMs
				}
				if source.LastUsedUnixMs > 0 {
					target.Entries[i].LastUsedUnixMs = source.LastUsedUnixMs
				}
				if strings.TrimSpace(source.SourceMachine) != "" {
					target.Entries[i].SourceMachine = source.SourceMachine
				}
				break
			}
		}
		count++
	}
	return count
}

func (s *session) exportHistory(raw json.RawMessage) (any, error) {
	var p struct {
		Path            string `json:"path"`
		CurrentPassword string `json:"current_password"`
		Mode            string `json:"mode"`
		ExportPassword  string `json:"export_password"`
	}
	if err := decode(raw, &p); err != nil {
		return nil, err
	}
	if !passwordMatches(p.CurrentPassword, s.password) {
		return nil, errors.New("the history password did not match; clipboard history was not exported")
	}
	var exportPassword string
	switch strings.ToLower(strings.TrimSpace(p.Mode)) {
	case "current":
		exportPassword = s.password
	case "new":
		if p.ExportPassword == "" {
			return nil, errors.New("enter a new password for the export")
		}
		exportPassword = p.ExportPassword
	case "none":
		exportPassword = ""
	default:
		return nil, errors.New("choose current password, new password, or no password")
	}
	path, err := cleanTransferPath(p.Path, true)
	if err != nil {
		return nil, err
	}
	blob, err := clipdb.EncodeWithLimits(s.database, exportPassword, nil, s.codecLimits())
	if err != nil {
		return nil, fmt.Errorf("could not encode the export: %w", err)
	}
	if err := os.MkdirAll(filepath.Dir(path), 0700); err != nil {
		return nil, fmt.Errorf("could not create the export folder: %w", err)
	}
	file, err := os.OpenFile(path, os.O_WRONLY|os.O_CREATE|os.O_TRUNC, 0600)
	if err != nil {
		return nil, fmt.Errorf("could not create the export: %w", err)
	}
	if err := file.Chmod(0600); err != nil {
		file.Close()
		return nil, fmt.Errorf("could not protect the export: %w", err)
	}
	if _, err := file.Write(blob); err != nil {
		file.Close()
		return nil, fmt.Errorf("could not write the export: %w", err)
	}
	if err := file.Sync(); err != nil {
		file.Close()
		return nil, fmt.Errorf("could not finish the export: %w", err)
	}
	if err := file.Close(); err != nil {
		return nil, fmt.Errorf("could not write the export: %w", err)
	}
	return map[string]any{"path": path, "entries": len(s.database.Entries)}, nil
}

func cleanTransferPath(value string, addExtension bool) (string, error) {
	value = strings.TrimSpace(value)
	if value == "" {
		return "", errors.New("a clipboard history file is required")
	}
	path, err := filepath.Abs(value)
	if err != nil {
		return "", errors.New("the clipboard history path is invalid")
	}
	if addExtension && !strings.EqualFold(filepath.Ext(path), ".clipdb") {
		path += ".clipdb"
	}
	return path, nil
}

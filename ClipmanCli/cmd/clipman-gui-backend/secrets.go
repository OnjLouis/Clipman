package main

import (
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"

	"github.com/OnjLouis/Clipman/ClipmanCli/internal/clipdb"
	"github.com/OnjLouis/Clipman/ClipmanCli/internal/merge"
	"github.com/OnjLouis/Clipman/ClipmanCli/internal/model"
	"github.com/OnjLouis/Clipman/ClipmanCli/internal/platform"
)

type secretJSON struct {
	ID   string `json:"id"`
	Name string `json:"name"`
}

func (s *session) secretPath() string {
	return filepath.Join(filepath.Dir(s.configPath), safeDeviceName(s.cfg.Machine)+"-secrets.clipdb")
}

func (s *session) loadSecrets() (model.Database, []byte, error) {
	path := s.secretPath()
	blob, err := os.ReadFile(path)
	if os.IsNotExist(err) {
		return model.NewDatabase(time.Now().UnixMilli()), nil, nil
	}
	if err != nil {
		return model.Database{}, nil, err
	}
	limits := clipdb.DefaultLimits()
	if s.engine != nil {
		limits = s.engine.Limits
	}
	database, err := clipdb.Decode(blob, s.password, limits)
	return database, blob, err
}

func (s *session) saveSecrets(database model.Database, existing []byte) error {
	database.UpdatedUnixMs = time.Now().UnixMilli()
	blob, err := clipdb.Encode(database, s.password, existing)
	if err != nil {
		return err
	}
	return platform.SavePrivate(s.secretPath(), blob)
}

func secretList(database model.Database) []secretJSON {
	entries := append([]model.Entry(nil), database.Entries...)
	sort.SliceStable(entries, func(i, j int) bool {
		if entries[i].ManualOrder != entries[j].ManualOrder {
			return entries[i].ManualOrder < entries[j].ManualOrder
		}
		return strings.ToLower(entries[i].Name) < strings.ToLower(entries[j].Name)
	})
	result := make([]secretJSON, 0, len(entries))
	for _, entry := range entries {
		result = append(result, secretJSON{ID: entry.ID, Name: entry.Name})
	}
	return result
}

func (s *session) listSecrets(raw json.RawMessage) (any, error) {
	var p struct {
		Password string `json:"password"`
	}
	if err := decode(raw, &p); err != nil {
		return nil, err
	}
	if !passwordMatches(p.Password, s.password) {
		return nil, errors.New("the history password did not match")
	}
	database, _, err := s.loadSecrets()
	if err != nil {
		return nil, err
	}
	return map[string]any{"secrets": secretList(database)}, nil
}

func (s *session) putSecret(raw json.RawMessage) (any, error) {
	var p struct {
		ID    string `json:"id"`
		Name  string `json:"name"`
		Value string `json:"value"`
	}
	if err := decode(raw, &p); err != nil {
		return nil, err
	}
	p.Name = strings.TrimSpace(p.Name)
	if p.Name == "" || p.Value == "" {
		return nil, errors.New("secret name and value are required")
	}
	database, existing, err := s.loadSecrets()
	if err != nil {
		return nil, err
	}
	now := time.Now().UnixMilli()
	if p.ID != "" {
		for index := range database.Entries {
			if strings.EqualFold(database.Entries[index].ID, p.ID) {
				database.Entries[index].Name = p.Name
				database.Entries[index].Text = p.Value
				database.Entries[index].LastUsedUnixMs = now
				if err := s.saveSecrets(database, existing); err != nil {
					return nil, err
				}
				return map[string]any{"secrets": secretList(database), "id": database.Entries[index].ID}, nil
			}
		}
		return nil, errors.New("secret was changed or deleted")
	}
	order := int64(len(database.Entries) + 1)
	entry := model.Entry{ID: merge.NewID(), Name: p.Name, Text: p.Value, SourceMachine: s.cfg.Machine, CreatedUnixMs: now, LastUsedUnixMs: now, ManualOrder: order}
	database.Entries = append(database.Entries, entry)
	if err := s.saveSecrets(database, existing); err != nil {
		return nil, err
	}
	return map[string]any{"secrets": secretList(database), "id": entry.ID}, nil
}

func (s *session) getSecret(raw json.RawMessage) (any, error) {
	var p struct {
		ID string `json:"id"`
	}
	if err := decode(raw, &p); err != nil {
		return nil, err
	}
	database, _, err := s.loadSecrets()
	if err != nil {
		return nil, err
	}
	for _, entry := range database.Entries {
		if strings.EqualFold(entry.ID, p.ID) {
			return map[string]string{"id": entry.ID, "name": entry.Name, "value": entry.Text}, nil
		}
	}
	return nil, errors.New("secret was changed or deleted")
}

func (s *session) deleteSecret(raw json.RawMessage) (any, error) {
	var p struct {
		ID string `json:"id"`
	}
	if err := decode(raw, &p); err != nil {
		return nil, err
	}
	database, existing, err := s.loadSecrets()
	if err != nil {
		return nil, err
	}
	for index, entry := range database.Entries {
		if strings.EqualFold(entry.ID, p.ID) {
			database.Entries = append(database.Entries[:index], database.Entries[index+1:]...)
			if err := s.saveSecrets(database, existing); err != nil {
				return nil, err
			}
			return map[string]any{"secrets": secretList(database)}, nil
		}
	}
	return nil, errors.New("secret was changed or deleted")
}

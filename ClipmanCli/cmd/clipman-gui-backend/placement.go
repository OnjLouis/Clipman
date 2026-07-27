package main

import (
	"encoding/json"
	"errors"
	"sort"
	"strings"

	"github.com/OnjLouis/Clipman/ClipmanCli/internal/merge"
	"github.com/OnjLouis/Clipman/ClipmanCli/internal/model"
	"github.com/OnjLouis/Clipman/ClipmanCli/internal/operation"
)

func (s *session) putAfter(raw json.RawMessage) (any, error) {
	var p struct {
		AfterID  string        `json:"after_id"`
		Text     string        `json:"text"`
		RichText *richTextJSON `json:"rich_text"`
	}
	if err := decode(raw, &p); err != nil {
		return nil, err
	}
	if strings.TrimSpace(p.Text) == "" {
		return nil, errors.New("clipboard text cannot be empty")
	}
	return s.mutate(func(db *model.Database, now int64) (bool, any, error) {
		entry, outcome := operation.Put(db, p.Text, "", "", s.cfg.Machine, "move", merge.NewID(), false, false, now)
		if outcome == "ignored" {
			return false, map[string]any{"entry": exportEntry(entry), "outcome": outcome}, nil
		}
		if richText := normalizeRichText(p.RichText); richText != nil {
			for index := range db.Entries {
				if strings.EqualFold(db.Entries[index].ID, entry.ID) {
					setRichText(&db.Entries[index], richText, now)
					entry = db.Entries[index]
					break
				}
			}
		}
		placeAfter(db, entry.ID, p.AfterID)
		return true, map[string]any{"entry": exportEntry(entry), "outcome": outcome}, nil
	})
}

func placeAfter(db *model.Database, id, afterID string) {
	sort.SliceStable(db.Entries, func(i, j int) bool {
		if db.Entries[i].Pinned != db.Entries[j].Pinned {
			return db.Entries[i].Pinned
		}
		return db.Entries[i].ManualOrder < db.Entries[j].ManualOrder
	})
	moving := -1
	after := -1
	for i := range db.Entries {
		if strings.EqualFold(db.Entries[i].ID, id) {
			moving = i
		}
		if strings.EqualFold(db.Entries[i].ID, afterID) {
			after = i
		}
	}
	if moving < 0 {
		return
	}
	entry := db.Entries[moving]
	db.Entries = append(db.Entries[:moving], db.Entries[moving+1:]...)
	if after >= moving {
		after--
	}
	insert := after + 1
	if after < 0 || (after < len(db.Entries) && db.Entries[after].Pinned != entry.Pinned) {
		insert = 0
		for insert < len(db.Entries) && db.Entries[insert].Pinned {
			insert++
		}
	}
	if insert < 0 {
		insert = 0
	}
	if insert > len(db.Entries) {
		insert = len(db.Entries)
	}
	db.Entries = append(db.Entries, model.Entry{})
	copy(db.Entries[insert+1:], db.Entries[insert:])
	db.Entries[insert] = entry
	for i := range db.Entries {
		db.Entries[i].ManualOrder = int64(i + 1)
	}
}

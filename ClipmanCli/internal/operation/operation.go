package operation

import (
	"encoding/json"
	"errors"
	"sort"
	"strings"

	"github.com/OnjLouis/Clipman/ClipmanCli/internal/merge"
	"github.com/OnjLouis/Clipman/ClipmanCli/internal/model"
)

type Kind string

const (
	History   Kind = "history"
	Templates Kind = "templates"
	All       Kind = "all"
)

func ParseKind(value string) (Kind, error) {
	kind := Kind(strings.ToLower(strings.TrimSpace(value)))
	switch kind {
	case History, Templates, All:
		return kind, nil
	default:
		return "", errors.New("kind must be history, templates, or all")
	}
}

type Selector struct {
	Index                *int
	ID, Name, Search     string
	First, CaseSensitive bool
}

func View(database model.Database, kind Kind, pinnedFirst bool) []model.Entry {
	result := make([]model.Entry, 0, len(database.Entries))
	for _, entry := range database.Entries {
		if kind == History && entry.IsTemplate {
			continue
		}
		if kind == Templates && !entry.IsTemplate {
			continue
		}
		result = append(result, entry)
	}
	sort.SliceStable(result, func(i, j int) bool {
		if pinnedFirst && result[i].Pinned != result[j].Pinned {
			return result[i].Pinned
		}
		if result[i].LastUsedUnixMs != result[j].LastUsedUnixMs {
			return result[i].LastUsedUnixMs > result[j].LastUsedUnixMs
		}
		if result[i].CreatedUnixMs != result[j].CreatedUnixMs {
			return result[i].CreatedUnixMs > result[j].CreatedUnixMs
		}
		return result[i].ID < result[j].ID
	})
	return result
}

func Select(entries []model.Entry, selector Selector) (model.Entry, int, error) {
	matches := []int{}
	switch {
	case selector.Index != nil:
		if *selector.Index < 0 || *selector.Index >= len(entries) {
			return model.Entry{}, -1, errors.New("entry not found")
		}
		matches = []int{*selector.Index}
	case selector.ID != "":
		for i, e := range entries {
			if e.ID == selector.ID {
				matches = append(matches, i)
			}
		}
	case selector.Name != "":
		for i, e := range entries {
			if equal(e.Name, selector.Name, selector.CaseSensitive) {
				matches = append(matches, i)
			}
		}
	case selector.Search != "":
		for i, e := range entries {
			if contains(e.Name, selector.Search, selector.CaseSensitive) || contains(e.Text, selector.Search, selector.CaseSensitive) {
				matches = append(matches, i)
			}
		}
	default:
		if len(entries) > 0 {
			matches = []int{0}
		}
	}
	if len(matches) == 0 {
		return model.Entry{}, -1, errors.New("entry not found")
	}
	if len(matches) > 1 && !selector.First {
		return model.Entry{}, -1, errors.New("selection is ambiguous")
	}
	index := matches[0]
	return entries[index], index, nil
}

func Put(database *model.Database, text, name, group, machine, duplicate, newID string, pinned, isTemplate bool, now int64) (model.Entry, string) {
	// An explicit put is a new user intent, so an older deletion of the same
	// text must not immediately remove the newly created entry again.
	textHash := merge.TextHash(text)
	deleted := database.Deleted[:0]
	for _, marker := range database.Deleted {
		if !strings.EqualFold(marker.TextHash, textHash) {
			deleted = append(deleted, marker)
		}
	}
	database.Deleted = deleted
	for index := range database.Entries {
		entry := &database.Entries[index]
		if entry.Text == text && entry.IsTemplate == isTemplate {
			switch strings.ToLower(duplicate) {
			case "ignore":
				return *entry, "ignored"
			case "keep":
			default:
				entry.LastUsedUnixMs = now
				entry.SourceMachine = machine
				database.UpdatedUnixMs = now
				return *entry, "moved"
			}
		}
	}
	maxOrder := int64(0)
	for _, entry := range database.Entries {
		if entry.ManualOrder > maxOrder {
			maxOrder = entry.ManualOrder
		}
	}
	if newID == "" {
		newID = merge.NewID()
	}
	entry := model.Entry{ID: newID, Text: text, Name: strings.TrimSpace(name), Group: strings.TrimSpace(group), SourceMachine: machine, CreatedUnixMs: now, LastUsedUnixMs: now, Pinned: pinned, IsTemplate: isTemplate, ManualOrder: maxOrder + 1, Extra: map[string]json.RawMessage{}}
	database.Entries = append(database.Entries, entry)
	database.UpdatedUnixMs = now
	return entry, "created"
}

func Delete(database *model.Database, id, machine string, now int64) (model.Entry, error) {
	for index, entry := range database.Entries {
		if strings.EqualFold(entry.ID, id) {
			database.Entries = append(database.Entries[:index], database.Entries[index+1:]...)
			merge.AddDeleted(database, entry, machine, now)
			database.UpdatedUnixMs = now
			return entry, nil
		}
	}
	return model.Entry{}, errors.New("entry was deleted by another client")
}
func Touch(database *model.Database, id string, now int64) (model.Entry, error) {
	for index := range database.Entries {
		if strings.EqualFold(database.Entries[index].ID, id) {
			database.Entries[index].LastUsedUnixMs = now
			database.UpdatedUnixMs = now
			return database.Entries[index], nil
		}
	}
	return model.Entry{}, errors.New("entry was deleted by another client")
}
func equal(a, b string, sensitive bool) bool {
	if sensitive {
		return a == b
	}
	return strings.EqualFold(a, b)
}
func contains(value, needle string, sensitive bool) bool {
	if sensitive {
		return strings.Contains(value, needle)
	}
	return strings.Contains(strings.ToLower(value), strings.ToLower(needle))
}

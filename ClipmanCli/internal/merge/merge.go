package merge

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"sort"
	"strings"
	"time"

	"github.com/OnjLouis/Clipman/ClipmanCli/internal/model"
)

const tombstoneDays = 90

func Normalize(database *model.Database, now int64) {
	if database.Version < 1 {
		database.Version = 1
	}
	if database.Extra == nil {
		database.Extra = map[string]json.RawMessage{}
	}
	normalizeDeleted(database, now)
	applyDeleted(database)
	entries := make([]model.Entry, 0, len(database.Entries))
	seenIDs := map[string]bool{}
	for _, entry := range database.Entries {
		if entry.Text == "" {
			continue
		}
		entry.ID = strings.TrimSpace(entry.ID)
		if entry.ID == "" || seenIDs[strings.ToLower(entry.ID)] {
			entry.ID = NewID()
		}
		seenIDs[strings.ToLower(entry.ID)] = true
		if entry.CreatedUnixMs <= 0 {
			entry.CreatedUnixMs = now
		}
		if entry.LastUsedUnixMs <= 0 {
			entry.LastUsedUnixMs = entry.CreatedUnixMs
		}
		if entry.Name == "" {
			entry.Name = ""
		}
		if entry.Group == "" {
			entry.Group = ""
		}
		if entry.SourceMachine == "" {
			entry.SourceMachine = ""
		}
		entries = append(entries, entry)
	}
	sort.SliceStable(entries, func(i, j int) bool {
		li, lj := entries[i].ManualOrder, entries[j].ManualOrder
		if li <= 0 && lj > 0 {
			return false
		}
		if li > 0 && lj <= 0 {
			return true
		}
		if li != lj {
			return li < lj
		}
		if entries[i].CreatedUnixMs != entries[j].CreatedUnixMs {
			return entries[i].CreatedUnixMs < entries[j].CreatedUnixMs
		}
		return entries[i].ID < entries[j].ID
	})
	for index := range entries {
		entries[index].ManualOrder = int64(index + 1)
	}
	database.Entries = entries
	database.UpdatedUnixMs = now
}

func Merge(target *model.Database, source model.Database, now int64) {
	mergeDeleted(target, source.Deleted, now)
	applyDeleted(target)
	for _, incoming := range source.Entries {
		if incoming.Text == "" || IsDeleted(*target, incoming) {
			continue
		}
		index := findByID(target.Entries, incoming.ID)
		if index < 0 {
			index = findByText(target.Entries, incoming.Text)
		}
		if index < 0 {
			target.Entries = append(target.Entries, incoming)
			continue
		}
		mergeEntry(&target.Entries[index], incoming)
	}
	if source.Version > target.Version {
		target.Version = source.Version
	}
	for key, value := range source.Extra {
		if _, ok := target.Extra[key]; !ok {
			target.Extra[key] = append([]byte(nil), value...)
		}
	}
	Normalize(target, now)
}

func IsDeleted(database model.Database, entry model.Entry) bool {
	hash := TextHash(entry.Text)
	for _, marker := range database.Deleted {
		if strings.EqualFold(marker.ID, entry.ID) || marker.TextHash != "" && strings.EqualFold(marker.TextHash, hash) {
			return true
		}
	}
	return false
}
func TextHash(text string) string {
	sum := sha256.Sum256([]byte(text))
	return hex.EncodeToString(sum[:])
}

func AddDeleted(database *model.Database, entry model.Entry, machine string, now int64) {
	marker := model.DeletedEntry{ID: entry.ID, TextHash: TextHash(entry.Text), DeletedUnixMs: now, SourceMachine: machine, Extra: map[string]json.RawMessage{}}
	found := false
	for index := range database.Deleted {
		if strings.EqualFold(database.Deleted[index].ID, entry.ID) {
			database.Deleted[index] = marker
			found = true
			break
		}
	}
	if !found {
		database.Deleted = append(database.Deleted, marker)
	}
	normalizeDeleted(database, now)
	applyDeleted(database)
}

func mergeEntry(existing *model.Entry, incoming model.Entry) {
	incomingWins := incoming.LastUsedUnixMs >= existing.LastUsedUnixMs
	createdWins := incoming.CreatedUnixMs > existing.CreatedUnixMs
	if incoming.LastUsedUnixMs > existing.LastUsedUnixMs {
		existing.LastUsedUnixMs = incoming.LastUsedUnixMs
	}
	if incoming.CreatedUnixMs > 0 && (existing.CreatedUnixMs == 0 || createdWins || (!incomingWins && incoming.CreatedUnixMs < existing.CreatedUnixMs)) {
		existing.CreatedUnixMs = incoming.CreatedUnixMs
	}
	if strings.TrimSpace(incoming.Name) != "" && incomingWins {
		existing.Name = strings.TrimSpace(incoming.Name)
	}
	if strings.TrimSpace(incoming.Group) != "" && incomingWins {
		existing.Group = strings.TrimSpace(incoming.Group)
	}
	if strings.TrimSpace(incoming.SourceMachine) != "" && (incomingWins || createdWins) {
		existing.SourceMachine = strings.TrimSpace(incoming.SourceMachine)
	}
	if incoming.Pinned {
		existing.Pinned = true
	}
	if existing.ManualOrder <= 0 || (incoming.ManualOrder > 0 && incoming.ManualOrder < existing.ManualOrder) {
		existing.ManualOrder = incoming.ManualOrder
	}
	if existing.Extra == nil {
		existing.Extra = map[string]json.RawMessage{}
	}
	for key, value := range incoming.Extra {
		if _, ok := existing.Extra[key]; !ok || incomingWins {
			existing.Extra[key] = append([]byte(nil), value...)
		}
	}
}
func mergeDeleted(database *model.Database, incoming []model.DeletedEntry, now int64) {
	database.Deleted = append(database.Deleted, incoming...)
	normalizeDeleted(database, now)
}
func normalizeDeleted(database *model.Database, now int64) {
	cutoff := now - int64(tombstoneDays)*24*int64(time.Hour/time.Millisecond)
	byID := map[string]model.DeletedEntry{}
	for _, marker := range database.Deleted {
		marker.ID = strings.TrimSpace(marker.ID)
		if marker.ID == "" {
			continue
		}
		if marker.DeletedUnixMs <= 0 {
			marker.DeletedUnixMs = now
		}
		if marker.DeletedUnixMs < cutoff {
			continue
		}
		key := strings.ToLower(marker.ID)
		existing, ok := byID[key]
		if !ok || marker.DeletedUnixMs > existing.DeletedUnixMs {
			if marker.TextHash == "" && ok {
				marker.TextHash = existing.TextHash
			}
			byID[key] = marker
		} else if existing.TextHash == "" && marker.TextHash != "" {
			existing.TextHash = marker.TextHash
			byID[key] = existing
		}
	}
	database.Deleted = database.Deleted[:0]
	for _, marker := range byID {
		database.Deleted = append(database.Deleted, marker)
	}
	sort.Slice(database.Deleted, func(i, j int) bool {
		if database.Deleted[i].DeletedUnixMs != database.Deleted[j].DeletedUnixMs {
			return database.Deleted[i].DeletedUnixMs > database.Deleted[j].DeletedUnixMs
		}
		return database.Deleted[i].ID < database.Deleted[j].ID
	})
}
func applyDeleted(database *model.Database) {
	if len(database.Deleted) == 0 {
		return
	}
	kept := database.Entries[:0]
	for _, entry := range database.Entries {
		if !IsDeleted(*database, entry) {
			kept = append(kept, entry)
		}
	}
	database.Entries = kept
}
func findByID(entries []model.Entry, id string) int {
	if strings.TrimSpace(id) == "" {
		return -1
	}
	for index := range entries {
		if strings.EqualFold(entries[index].ID, id) {
			return index
		}
	}
	return -1
}
func findByText(entries []model.Entry, text string) int {
	for index := range entries {
		if entries[index].Text == text {
			return index
		}
	}
	return -1
}

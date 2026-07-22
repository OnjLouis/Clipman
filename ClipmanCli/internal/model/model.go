package model

import (
	"bytes"
	"encoding/json"
)

type Entry struct {
	ID             string
	Text           string
	Name           string
	Group          string
	SourceMachine  string
	CreatedUnixMs  int64
	LastUsedUnixMs int64
	Pinned         bool
	IsTemplate     bool
	ManualOrder    int64
	Extra          map[string]json.RawMessage
}

type DeletedEntry struct {
	ID            string
	TextHash      string
	DeletedUnixMs int64
	SourceMachine string
	Extra         map[string]json.RawMessage
}

type Database struct {
	Version       int
	UpdatedUnixMs int64
	Entries       []Entry
	Deleted       []DeletedEntry
	Extra         map[string]json.RawMessage
}

func NewDatabase(now int64) Database {
	return Database{Version: 1, UpdatedUnixMs: now, Entries: []Entry{}, Deleted: []DeletedEntry{}, Extra: map[string]json.RawMessage{}}
}

func (e *Entry) UnmarshalJSON(data []byte) error {
	var raw map[string]json.RawMessage
	if err := json.Unmarshal(data, &raw); err != nil {
		return err
	}
	e.Extra = cloneRawMap(raw)
	if err := decodeString(raw, "Id", &e.ID); err != nil {
		return err
	}
	if err := decodeString(raw, "Text", &e.Text); err != nil {
		return err
	}
	if err := decodeString(raw, "Name", &e.Name); err != nil {
		return err
	}
	if err := decodeString(raw, "Group", &e.Group); err != nil {
		return err
	}
	if err := decodeString(raw, "SourceMachine", &e.SourceMachine); err != nil {
		return err
	}
	if err := decodeInt64(raw, "CreatedUnixMs", &e.CreatedUnixMs); err != nil {
		return err
	}
	if err := decodeInt64(raw, "LastUsedUnixMs", &e.LastUsedUnixMs); err != nil {
		return err
	}
	if err := decodeBool(raw, "Pinned", &e.Pinned); err != nil {
		return err
	}
	if err := decodeBool(raw, "IsTemplate", &e.IsTemplate); err != nil {
		return err
	}
	if err := decodeInt64(raw, "ManualOrder", &e.ManualOrder); err != nil {
		return err
	}
	removeKeys(e.Extra, "Id", "Text", "Name", "Group", "SourceMachine", "CreatedUnixMs", "LastUsedUnixMs", "Pinned", "IsTemplate", "ManualOrder")
	return nil
}

func (e Entry) MarshalJSON() ([]byte, error) {
	raw := cloneRawMap(e.Extra)
	setRaw(raw, "Id", e.ID)
	setRaw(raw, "Text", e.Text)
	setRaw(raw, "Name", e.Name)
	setRaw(raw, "Group", e.Group)
	setRaw(raw, "SourceMachine", e.SourceMachine)
	setRaw(raw, "CreatedUnixMs", e.CreatedUnixMs)
	setRaw(raw, "LastUsedUnixMs", e.LastUsedUnixMs)
	setRaw(raw, "Pinned", e.Pinned)
	setRaw(raw, "IsTemplate", e.IsTemplate)
	setRaw(raw, "ManualOrder", e.ManualOrder)
	return marshalOrdered(raw, []string{"Id", "Text", "Name", "Group", "SourceMachine", "CreatedUnixMs", "LastUsedUnixMs", "Pinned", "IsTemplate", "ManualOrder"})
}

func (d *DeletedEntry) UnmarshalJSON(data []byte) error {
	var raw map[string]json.RawMessage
	if err := json.Unmarshal(data, &raw); err != nil {
		return err
	}
	d.Extra = cloneRawMap(raw)
	if err := decodeString(raw, "Id", &d.ID); err != nil {
		return err
	}
	if err := decodeString(raw, "TextHash", &d.TextHash); err != nil {
		return err
	}
	if err := decodeInt64(raw, "DeletedUnixMs", &d.DeletedUnixMs); err != nil {
		return err
	}
	if err := decodeString(raw, "SourceMachine", &d.SourceMachine); err != nil {
		return err
	}
	removeKeys(d.Extra, "Id", "TextHash", "DeletedUnixMs", "SourceMachine")
	return nil
}

func (d DeletedEntry) MarshalJSON() ([]byte, error) {
	raw := cloneRawMap(d.Extra)
	setRaw(raw, "Id", d.ID)
	setRaw(raw, "TextHash", d.TextHash)
	setRaw(raw, "DeletedUnixMs", d.DeletedUnixMs)
	setRaw(raw, "SourceMachine", d.SourceMachine)
	return marshalOrdered(raw, []string{"Id", "TextHash", "DeletedUnixMs", "SourceMachine"})
}

func (d *Database) UnmarshalJSON(data []byte) error {
	var raw map[string]json.RawMessage
	if err := json.Unmarshal(data, &raw); err != nil {
		return err
	}
	d.Extra = cloneRawMap(raw)
	if value, ok := raw["Version"]; ok && string(value) != "null" {
		if err := json.Unmarshal(value, &d.Version); err != nil {
			return err
		}
	}
	if value, ok := raw["UpdatedUnixMs"]; ok && string(value) != "null" {
		if err := json.Unmarshal(value, &d.UpdatedUnixMs); err != nil {
			return err
		}
	}
	if value, ok := raw["Entries"]; ok && string(value) != "null" {
		if err := json.Unmarshal(value, &d.Entries); err != nil {
			return err
		}
	}
	if value, ok := raw["DeletedEntries"]; ok && string(value) != "null" {
		if err := json.Unmarshal(value, &d.Deleted); err != nil {
			return err
		}
	}
	if d.Entries == nil {
		d.Entries = []Entry{}
	}
	if d.Deleted == nil {
		d.Deleted = []DeletedEntry{}
	}
	removeKeys(d.Extra, "Version", "UpdatedUnixMs", "Entries", "DeletedEntries")
	return nil
}

func (d Database) MarshalJSON() ([]byte, error) {
	raw := cloneRawMap(d.Extra)
	setRaw(raw, "Version", d.Version)
	setRaw(raw, "UpdatedUnixMs", d.UpdatedUnixMs)
	setRaw(raw, "Entries", d.Entries)
	setRaw(raw, "DeletedEntries", d.Deleted)
	return marshalOrdered(raw, []string{"Version", "UpdatedUnixMs", "Entries", "DeletedEntries"})
}

func cloneRawMap(source map[string]json.RawMessage) map[string]json.RawMessage {
	out := make(map[string]json.RawMessage, len(source))
	for key, value := range source {
		out[key] = append(json.RawMessage(nil), value...)
	}
	return out
}

func removeKeys(raw map[string]json.RawMessage, keys ...string) {
	for _, key := range keys {
		delete(raw, key)
	}
}
func decodeString(raw map[string]json.RawMessage, key string, target *string) error {
	if value, ok := raw[key]; ok && string(value) != "null" {
		return json.Unmarshal(value, target)
	}
	return nil
}
func decodeInt64(raw map[string]json.RawMessage, key string, target *int64) error {
	if value, ok := raw[key]; ok && string(value) != "null" {
		return json.Unmarshal(value, target)
	}
	return nil
}
func decodeBool(raw map[string]json.RawMessage, key string, target *bool) error {
	if value, ok := raw[key]; ok && string(value) != "null" {
		return json.Unmarshal(value, target)
	}
	return nil
}
func setRaw(raw map[string]json.RawMessage, key string, value any) {
	encoded, _ := json.Marshal(value)
	raw[key] = encoded
}

func marshalOrdered(raw map[string]json.RawMessage, preferred []string) ([]byte, error) {
	var out bytes.Buffer
	out.WriteByte('{')
	first := true
	written := make(map[string]bool, len(raw))
	write := func(key string) error {
		value, ok := raw[key]
		if !ok {
			return nil
		}
		if !first {
			out.WriteByte(',')
		}
		first = false
		keyBytes, _ := json.Marshal(key)
		out.Write(keyBytes)
		out.WriteByte(':')
		out.Write(value)
		written[key] = true
		return nil
	}
	for _, key := range preferred {
		_ = write(key)
	}
	keys := make([]string, 0, len(raw))
	for key := range raw {
		if !written[key] {
			keys = append(keys, key)
		}
	}
	for i := 0; i < len(keys); i++ {
		for j := i + 1; j < len(keys); j++ {
			if keys[j] < keys[i] {
				keys[i], keys[j] = keys[j], keys[i]
			}
		}
	}
	for _, key := range keys {
		_ = write(key)
	}
	out.WriteByte('}')
	return out.Bytes(), nil
}

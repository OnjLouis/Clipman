package model

import (
	"encoding/json"
	"time"
)

type FileEvent struct {
	ID             string
	CapturedUnixMs int64
	Source         string
	Operation      string
	SourceMachine  string
	ContainsText   bool
	FileCount      int
	Files          []string
	Formats        []string
	Pinned         bool
	ManualOrder    int64
	Extra          map[string]json.RawMessage
}

type FileDatabase struct {
	Version       int
	UpdatedUnixMs int64
	Events        []FileEvent
	Extra         map[string]json.RawMessage
}

func NewFileDatabase(now int64) FileDatabase {
	return FileDatabase{Version: 1, UpdatedUnixMs: now, Events: []FileEvent{}, Extra: map[string]json.RawMessage{}}
}

func (e *FileEvent) UnmarshalJSON(data []byte) error {
	var raw map[string]json.RawMessage
	if err := json.Unmarshal(data, &raw); err != nil {
		return err
	}
	e.Extra = cloneRawMap(raw)
	if err := decodeString(raw, "Id", &e.ID); err != nil {
		return err
	}
	if err := decodeInt64(raw, "CapturedUnixMs", &e.CapturedUnixMs); err != nil {
		return err
	}
	if err := decodeString(raw, "Source", &e.Source); err != nil {
		return err
	}
	if err := decodeString(raw, "Operation", &e.Operation); err != nil {
		return err
	}
	if err := decodeString(raw, "SourceMachine", &e.SourceMachine); err != nil {
		return err
	}
	if err := decodeBool(raw, "ContainsText", &e.ContainsText); err != nil {
		return err
	}
	if value, ok := raw["FileCount"]; ok && string(value) != "null" {
		if err := json.Unmarshal(value, &e.FileCount); err != nil {
			return err
		}
	}
	if value, ok := raw["Files"]; ok && string(value) != "null" {
		if err := json.Unmarshal(value, &e.Files); err != nil {
			return err
		}
	}
	if value, ok := raw["Formats"]; ok && string(value) != "null" {
		if err := json.Unmarshal(value, &e.Formats); err != nil {
			return err
		}
	}
	if err := decodeBool(raw, "Pinned", &e.Pinned); err != nil {
		return err
	}
	if err := decodeInt64(raw, "ManualOrder", &e.ManualOrder); err != nil {
		return err
	}
	if e.Files == nil {
		e.Files = []string{}
	}
	if e.Formats == nil {
		e.Formats = []string{}
	}
	removeKeys(e.Extra, "Id", "CapturedUnixMs", "Source", "Operation", "SourceMachine", "ContainsText", "FileCount", "Files", "Formats", "Pinned", "ManualOrder")
	return nil
}

func (e FileEvent) MarshalJSON() ([]byte, error) {
	raw := cloneRawMap(e.Extra)
	setRaw(raw, "Id", e.ID)
	setRaw(raw, "CapturedUnixMs", e.CapturedUnixMs)
	setRaw(raw, "Source", e.Source)
	setRaw(raw, "Operation", e.Operation)
	setRaw(raw, "SourceMachine", e.SourceMachine)
	setRaw(raw, "ContainsText", e.ContainsText)
	setRaw(raw, "FileCount", e.FileCount)
	setRaw(raw, "Files", e.Files)
	setRaw(raw, "Formats", e.Formats)
	setRaw(raw, "Pinned", e.Pinned)
	setRaw(raw, "ManualOrder", e.ManualOrder)
	return marshalOrdered(raw, []string{"Id", "CapturedUnixMs", "Source", "Operation", "SourceMachine", "ContainsText", "FileCount", "Files", "Formats", "Pinned", "ManualOrder"})
}

func (d *FileDatabase) UnmarshalJSON(data []byte) error {
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
	if value, ok := raw["Events"]; ok && string(value) != "null" {
		if err := json.Unmarshal(value, &d.Events); err != nil {
			return err
		}
	}
	if d.Version < 1 {
		d.Version = 1
	}
	if d.UpdatedUnixMs <= 0 {
		d.UpdatedUnixMs = time.Now().UnixMilli()
	}
	if d.Events == nil {
		d.Events = []FileEvent{}
	}
	removeKeys(d.Extra, "Version", "UpdatedUnixMs", "Events")
	return nil
}

func (d FileDatabase) MarshalJSON() ([]byte, error) {
	raw := cloneRawMap(d.Extra)
	setRaw(raw, "Version", d.Version)
	setRaw(raw, "UpdatedUnixMs", d.UpdatedUnixMs)
	setRaw(raw, "Events", d.Events)
	return marshalOrdered(raw, []string{"Version", "UpdatedUnixMs", "Events"})
}

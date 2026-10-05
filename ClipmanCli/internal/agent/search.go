// Package agent bounds the plain-text history data returned to integrations.
package agent

import (
	"encoding/json"
	"errors"
	"fmt"
	"sort"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/OnjLouis/Clipman/ClipmanCli/internal/model"
)

const (
	MaxResults       = 50
	DefaultResults   = 20
	MaxRangeDays     = 31
	MaxResponseBytes = 64 << 10
	MaxQueryRunes    = 256
	PreviewRunes     = 300
	MaxMetadataRunes = 200
	MaxIDBytes       = 128
)

type Query struct {
	Text, Group, Device string
	From, Through       time.Time
	Limit               int
}

type Entry struct {
	ID                string    `json:"id"`
	Name              string    `json:"name"`
	Group             string    `json:"group"`
	Device            string    `json:"device"`
	CreatedAt         time.Time `json:"created_at"`
	Preview           string    `json:"preview,omitempty"`
	PreviewTruncated  bool      `json:"preview_truncated,omitempty"`
	MetadataTruncated bool      `json:"metadata_truncated,omitempty"`
	Text              *string   `json:"text,omitempty"`
}

type SearchResult struct {
	SchemaVersion int       `json:"schema_version"`
	Freshness     string    `json:"freshness"`
	ContentTrust  string    `json:"content_trust"`
	From          time.Time `json:"from"`
	Until         time.Time `json:"until"`
	Matches       int       `json:"matches"`
	Truncated     bool      `json:"truncated"`
	Entries       []Entry   `json:"entries"`
}

func DateRange(from, through string, now time.Time) (time.Time, time.Time, error) {
	today := time.Date(now.Year(), now.Month(), now.Day(), 0, 0, 0, 0, now.Location())
	start, last := today, today
	var err error
	if from != "" {
		start, err = time.ParseInLocation(time.DateOnly, from, now.Location())
		if err != nil {
			return time.Time{}, time.Time{}, errors.New("from must be YYYY-MM-DD")
		}
	}
	if through != "" {
		last, err = time.ParseInLocation(time.DateOnly, through, now.Location())
		if err != nil {
			return time.Time{}, time.Time{}, errors.New("through must be YYYY-MM-DD")
		}
	} else if from != "" {
		last = start
	}
	if last.Before(start) || !last.Before(start.AddDate(0, 0, MaxRangeDays)) {
		return time.Time{}, time.Time{}, errors.New("date range must cover between 1 and 31 calendar days")
	}
	return start, last.AddDate(0, 0, 1), nil
}

func (q Query) Validate() error {
	if strings.TrimSpace(q.Text) == "" || !utf8.ValidString(q.Text) || utf8.RuneCountInString(q.Text) > MaxQueryRunes {
		return errors.New("query must contain between 1 and 256 characters of nonblank UTF-8 text")
	}
	if q.Limit < 1 || q.Limit > MaxResults {
		return errors.New("limit must be between 1 and 50")
	}
	if !q.Through.After(q.From) || q.Through.After(q.From.AddDate(0, 0, MaxRangeDays)) {
		return errors.New("date range must cover between 1 and 31 calendar days")
	}
	for _, filter := range []string{q.Group, q.Device} {
		if !utf8.ValidString(filter) || utf8.RuneCountInString(filter) > MaxQueryRunes {
			return errors.New("group and device filters must be valid UTF-8 of at most 256 characters")
		}
	}
	return nil
}

// Eligible excludes templates and all rich payloads; Secrets use a separate
// store which the CLI never opens. Extra fields are never returned.
func Eligible(e model.Entry) bool {
	_, rich := e.Extra["RichText"]
	return !e.IsTemplate && !rich && e.ID != "" && len(e.ID) <= MaxIDBytes && utf8.ValidString(e.ID)
}

func Search(entries []model.Entry, q Query) (SearchResult, error) {
	if err := q.Validate(); err != nil {
		return SearchResult{}, err
	}
	result := SearchResult{SchemaVersion: 1, Freshness: "server", ContentTrust: "untrusted_data", From: q.From, Until: q.Through, Entries: []Entry{}}
	matches := make([]model.Entry, 0, q.Limit)
	term := strings.ToLower(strings.TrimSpace(q.Text))
	for _, e := range entries {
		if !Eligible(e) {
			continue
		}
		created := time.UnixMilli(e.CreatedUnixMs)
		if created.Before(q.From) || !created.Before(q.Through) {
			continue
		}
		if q.Group != "" && !strings.EqualFold(strings.TrimSpace(e.Group), strings.TrimSpace(q.Group)) {
			continue
		}
		if q.Device != "" && !strings.EqualFold(strings.TrimSpace(e.SourceMachine), strings.TrimSpace(q.Device)) {
			continue
		}
		if !strings.Contains(strings.ToLower(e.Name), term) && !strings.Contains(strings.ToLower(e.Text), term) {
			continue
		}
		result.Matches++
		// Retain only the newest requested matches, rather than making another
		// history-sized allocation for a common search term.
		position := sort.Search(len(matches), func(i int) bool {
			if matches[i].CreatedUnixMs != e.CreatedUnixMs {
				return matches[i].CreatedUnixMs < e.CreatedUnixMs
			}
			return matches[i].ID > e.ID
		})
		if position == q.Limit {
			continue
		}
		if len(matches) < q.Limit {
			matches = append(matches, model.Entry{})
		}
		copy(matches[position+1:], matches[position:len(matches)-1])
		matches[position] = e
	}
	for _, e := range matches {
		if len(result.Entries) == q.Limit {
			break
		}
		item := metadata(e)
		item.Preview, item.PreviewTruncated = boundedText(e.Text, PreviewRunes)
		result.Entries = append(result.Entries, item)
		if _, err := Encode(result); err != nil {
			result.Entries = result.Entries[:len(result.Entries)-1]
			break
		}
	}
	result.Truncated = len(result.Entries) < result.Matches
	return result, nil
}

func Get(entries []model.Entry, id string) (Entry, error) {
	if id == "" || len(id) > MaxIDBytes || !utf8.ValidString(id) {
		return Entry{}, errors.New("an exact entry ID of at most 128 UTF-8 bytes is required")
	}
	for _, e := range entries {
		if e.ID != id || !Eligible(e) {
			continue
		}
		if len(e.Text) > MaxResponseBytes {
			return Entry{}, errors.New("entry exceeds the 64 KiB response limit; view it in Clipman instead")
		}
		item := metadata(e)
		item.Text = &e.Text
		return item, nil
	}
	return Entry{}, errors.New("entry not found in accessible plain-text history")
}

func Encode(value any) ([]byte, error) {
	data, err := json.Marshal(value)
	if err != nil {
		return nil, err
	}
	if len(data)+1 > MaxResponseBytes {
		return nil, fmt.Errorf("response exceeds the %d-byte limit; narrow the search or view the entry in Clipman", MaxResponseBytes)
	}
	return append(data, '\n'), nil
}

func metadata(e model.Entry) Entry {
	name, n := boundedText(e.Name, MaxMetadataRunes)
	group, g := boundedText(e.Group, MaxMetadataRunes)
	device, d := boundedText(e.SourceMachine, MaxMetadataRunes)
	return Entry{ID: e.ID, Name: name, Group: group, Device: device, CreatedAt: time.UnixMilli(e.CreatedUnixMs).UTC(), MetadataTruncated: n || g || d}
}

func boundedText(text string, limit int) (string, bool) {
	count := 0
	for index := range text {
		if count == limit {
			return text[:index], true
		}
		count++
	}
	return text, false
}

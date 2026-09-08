// Package rules implements the sync-rules document model and routing engine
// described in sync-rules-spec.md sections 3-4: channel key derivation,
// document validation, per-entry routing, device subscriptions, and
// whole-document last-writer-wins merge.
package rules

import (
	"encoding/json"
	"fmt"
	"regexp"
	"strings"

	"github.com/OnjLouis/Clipman/ClipmanLinuxBackend/internal/model"
)

// documentKind is the required value of Document.Clipman.
const documentKind = "sync-rules"

// richTextImagesKind is the only currently supported Route.Kind value.
const richTextImagesKind = "RichTextImages"

// channelKeyPattern implements the grammar from spec section 3:
// [a-z0-9]([a-z0-9 _-]{0,30}[a-z0-9])?  (ASCII only, 1-32 chars).
var channelKeyPattern = regexp.MustCompile(`^[a-z0-9]([a-z0-9 _-]{0,30}[a-z0-9])?$`)

// reservedChannelKeys are channel names rejected by Validate.
var reservedChannelKeys = map[string]bool{
	"core":       true,
	"all":        true,
	"pinned":     true,
	"sync-rules": true,
}

// Document is the sync-rules document: channels, their routes, and device
// subscriptions. It is stored in its own bucket/file, never inside the
// history database. Field order is fixed here and drives Serialize's output.
type Document struct {
	Clipman       string    `json:"Clipman"`
	Version       int       `json:"Version"`
	Enabled       bool      `json:"Enabled"`
	UpdatedUnixMs int64     `json:"UpdatedUnixMs"`
	UpdatedBy     string    `json:"UpdatedBy"`
	Channels      []Channel `json:"Channels"`
	Devices       []Device  `json:"Devices"`
}

// Channel is one named partition of history with the route that fills it.
type Channel struct {
	Name  string `json:"Name"`
	Route Route  `json:"Route"`
}

// Route is the set of conditions, ANDed together, that route an entry into
// its channel. A valid route has at least one condition set.
type Route struct {
	Groups        []string `json:"Groups,omitempty"`
	SourceDevices []string `json:"SourceDevices,omitempty"`
	Kind          string   `json:"Kind,omitempty"`
}

// Device lists the channels one named device subscribes to.
type Device struct {
	Name     string   `json:"Name"`
	Channels []string `json:"Channels"`
}

// normalize applies the lowerInvariant(trim(x)) comparison rule used
// throughout spec section 3 for device names, groups, and channel keys.
func normalize(s string) string {
	return strings.ToLower(strings.TrimSpace(s))
}

// isASCII reports whether s contains only ASCII bytes.
func isASCII(s string) bool {
	for i := 0; i < len(s); i++ {
		if s[i] > 0x7F {
			return false
		}
	}
	return true
}

// ChannelKey normalizes a channel display name into its key: lowerInvariant
// of the trimmed name, provided the result matches the channel-key grammar
// and is pure ASCII. Names that fail either check yield "".
func ChannelKey(name string) string {
	key := normalize(name)
	if key == "" || !isASCII(key) || !channelKeyPattern.MatchString(key) {
		return ""
	}
	return key
}

// ChannelStorageName folds a channel key into the form it takes in
// shared-folder file names, where spaces become dashes (spec section 2).
// Two distinct keys can fold to the same storage name - "my work" and
// "my-work" - and would then share one file, so ValidateForEdit rejects
// that at edit time.
func ChannelStorageName(key string) string {
	return strings.ReplaceAll(key, " ", "-")
}

// ReadOnly reports whether doc is a future-version document that this
// client must not rewrite (spec section 4): it applies what it understands
// but never PUTs its own interpretation back.
func ReadOnly(doc *Document) bool {
	return doc != nil && doc.Version > 1
}

// Validate checks doc against the rules in spec section 4: the document
// marker, channel key grammar and uniqueness, reserved names, route
// well-formedness, and device channel references.
func Validate(doc *Document) error {
	if doc == nil {
		return fmt.Errorf("rules: document is nil")
	}
	if doc.Clipman != documentKind {
		return fmt.Errorf("rules: Clipman field must be %q, got %q", documentKind, doc.Clipman)
	}

	keys := make(map[string]bool, len(doc.Channels))
	for _, channel := range doc.Channels {
		key := ChannelKey(channel.Name)
		if key == "" {
			return fmt.Errorf("rules: channel name %q is not a valid channel key", channel.Name)
		}
		if reservedChannelKeys[key] {
			return fmt.Errorf("rules: channel name %q is reserved", channel.Name)
		}
		if keys[key] {
			return fmt.Errorf("rules: duplicate channel key %q", key)
		}
		keys[key] = true

		if len(channel.Route.Groups) == 0 && len(channel.Route.SourceDevices) == 0 && channel.Route.Kind == "" {
			return fmt.Errorf("rules: channel %q has a route with no conditions", channel.Name)
		}
		if channel.Route.Kind != "" && channel.Route.Kind != richTextImagesKind {
			return fmt.Errorf("rules: channel %q has unsupported route kind %q", channel.Name, channel.Route.Kind)
		}
	}

	for _, device := range doc.Devices {
		hasWildcard := false
		for _, channelRef := range device.Channels {
			if channelRef == "*" {
				hasWildcard = true
				break
			}
		}
		if hasWildcard && len(device.Channels) != 1 {
			return fmt.Errorf("rules: device %q mixes \"*\" with named channels in Channels", device.Name)
		}
		for _, channelRef := range device.Channels {
			if channelRef == "*" {
				continue
			}
			if !keys[normalize(channelRef)] {
				return fmt.Errorf("rules: device %q references unknown channel %q", device.Name, channelRef)
			}
		}
	}

	return nil
}

// ValidateForEdit checks everything Validate checks plus the edit-time-only
// rules of spec section 3: two distinct channel keys must not fold to the
// same shared-folder storage name. Editors call this before writing a
// document; the read path (Parse) deliberately does not, so a document
// another client already saved with such a collision keeps loading and
// routing rather than degrading this client to disabled rules.
func ValidateForEdit(doc *Document) error {
	if err := Validate(doc); err != nil {
		return err
	}
	storageNames := make(map[string]string, len(doc.Channels))
	for _, channel := range doc.Channels {
		key := ChannelKey(channel.Name)
		folded := ChannelStorageName(key)
		if other, ok := storageNames[folded]; ok {
			return fmt.Errorf("rules: channel %q would share a storage file with channel %q: spaces and dashes are interchangeable in channel file names", channel.Name, other)
		}
		storageNames[folded] = channel.Name
	}
	return nil
}

// richTextPayload decodes only the field RouteEntry needs from an entry's
// Extra["RichText"] value; see internal/model's Entry.Extra and
// internal/merge's treatment of the same key.
type richTextPayload struct {
	HtmlFragment string `json:"HtmlFragment"`
}

// entryHasEmbeddedImage reports whether e carries rich text whose HTML
// fragment contains the ordinal substring "data:image/".
func entryHasEmbeddedImage(e *model.Entry) bool {
	if e == nil || e.Extra == nil {
		return false
	}
	raw, ok := e.Extra["RichText"]
	if !ok || string(raw) == "null" {
		return false
	}
	var payload richTextPayload
	if err := json.Unmarshal(raw, &payload); err != nil {
		return false
	}
	return strings.Contains(payload.HtmlFragment, "data:image/")
}

// routeMatches reports whether every condition set on route matches e. A
// route with no conditions set never matches (Validate rejects such routes,
// but RouteEntry must still be safe against an unvalidated document).
func routeMatches(route Route, e *model.Entry) bool {
	matchedAny := false

	if len(route.Groups) > 0 {
		if !containsNormalized(route.Groups, e.Group) {
			return false
		}
		matchedAny = true
	}
	if len(route.SourceDevices) > 0 {
		if !containsNormalized(route.SourceDevices, e.SourceMachine) {
			return false
		}
		matchedAny = true
	}
	if route.Kind != "" {
		if route.Kind != richTextImagesKind || !entryHasEmbeddedImage(e) {
			return false
		}
		matchedAny = true
	}

	return matchedAny
}

func containsNormalized(list []string, target string) bool {
	normalizedTarget := normalize(target)
	for _, item := range list {
		if normalize(item) == normalizedTarget {
			return true
		}
	}
	return false
}

// RouteEntry returns the key of the first channel (in document order) whose
// route matches e, or "" when doc is nil, disabled, or no route matches
// (meaning the entry lives in core).
func RouteEntry(doc *Document, e *model.Entry) string {
	if doc == nil || !doc.Enabled || e == nil {
		return ""
	}
	for _, channel := range doc.Channels {
		if routeMatches(channel.Route, e) {
			return ChannelKey(channel.Name)
		}
	}
	return ""
}

// SubscribedChannels returns the channel keys deviceName downloads, not
// including core (core is implicit and always synced). It returns nil when
// doc is nil, disabled, or deviceName is not listed in doc.Devices - nil
// means "subscribe to everything" per spec section 4.
func SubscribedChannels(doc *Document, deviceName string) []string {
	if doc == nil || !doc.Enabled {
		return nil
	}

	normalizedName := normalize(deviceName)
	var device *Device
	for i := range doc.Devices {
		if normalize(doc.Devices[i].Name) == normalizedName {
			device = &doc.Devices[i]
			break
		}
	}
	if device == nil {
		return nil
	}

	for _, channelRef := range device.Channels {
		if channelRef == "*" {
			all := make([]string, 0, len(doc.Channels))
			for _, channel := range doc.Channels {
				all = append(all, ChannelKey(channel.Name))
			}
			return all
		}
	}

	known := make(map[string]bool, len(doc.Channels))
	for _, channel := range doc.Channels {
		known[ChannelKey(channel.Name)] = true
	}
	subscribed := make([]string, 0, len(device.Channels))
	for _, channelRef := range device.Channels {
		key := normalize(channelRef)
		if known[key] {
			subscribed = append(subscribed, key)
		}
	}
	return subscribed
}

// MergeDocuments merges two possibly-nil documents by whole-document
// last-writer-wins on UpdatedUnixMs, breaking ties toward the greater
// UpdatedBy string by ordinal comparison. A nil document loses to a non-nil
// one; if both are nil the result is nil.
func MergeDocuments(local, remote *Document) *Document {
	if local == nil {
		return remote
	}
	if remote == nil {
		return local
	}
	if remote.UpdatedUnixMs > local.UpdatedUnixMs {
		return remote
	}
	if remote.UpdatedUnixMs < local.UpdatedUnixMs {
		return local
	}
	if remote.UpdatedBy > local.UpdatedBy {
		return remote
	}
	return local
}

// Parse decodes a rules document, rejecting any payload whose Clipman field
// is not "sync-rules". A document whose Version is greater than this client
// understands (see ReadOnly) is not run through Validate: spec section 4
// requires such a document to be applied leniently rather than rejected
// outright, since a client must never fail entirely on a future document.
// Channels whose name yields an invalid key are kept in the returned
// document but are unroutable (RouteEntry and friends treat them as
// non-matching). Documents at Version <= 1 keep full strict validation,
// since editors validate before writing them.
func Parse(data []byte) (*Document, error) {
	var doc Document
	if err := json.Unmarshal(data, &doc); err != nil {
		return nil, err
	}
	if ReadOnly(&doc) {
		if doc.Clipman != documentKind {
			return nil, fmt.Errorf("rules: Clipman field must be %q, got %q", documentKind, doc.Clipman)
		}
		return &doc, nil
	}
	if err := Validate(&doc); err != nil {
		return nil, err
	}
	return &doc, nil
}

// Serialize encodes doc as JSON with field order fixed by Document's
// struct definition.
func Serialize(doc *Document) ([]byte, error) {
	return json.Marshal(doc)
}

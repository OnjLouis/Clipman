package agent

import (
	"encoding/json"
	"testing"

	"github.com/OnjLouis/Clipman/ClipmanCli/internal/model"
)

func TestEligibleRichTextField(t *testing.T) {
	for _, tc := range []struct {
		name  string
		value string
		want  bool
	}{
		{"absent", "", true},
		{"null", "null", true},
		{"whitespace null", " \nnull\t", true},
		{"payload", `{"HtmlFragment":"<b>private</b>"}`, false},
		{"empty object", `{}`, false},
		{"string null", `"null"`, false},
		{"boolean", `false`, false},
		{"malformed", `null junk`, false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			entry := model.Entry{ID: "plain", Text: "ordinary text"}
			if tc.value != "" {
				entry.Extra = map[string]json.RawMessage{"RichText": json.RawMessage(tc.value)}
			}
			if got := Eligible(entry); got != tc.want {
				t.Fatalf("Eligible = %v, want %v", got, tc.want)
			}
			entry.IsTemplate = true
			if Eligible(entry) {
				t.Fatal("template included")
			}
		})
	}
	if Eligible(model.Entry{ID: "invalid", Extra: map[string]json.RawMessage{"RichText": nil}}) {
		t.Fatal("empty rich-text field included")
	}
}

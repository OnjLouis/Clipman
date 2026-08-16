package identity_test

import (
	"testing"

	"github.com/OnjLouis/Clipman/ClipmanCli/internal/fixture"
	"github.com/OnjLouis/Clipman/ClipmanCli/internal/identity"
)

// TestIdentityMatchesEveryClient checks the bucket derivation against vectors
// produced by each client's own implementation. A disagreement here means two
// devices with the same token and history password would look in different
// buckets and silently fail to share history.
func TestIdentityMatchesEveryClient(t *testing.T) {
	manifests, err := fixture.All()
	if err != nil {
		t.Fatalf("loading the fixture corpus: %v", err)
	}
	if len(manifests) == 0 {
		t.Skip("no interoperability fixtures are present; see testdata/fixtures/README.md")
	}
	for _, manifest := range manifests {
		for _, vector := range manifest.Identity {
			name := manifest.Generator + "/" + vector.Name
			t.Run(name, func(t *testing.T) {
				got := identity.DatabaseID(vector.Token, vector.Password)
				if got != vector.DatabaseID {
					t.Fatalf("bucket mismatch\n token    %q\n password %q\n want     %q\n got      %q",
						vector.Token, vector.Password, vector.DatabaseID, got)
				}
			})
		}
	}
}

// TestIdentityCorpusCoversTheAwkwardCases guards the corpus itself. A vector
// file that quietly lost its Unicode or whitespace cases would still pass
// every comparison above while testing nothing interesting.
func TestIdentityCorpusCoversTheAwkwardCases(t *testing.T) {
	manifest, err := fixture.Load("windows")
	if err != nil {
		t.Skipf("windows fixtures are not present: %v", err)
	}
	required := []string{
		"unicode-password", "unicode-token", "token-needs-trimming",
		"empty-password-has-no-bucket", "empty-token-has-no-bucket",
	}
	present := map[string]bool{}
	for _, vector := range manifest.Identity {
		present[vector.Name] = true
	}
	for _, name := range required {
		if !present[name] {
			t.Errorf("the corpus no longer covers %q", name)
		}
	}
}

// TestTrimmedTokenSelectsTheSameBucket states the consequence of token
// canonicalization directly, rather than leaving it implicit in two vectors
// that happen to share an expected value.
func TestTrimmedTokenSelectsTheSameBucket(t *testing.T) {
	manifest, err := fixture.Load("windows")
	if err != nil {
		t.Skipf("windows fixtures are not present: %v", err)
	}
	var padded, plain string
	for _, vector := range manifest.Identity {
		switch vector.Name {
		case "token-needs-trimming":
			padded = vector.DatabaseID
		case "ascii":
			plain = vector.DatabaseID
		}
	}
	if padded == "" || plain == "" {
		t.Skip("the corpus does not carry both trimming vectors")
	}
	if padded != plain {
		t.Fatalf("a token with surrounding whitespace must select the same bucket: %q vs %q", padded, plain)
	}
}

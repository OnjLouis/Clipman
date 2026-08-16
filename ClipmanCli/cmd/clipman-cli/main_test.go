package main

import (
	"context"
	"crypto/rand"
	"crypto/rsa"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"errors"
	"flag"
	"fmt"
	"github.com/OnjLouis/Clipman/ClipmanCli/internal/clipdb"
	"github.com/OnjLouis/Clipman/ClipmanCli/internal/model"
	"github.com/OnjLouis/Clipman/ClipmanCli/internal/server"
	"io"
	"math/big"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/OnjLouis/Clipman/ClipmanCli/internal/config"
	"github.com/OnjLouis/Clipman/ClipmanCli/internal/operation"
)

func testServerWithCertificateChain(t *testing.T) (*httptest.Server, *x509.Certificate, *x509.Certificate) {
	t.Helper()
	now := time.Now()
	caKey, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		t.Fatal(err)
	}
	caTemplate := &x509.Certificate{
		SerialNumber:          big.NewInt(1),
		Subject:               pkix.Name{CommonName: "Clipman Test Authority"},
		NotBefore:             now.Add(-time.Hour),
		NotAfter:              now.Add(time.Hour),
		IsCA:                  true,
		BasicConstraintsValid: true,
		KeyUsage:              x509.KeyUsageCertSign | x509.KeyUsageDigitalSignature,
	}
	caDER, err := x509.CreateCertificate(rand.Reader, caTemplate, caTemplate, &caKey.PublicKey, caKey)
	if err != nil {
		t.Fatal(err)
	}
	ca, err := x509.ParseCertificate(caDER)
	if err != nil {
		t.Fatal(err)
	}

	leafKey, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		t.Fatal(err)
	}
	leafTemplate := &x509.Certificate{
		SerialNumber: big.NewInt(2),
		Subject:      pkix.Name{CommonName: "127.0.0.1"},
		NotBefore:    now.Add(-time.Hour),
		NotAfter:     now.Add(time.Hour),
		IPAddresses:  []net.IP{net.ParseIP("127.0.0.1")},
		ExtKeyUsage:  []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth},
		KeyUsage:     x509.KeyUsageDigitalSignature,
	}
	leafDER, err := x509.CreateCertificate(rand.Reader, leafTemplate, ca, &leafKey.PublicKey, caKey)
	if err != nil {
		t.Fatal(err)
	}
	leaf, err := x509.ParseCertificate(leafDER)
	if err != nil {
		t.Fatal(err)
	}

	server := httptest.NewUnstartedServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusOK)
	}))
	server.TLS = &tls.Config{Certificates: []tls.Certificate{{Certificate: [][]byte{leafDER, caDER}, PrivateKey: leafKey}}, MinVersion: tls.VersionTLS12}
	server.StartTLS()
	t.Cleanup(server.Close)
	return server, leaf, ca
}

func TestGlobalParsingStopsAtCommand(t *testing.T) {
	g, remaining, err := parseGlobals([]string{"--server", "clipman://host:60000", "put", "--text", "--json"})
	if err != nil {
		t.Fatal(err)
	}
	if g.server != "clipman://host:60000" {
		t.Fatalf("server = %q", g.server)
	}
	if len(remaining) != 3 || remaining[0] != "put" || remaining[1] != "--text" || remaining[2] != "--json" {
		t.Fatalf("remaining = %#v", remaining)
	}
}

func TestSourceVersionMatchesVersionFile(t *testing.T) {
	data, err := os.ReadFile(filepath.Join("..", "..", "VERSION"))
	if err != nil {
		t.Fatal(err)
	}
	if want := strings.TrimSpace(string(data)); version != want {
		t.Fatalf("source version = %q, VERSION = %q", version, want)
	}
}

func TestCommandHelpDoesNotStealOptionValues(t *testing.T) {
	if hasHelpOption([]string{"--text", "--help"}) {
		t.Fatal("--help used as an option value must not trigger command help")
	}
	if !hasHelpOption([]string{"--help"}) {
		t.Fatal("leading --help should trigger command help")
	}
}

func TestUnknownGlobalOptionFails(t *testing.T) {
	if _, _, err := parseGlobals([]string{"--unknown", "list"}); err == nil {
		t.Fatal("expected unknown global option error")
	}
}

func TestHelpAndUnknownCommandDoNotNeedConfiguration(t *testing.T) {
	if code := run([]string{"help"}); code != 0 {
		t.Fatalf("help exit code = %d", code)
	}
	if code := run([]string{"help", "get"}); code != 0 {
		t.Fatalf("help get exit code = %d", code)
	}
	if code := run([]string{"not-a-command"}); code != 2 {
		t.Fatalf("unknown command exit code = %d", code)
	}
}

func TestResolvePasswordRequiresNonblankValue(t *testing.T) {
	if _, err := resolvePassword(globals{password: optionalString{set: true}}, config.Default(), false); err == nil || !strings.Contains(err.Error(), "nonblank history password") {
		t.Fatalf("blank history password error = %v", err)
	}
	password, err := resolvePassword(globals{password: optionalString{set: true, value: "test-password"}}, config.Default(), false)
	if err != nil || password != "test-password" {
		t.Fatalf("nonblank history password = %q, %v", password, err)
	}
}

// captureStdout runs body with standard output redirected and returns what it
// wrote, so usage tests do not pollute the test log.
func captureStdout(t *testing.T, body func()) string {
	t.Helper()
	read, write, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	saved := os.Stdout
	os.Stdout = write
	done := make(chan string, 1)
	go func() {
		data, _ := io.ReadAll(read)
		done <- string(data)
	}()
	body()
	os.Stdout = saved
	write.Close()
	output := <-done
	read.Close()
	return output
}

// selectorFlags mirrors the option shapes that get and rm register: a mix of
// options that take a value and options that do not.
func selectorFlags() *flag.FlagSet {
	fs := newFlagSet("get")
	fs.String("id", "", "exact entry ID")
	fs.String("kind", "history", "history, templates, or all")
	fs.Bool("json", false, "write JSON output")
	fs.Bool("touch", false, "mark the entry used")
	return fs
}

func TestPermuteArgsAllowsOptionsAfterTheIndex(t *testing.T) {
	cases := []struct {
		name string
		args []string
		want []string
	}{
		{"index then boolean option", []string{"0", "--json"}, []string{"--json", "--", "0"}},
		{"index then option with a value", []string{"0", "--kind", "all"}, []string{"--kind", "all", "--", "0"}},
		{"index between options", []string{"--touch", "3", "--json"}, []string{"--touch", "--json", "--", "3"}},
		{"already in flag order", []string{"--json", "0"}, []string{"--json", "--", "0"}},
		{"joined option value", []string{"0", "--kind=all"}, []string{"--kind=all", "--", "0"}},
		{"no operands", []string{"--id", "abc", "--json"}, []string{"--id", "abc", "--json"}},
		{"explicit separator is preserved", []string{"--json", "--", "0"}, []string{"--json", "--", "0"}},
	}
	for _, testCase := range cases {
		t.Run(testCase.name, func(t *testing.T) {
			got := permuteArgs(selectorFlags(), testCase.args)
			if strings.Join(got, " ") != strings.Join(testCase.want, " ") {
				t.Fatalf("permuteArgs(%q) = %q, want %q", testCase.args, got, testCase.want)
			}
		})
	}
}

// permuteArgs must not swallow the value of an option, which would turn
// `--id 0` into a selector with an empty ID and a stray index.
func TestPermuteArgsKeepsOptionValuesAttached(t *testing.T) {
	got := permuteArgs(selectorFlags(), []string{"--id", "0"})
	if strings.Join(got, " ") != "--id 0" {
		t.Fatalf("permuteArgs = %q, want %q", got, "--id 0")
	}
}

// An undefined option keeps reaching Parse so that it is still reported as a
// usage error rather than silently treated as an index.
func TestPermuteArgsLeavesUndefinedOptionsForParse(t *testing.T) {
	got := permuteArgs(selectorFlags(), []string{"--nope"})
	if strings.Join(got, " ") != "--nope" {
		t.Fatalf("permuteArgs = %q, want %q", got, "--nope")
	}
}

func TestParseGetAcceptsOptionsAfterTheIndex(t *testing.T) {
	var g globals
	selector, kind, _, touch, _, _, err := parseGet([]string{"0", "--json", "--touch", "--kind", "all"}, config.Default(), &g)
	if err != nil {
		t.Fatalf("parseGet returned %v", err)
	}
	if selector.Index == nil || *selector.Index != 0 {
		t.Fatalf("selector index = %v, want 0", selector.Index)
	}
	if kind != operation.All {
		t.Fatalf("kind = %q, want %q", kind, operation.All)
	}
	if !touch {
		t.Fatal("--touch after the index was not applied")
	}
	if !g.json {
		t.Fatal("--json after the index was not applied")
	}
}

func TestBuildSelectorRejectsNegativeIndex(t *testing.T) {
	_, err := buildSelector([]string{"-1"}, "", "", "", false, false)
	if err == nil || !strings.Contains(err.Error(), "non-negative") {
		t.Fatalf("negative index error = %v", err)
	}
	var app appError
	if !errors.As(err, &app) || app.code != 2 {
		t.Fatalf("negative index exit code = %v, want 2", err)
	}
}

func TestBuildSelectorRejectsCombinedSelectors(t *testing.T) {
	if _, err := buildSelector([]string{"0"}, "some-id", "", "", false, false); err == nil {
		t.Fatal("index combined with --id should fail")
	}
	if _, err := buildSelector([]string{"0", "1"}, "", "", "", false, false); err == nil {
		t.Fatal("two indexes should fail")
	}
}

func TestCommandHelpWorksAfterOtherOptions(t *testing.T) {
	fs := selectorFlags()
	var err error
	output := captureStdout(t, func() {
		err = parseCommandFlags(fs, "get", []string{"--json", "--help"})
	})
	if !errors.Is(err, errHelpRequested) {
		t.Fatalf("parseCommandFlags returned %v, want errHelpRequested", err)
	}
	if !strings.Contains(output, "Usage: clipman-cli") {
		t.Fatalf("help output = %q", output)
	}
	if printError(err) != 0 {
		t.Fatal("requesting help must exit 0")
	}
}

func TestEveryKnownCommandHasUsageText(t *testing.T) {
	for _, command := range []string{"init", "status", "list", "get", "put", "rm", "sync", "pick", "menu", "help"} {
		if !printCommandUsage(io.Discard, command) {
			t.Fatalf("command %q has no usage text", command)
		}
	}
	if printCommandUsage(io.Discard, "not-a-command") {
		t.Fatal("unknown command reported usage text")
	}
}

func captureStderr(t *testing.T, body func()) string {
	t.Helper()
	read, write, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	saved := os.Stderr
	os.Stderr = write
	done := make(chan string, 1)
	go func() {
		data, _ := io.ReadAll(read)
		done <- string(data)
	}()
	body()
	os.Stderr = saved
	write.Close()
	output := <-done
	read.Close()
	return output
}

func TestVerboseDiagnosticsRequireTheOption(t *testing.T) {
	quiet := captureStderr(t, func() { verbosef(globals{}, "server %s", "https://example.invalid") })
	if quiet != "" {
		t.Fatalf("diagnostics must stay off without --verbose, got %q", quiet)
	}
	suppressed := captureStderr(t, func() {
		verbosef(globals{verbose: true, quiet: true}, "server %s", "https://example.invalid")
	})
	if suppressed != "" {
		t.Fatalf("--quiet must win over --verbose, got %q", suppressed)
	}
	enabled := captureStderr(t, func() {
		verbosef(globals{verbose: true}, "server %s", "https://example.invalid")
	})
	if !strings.Contains(enabled, "server https://example.invalid") {
		t.Fatalf("verbose output = %q", enabled)
	}
}

func TestCertificateTrustPromptOnlyHandlesUnknownAuthority(t *testing.T) {
	unknown := x509.UnknownAuthorityError{}
	if !isCertificateTrustError(unknown) {
		t.Fatal("unknown authority should offer the trust prompt")
	}
	wrapped := &tls.CertificateVerificationError{Err: unknown}
	if !isCertificateTrustError(wrapped) {
		t.Fatal("wrapped unknown authority should offer the trust prompt")
	}
	if isCertificateTrustError(x509.HostnameError{}) {
		t.Fatal("hostname mismatch must not offer a trust prompt")
	}
	if isCertificateTrustError(x509.CertificateInvalidError{}) {
		t.Fatal("expired or otherwise invalid certificate must not offer a trust prompt")
	}
}

func TestFetchServerCertificatesUsesAuthorityFingerprint(t *testing.T) {
	server, wantLeaf, wantAuthority := testServerWithCertificateChain(t)
	leaf, authority, err := fetchServerCertificates(context.Background(), server.URL)
	if err != nil {
		t.Fatal(err)
	}
	if !leaf.Equal(wantLeaf) {
		t.Fatalf("leaf certificate = %q, want %q", leaf.Subject, wantLeaf.Subject)
	}
	if !authority.Equal(wantAuthority) {
		t.Fatalf("authority certificate = %q, want %q", authority.Subject, wantAuthority.Subject)
	}
	if certificateFingerprintSHA256(authority) == certificateFingerprintSHA256(leaf) {
		t.Fatal("authority and leaf fingerprints unexpectedly match")
	}
}

// TestWhereToSaveIsNotAskedWhenTheLocationIsSettled covers the cases where init
// must stay quiet. Asking after the user has already named a location invites
// them to contradict themselves, and a non-interactive run has nobody to ask.
func TestWhereToSaveIsNotAskedWhenTheLocationIsSettled(t *testing.T) {
	t.Setenv("CLIPMAN_CONFIG", "")
	t.Setenv("CLIPMAN_HOME", "")
	os.Unsetenv("CLIPMAN_CONFIG")
	os.Unsetenv("CLIPMAN_HOME")

	if shouldAskWhereToSave(globals{}, true) {
		t.Error("a non-interactive run must not ask")
	}
	if shouldAskWhereToSave(globals{configPath: "some.toml"}, false) {
		t.Error("--config already names the location, so init must not ask")
	}

	t.Setenv("CLIPMAN_CONFIG", "from-environment.toml")
	if shouldAskWhereToSave(globals{}, false) {
		t.Error("CLIPMAN_CONFIG already names the location, so init must not ask")
	}
	os.Unsetenv("CLIPMAN_CONFIG")

	t.Setenv("CLIPMAN_HOME", "somewhere")
	if shouldAskWhereToSave(globals{}, false) {
		t.Error("CLIPMAN_HOME already names the location, so init must not ask")
	}
}

// TestInitHelpMentionsWhereSettingsGo keeps the built-in help honest about the
// choice, since the question only appears on an interactive run.
func TestInitHelpMentionsWhereSettingsGo(t *testing.T) {
	var out strings.Builder
	if !printCommandUsage(&out, "init") {
		t.Fatal("init has no usage text")
	}
	if !strings.Contains(out.String(), "--portable") {
		t.Fatalf("init help does not mention --portable:\n%s", out.String())
	}
}

// TestHandingOverAvoidsASilentDownload is the guard for the gap in a switch.
// The screen is torn down before the new interface draws anything, and a
// download plus a PBKDF2 decrypt in that gap is silence with nothing to explain
// it. The store therefore hands the already-loaded database to the interface
// being started.
//
// ctx is deliberately nil: reaching the network path would dereference it, so
// this test fails loudly rather than passing while quietly downloading.
func TestHandingOverAvoidsASilentDownload(t *testing.T) {
	database := model.NewDatabase(1)
	database.Entries = []model.Entry{{ID: "a", Text: "carried across the switch"}}

	store := &cliStore{kind: operation.History}
	store.last = &database
	store.handOver()

	entries, err := store.Load(context.Background())
	if err != nil {
		t.Fatalf("a handed-over load must not fail: %v", err)
	}
	if len(entries) != 1 || entries[0].ID != "a" {
		t.Fatalf("the handed-over database must be what is shown, got %#v", entries)
	}
	// One shot only, so an explicit reload still asks the server rather than
	// replaying what the user already had.
	if store.reuse != nil {
		t.Fatal("the handover must be consumed once, or r would stop reloading")
	}
}

// TestHandingOverRebuildsTheViewForTheNewKind covers Tab. The full-screen
// interface can change the kind and the line interface cannot, so the view has
// to be re-derived on arrival rather than replayed wholesale.
func TestHandingOverRebuildsTheViewForTheNewKind(t *testing.T) {
	database := model.NewDatabase(1)
	database.Entries = []model.Entry{
		{ID: "plain", Text: "an ordinary clip"},
		{ID: "tmpl", Text: "a template", IsTemplate: true},
	}

	store := &cliStore{kind: operation.History}
	store.last = &database
	store.SetKind(operation.Templates)
	store.handOver()

	entries, err := store.Load(context.Background())
	if err != nil {
		t.Fatalf("Load: %v", err)
	}
	if len(entries) != 1 || entries[0].ID != "tmpl" {
		t.Fatalf("the handed-over view must be rebuilt for the kind now in force, got %#v", entries)
	}
}

// TestRuntimeErrorsGetTheRightExitCode pins section 7.2. The fallthrough used to
// be 4, so a local encode or decode failure that surfaced through a call which
// also touches the network reported itself as a network failure — telling a
// script to retry something retrying cannot fix, and telling a user the network
// was at fault when it was not.
func TestRuntimeErrorsGetTheRightExitCode(t *testing.T) {
	for _, item := range []struct {
		name string
		err  error
		want int
	}{
		{"local decode failure", errors.New("trailing garbage after JSON value"), 1},
		{"unauthorized", server.ErrUnauthorized, 3},
		{"not found", server.ErrNotFound, 6},
		{"password required", clipdb.ErrPasswordRequired, 5},
		{"password or data", clipdb.ErrPasswordOrData, 5},
		{"timeout", &net.DNSError{Err: "timed out", IsTimeout: true}, 4},
		{"connection refused", &net.OpError{Op: "dial", Err: errors.New("connection refused")}, 4},
		{"server error", &server.StatusError{StatusCode: 503, Body: "unavailable"}, 4},
		{"payload too large", &server.StatusError{StatusCode: 413, Body: "too big"}, 4},
		// A 4xx that is not one of the sentinels is the request's problem, not
		// the network's, so it must not claim a network exit code.
		{"unexpected client status", &server.StatusError{StatusCode: 418, Body: "teapot"}, 1},
	} {
		t.Run(item.name, func(t *testing.T) {
			var app appError
			err := mapRuntimeError("operation failed", item.err)
			if !errors.As(err, &app) {
				t.Fatalf("mapRuntimeError must return an appError, got %T", err)
			}
			if app.code != item.want {
				t.Errorf("exit code = %d, want %d, for %v", app.code, item.want, item.err)
			}
		})
	}
}

// TestWrappedRuntimeErrorsAreStillClassified checks the classification survives
// wrapping, which is how these errors actually arrive from the sync engine.
func TestWrappedRuntimeErrorsAreStillClassified(t *testing.T) {
	wrapped := fmt.Errorf("upload failed: %w", &server.StatusError{StatusCode: 500, Body: "boom"})
	var app appError
	if err := mapRuntimeError("sync", wrapped); !errors.As(err, &app) || app.code != 4 {
		t.Fatalf("a wrapped server fault must still be 4, got %v", err)
	}
	wrappedLocal := fmt.Errorf("merge failed: %w", errors.New("duplicate entry id"))
	if err := mapRuntimeError("sync", wrappedLocal); !errors.As(err, &app) || app.code != 1 {
		t.Fatalf("a wrapped local failure must be 1, got %v", err)
	}
}

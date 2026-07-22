package main

import "testing"

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

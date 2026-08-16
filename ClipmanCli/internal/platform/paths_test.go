package platform

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// clearConfigEnvironment removes the variables that would otherwise decide the
// answer, so each test exercises the step it means to.
func clearConfigEnvironment(t *testing.T) {
	t.Helper()
	t.Setenv("CLIPMAN_CONFIG", "")
	t.Setenv("CLIPMAN_HOME", "")
	os.Unsetenv("CLIPMAN_CONFIG")
	os.Unsetenv("CLIPMAN_HOME")
}

func TestExplicitPathWinsOverEverything(t *testing.T) {
	clearConfigEnvironment(t)
	t.Setenv("CLIPMAN_CONFIG", filepath.Join(t.TempDir(), "ignored.toml"))
	t.Setenv("CLIPMAN_HOME", t.TempDir())
	explicit := filepath.Join(t.TempDir(), "chosen.toml")
	got, err := ConfigPath(explicit)
	if err != nil {
		t.Fatalf("ConfigPath: %v", err)
	}
	if got != explicit {
		t.Fatalf("got %q, want %q", got, explicit)
	}
}

func TestConfigEnvironmentBeatsHome(t *testing.T) {
	clearConfigEnvironment(t)
	want := filepath.Join(t.TempDir(), "named.toml")
	t.Setenv("CLIPMAN_CONFIG", want)
	t.Setenv("CLIPMAN_HOME", t.TempDir())
	got, err := ConfigPath("")
	if err != nil {
		t.Fatalf("ConfigPath: %v", err)
	}
	if got != want {
		t.Fatalf("got %q, want %q", got, want)
	}
}

func TestHomeSuppliesTheStandardFilename(t *testing.T) {
	clearConfigEnvironment(t)
	home := t.TempDir()
	t.Setenv("CLIPMAN_HOME", home)
	got, err := ConfigPath("")
	if err != nil {
		t.Fatalf("ConfigPath: %v", err)
	}
	if want := filepath.Join(home, ConfigFileName); got != want {
		t.Fatalf("got %q, want %q", got, want)
	}
}

// TestPortableConfigIsUsedWhenPresent is the behavior this exists for: a
// config.toml beside the executable belongs to that copy of the program.
func TestPortableConfigIsUsedWhenPresent(t *testing.T) {
	clearConfigEnvironment(t)
	portable, err := PortableConfigPath()
	if err != nil {
		t.Skipf("the executable path is unavailable here: %v", err)
	}
	if _, err := os.Stat(portable); err == nil {
		t.Skip("a real portable config already sits beside the test binary")
	}
	if err := os.WriteFile(portable, []byte("server = \"clipman://example:52731\"\n"), 0o600); err != nil {
		t.Skipf("cannot write beside the test binary: %v", err)
	}
	t.Cleanup(func() { os.Remove(portable) })

	got, err := ConfigPath("")
	if err != nil {
		t.Fatalf("ConfigPath: %v", err)
	}
	if got != portable {
		t.Fatalf("got %q, want the portable config %q", got, portable)
	}
}

// TestPortableConfigIsIgnoredWhenAbsent keeps the ordinary installation on the
// per-user profile. The portable file is adopted only once it exists.
func TestPortableConfigIsIgnoredWhenAbsent(t *testing.T) {
	clearConfigEnvironment(t)
	portable, err := PortableConfigPath()
	if err != nil {
		t.Skipf("the executable path is unavailable here: %v", err)
	}
	if _, err := os.Stat(portable); err == nil {
		t.Skip("a real portable config sits beside the test binary")
	}
	got, err := ConfigPath("")
	if err != nil {
		t.Fatalf("ConfigPath: %v", err)
	}
	if got == portable {
		t.Fatal("an absent portable config must not be chosen")
	}
	if !strings.HasSuffix(got, ConfigFileName) {
		t.Fatalf("the fallback should still name the standard file, got %q", got)
	}
}

// TestExplicitAndEnvironmentBeatThePortableConfig checks the portable file
// does not quietly override a profile the user named.
func TestExplicitAndEnvironmentBeatThePortableConfig(t *testing.T) {
	clearConfigEnvironment(t)
	portable, err := PortableConfigPath()
	if err != nil {
		t.Skipf("the executable path is unavailable here: %v", err)
	}
	if _, err := os.Stat(portable); err == nil {
		t.Skip("a real portable config already sits beside the test binary")
	}
	if err := os.WriteFile(portable, []byte("server = \"clipman://example:52731\"\n"), 0o600); err != nil {
		t.Skipf("cannot write beside the test binary: %v", err)
	}
	t.Cleanup(func() { os.Remove(portable) })

	explicit := filepath.Join(t.TempDir(), "named.toml")
	if got, err := ConfigPath(explicit); err != nil || got != explicit {
		t.Fatalf("--config should win: got %q, %v", got, err)
	}

	fromEnvironment := filepath.Join(t.TempDir(), "environment.toml")
	t.Setenv("CLIPMAN_CONFIG", fromEnvironment)
	if got, err := ConfigPath(""); err != nil || got != fromEnvironment {
		t.Fatalf("CLIPMAN_CONFIG should win: got %q, %v", got, err)
	}
	os.Unsetenv("CLIPMAN_CONFIG")

	home := t.TempDir()
	t.Setenv("CLIPMAN_HOME", home)
	if got, err := ConfigPath(""); err != nil || got != filepath.Join(home, ConfigFileName) {
		t.Fatalf("CLIPMAN_HOME should win: got %q, %v", got, err)
	}
}

// TestPortableConfigIsBesideTheBinaryNotTheWorkingDirectory states the choice
// plainly: a stray config.toml in some unrelated folder must never take over a
// session, because the file names a server and carries a token.
func TestPortableConfigIsBesideTheBinaryNotTheWorkingDirectory(t *testing.T) {
	clearConfigEnvironment(t)
	portable, err := PortableConfigPath()
	if err != nil {
		t.Skipf("the executable path is unavailable here: %v", err)
	}
	executable, err := os.Executable()
	if err != nil {
		t.Skipf("the executable path is unavailable here: %v", err)
	}
	if resolved, err := filepath.EvalSymlinks(executable); err == nil {
		executable = resolved
	}
	if filepath.Dir(portable) != filepath.Dir(executable) {
		t.Fatalf("portable config %q is not beside the executable %q", portable, executable)
	}

	// A config.toml in the working directory must be ignored.
	working := t.TempDir()
	if err := os.WriteFile(filepath.Join(working, ConfigFileName), []byte("server = \"clipman://decoy:52731\"\n"), 0o600); err != nil {
		t.Fatalf("writing the decoy: %v", err)
	}
	t.Chdir(working)
	got, err := ConfigPath("")
	if err != nil {
		t.Fatalf("ConfigPath: %v", err)
	}
	if got == filepath.Join(working, ConfigFileName) {
		t.Fatal("a config.toml in the working directory must not be adopted")
	}
}

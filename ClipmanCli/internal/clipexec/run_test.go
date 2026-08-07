package clipexec

import (
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"strings"
	"testing"
	"time"
)

// TestHelperProcess is not a test. It is the program the Run tests execute,
// which is how these stay portable: no assumption that sort, head, or cat exist
// or behave the same on Windows and Unix.
func TestHelperProcess(t *testing.T) {
	if os.Getenv("CLIPEXEC_HELPER") != "1" {
		return
	}
	defer os.Exit(0)
	switch os.Getenv("CLIPEXEC_HELPER_MODE") {
	case "echo-args":
		for _, arg := range os.Args[argsAfterSeparator():] {
			fmt.Println(arg)
		}
	case "copy-stdin":
		io.Copy(os.Stdout, os.Stdin)
	case "read-one-byte":
		// Exits while the parent is still writing, which is a broken pipe on the
		// parent's side and success on this one.
		buffer := make([]byte, 1)
		os.Stdin.Read(buffer)
		os.Stdout.Write(buffer)
	case "fail":
		fmt.Fprintln(os.Stderr, "something went wrong")
		os.Exit(3)
	case "flood":
		line := strings.Repeat("x", 1024) + "\n"
		for written := 0; written < 4*OutputLimit; written += len(line) {
			os.Stdout.WriteString(line)
		}
	case "sleep":
		time.Sleep(30 * time.Second)
	case "silent":
	}
}

// argsAfterSeparator finds the arguments meant for the helper, which follow the
// "--" the test harness inserts.
func argsAfterSeparator() int {
	for index, arg := range os.Args {
		if arg == "--" {
			return index + 1
		}
	}
	return len(os.Args)
}

func helperPlan(mode string, args ...string) (Plan, []string) {
	full := append([]string{os.Args[0], "-test.run=TestHelperProcess", "--"}, args...)
	return Plan{Args: full}, []string{"CLIPEXEC_HELPER=1", "CLIPEXEC_HELPER_MODE=" + mode}
}

// runHelper executes the helper with the given mode. The environment is set on
// this process because Run deliberately does not accept an environment: a clip
// must never travel in one, since it may be a credential and the environment of
// a running process is readable on Linux.
func runHelper(t *testing.T, ctx context.Context, mode, stdin string, usesStdin bool, args ...string) (Result, error) {
	t.Helper()
	plan, env := helperPlan(mode, args...)
	plan.Stdin, plan.UsesStdin = stdin, usesStdin
	for _, pair := range env {
		key, value, _ := strings.Cut(pair, "=")
		t.Setenv(key, value)
	}
	return Run(ctx, plan)
}

// TestArgumentsArriveExactlyAsPlanned is the end-to-end form of the parser's
// promise: what Build produced is what the program receives, one argument each,
// nothing re-split by anything in between.
func TestArgumentsArriveExactlyAsPlanned(t *testing.T) {
	clip := "; rm -rf ~\nand | more"
	result, err := runHelper(t, context.Background(), "echo-args", "", false, clip, "after")
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if !result.Succeeded() {
		t.Fatalf("helper failed: %+v", result)
	}
	// The clip spans two lines, so the first two output lines are the one
	// argument and the third is the argument that followed it.
	want := clip + "\nafter\n"
	if got := strings.ReplaceAll(result.Stdout, "\r\n", "\n"); got != want {
		t.Fatalf("arguments arrived as %q, want %q", got, want)
	}
}

func TestStdinCarriesTheClip(t *testing.T) {
	result, err := runHelper(t, context.Background(), "copy-stdin", "piped clip text", true)
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if result.Stdout != "piped clip text" {
		t.Fatalf("Stdout = %q, want the clip", result.Stdout)
	}
}

// TestStdinIsClosed is the difference between a command that finishes and one
// that hangs forever waiting for input that never ends.
func TestStdinIsClosed(t *testing.T) {
	done := make(chan struct{})
	go func() {
		defer close(done)
		runHelper(t, context.Background(), "copy-stdin", "short", true)
	}()
	select {
	case <-done:
	case <-time.After(20 * time.Second):
		t.Fatal("a program reading to end of input must not wait forever")
	}
}

// TestAProgramThatStopsReadingStillSucceeds covers the broken pipe. `x head -1`
// exits before consuming the whole clip, and that is the program working.
func TestAProgramThatStopsReadingStillSucceeds(t *testing.T) {
	big := strings.Repeat("abcdefghij", 200000)
	result, err := runHelper(t, context.Background(), "read-one-byte", big, true)
	if err != nil {
		t.Fatalf("a broken pipe is the program succeeding, not an error: %v", err)
	}
	if !result.Succeeded() {
		t.Fatalf("exit code = %d, want 0", result.ExitCode)
	}
}

func TestFailureKeepsOutputAndCode(t *testing.T) {
	result, err := runHelper(t, context.Background(), "fail", "", false)
	if err != nil {
		t.Fatalf("a non-zero exit is a result, not an error: %v", err)
	}
	if result.Succeeded() || result.ExitCode != 3 {
		t.Fatalf("ExitCode = %d, want 3", result.ExitCode)
	}
	if !strings.Contains(result.Stderr, "something went wrong") {
		t.Fatalf("Stderr = %q, want the program's message kept", result.Stderr)
	}
}

// TestOutputIsCapped stops a chatty program taking the process out.
func TestOutputIsCapped(t *testing.T) {
	result, err := runHelper(t, context.Background(), "flood", "", false)
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if !result.Truncated {
		t.Error("a program past the limit must be reported as truncated")
	}
	if len(result.Stdout) > OutputLimit {
		t.Fatalf("kept %d bytes, want at most %d", len(result.Stdout), OutputLimit)
	}
	// Truncation must not be reported as the program failing.
	if !result.Succeeded() {
		t.Errorf("truncating output must not turn into a failure: %+v", result)
	}
}

// TestCancellationStops is the escape hatch for a command that hangs. Without
// it the only way out of `x` on a wedged program is killing Clipman.
func TestCancellationStops(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	go func() {
		time.Sleep(200 * time.Millisecond)
		cancel()
	}()
	start := time.Now()
	result, err := runHelper(t, ctx, "sleep", "", false)
	if err != nil {
		t.Fatalf("a stopped program is a result, not an error: %v", err)
	}
	if !result.Stopped {
		t.Error("a cancelled run must report itself as stopped")
	}
	if elapsed := time.Since(start); elapsed > 20*time.Second {
		t.Fatalf("cancellation took %v; it must not wait for the program", elapsed)
	}
}

// TestMissingProgramIsNamed keeps Go's "executable file not found in %PATH%"
// out of a sentence that gets read aloud.
func TestMissingProgramIsNamed(t *testing.T) {
	_, err := Run(context.Background(), Plan{Args: []string{"clipman-no-such-program-exists"}})
	if !errors.Is(err, ErrProgramNotFound) {
		t.Fatalf("error = %v, want ErrProgramNotFound", err)
	}
	if !strings.Contains(err.Error(), "clipman-no-such-program-exists") {
		t.Errorf("the error must name the program: %v", err)
	}
}

// TestSilentSuccessIsStillAResult matters because a command that prints nothing
// must not read as having done nothing.
func TestSilentSuccessIsStillAResult(t *testing.T) {
	result, err := runHelper(t, context.Background(), "silent", "", false)
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if !result.Succeeded() || result.Stdout != "" {
		t.Fatalf("result = %+v, want a clean silent success", result)
	}
}

func TestEmptyPlanIsRefused(t *testing.T) {
	if _, err := Run(context.Background(), Plan{}); !errors.Is(err, ErrEmptyCommand) {
		t.Fatalf("error = %v, want ErrEmptyCommand", err)
	}
}

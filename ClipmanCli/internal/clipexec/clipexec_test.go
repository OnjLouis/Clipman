package clipexec

import (
	"errors"
	"strings"
	"testing"
)

// TestAClipCannotBecomeCommands is the reason this package exists. A clip is
// whatever the user copied, from anywhere. If any of these produced more than
// one argument, or an argument the user did not type, a copied string would be
// able to run a program of its own choosing.
func TestAClipCannotBecomeCommands(t *testing.T) {
	for _, clip := range []string{
		"; rm -rf ~",
		"&& shutdown now",
		"| tee /etc/passwd",
		"`id`",
		"$(id)",
		"> /etc/hosts",
		"a b c d e",
		`quote" and 'quote`,
		"newline\nsecond line",
		"@clip",
		"{}",
		"--flag=value",
		"",
	} {
		plan, err := Build("echo @clip", clip)
		if err != nil {
			t.Fatalf("Build(%q): %v", clip, err)
		}
		if len(plan.Args) != 2 {
			t.Fatalf("clip %q produced %d arguments %q, want exactly 2", clip, len(plan.Args), plan.Args)
		}
		if plan.Args[0] != "echo" {
			t.Errorf("clip %q changed the program to %q", clip, plan.Args[0])
		}
		if plan.Args[1] != clip {
			t.Errorf("clip %q arrived as %q; it must be one inert argument", clip, plan.Args[1])
		}
		if plan.UsesStdin {
			t.Errorf("clip %q: a substituted command must not also pipe", clip)
		}
	}
}

// TestNoPlaceholderPipesTheClip covers the default. Piping needs no substitution
// at all, which is why it is what happens when nothing else is asked for.
func TestNoPlaceholderPipesTheClip(t *testing.T) {
	plan, err := Build("wc -w", "several words here")
	if err != nil {
		t.Fatalf("Build: %v", err)
	}
	if got, want := strings.Join(plan.Args, " "), "wc -w"; got != want {
		t.Fatalf("Args = %q, want %q", got, want)
	}
	if !plan.UsesStdin || plan.Stdin != "several words here" {
		t.Fatalf("the clip must reach a placeholderless command on stdin, got %q (used %v)", plan.Stdin, plan.UsesStdin)
	}
}

// TestEmptyClipStillPipes separates "piped nothing" from "did not pipe", which a
// program reading to EOF can tell apart.
func TestEmptyClipStillPipes(t *testing.T) {
	plan, err := Build("cat", "")
	if err != nil {
		t.Fatalf("Build: %v", err)
	}
	if !plan.UsesStdin {
		t.Fatal("an empty clip must still be piped, not withheld")
	}
}

func TestEveryPlaceholderArgumentIsSubstituted(t *testing.T) {
	plan, err := Build("diff @clip @clip", "same")
	if err != nil {
		t.Fatalf("Build: %v", err)
	}
	if len(plan.Args) != 3 || plan.Args[1] != "same" || plan.Args[2] != "same" {
		t.Fatalf("Args = %q, want both placeholders substituted", plan.Args)
	}
}

// TestPartialPlaceholderIsRefused covers the silent-failure case: passing
// "pre@clip" through unchanged would look exactly like substitution not working.
func TestPartialPlaceholderIsRefused(t *testing.T) {
	for _, line := range []string{"prog pre@clip", "prog --file=@clip", "prog @clips"} {
		_, err := Build(line, "CLIP")
		var refusal *RefusalError
		if !errors.As(err, &refusal) {
			t.Fatalf("Build(%q) must refuse a partial placeholder, got %v", line, err)
		}
		if !strings.Contains(refusal.Message, "on its own") {
			t.Errorf("Build(%q) must say how to fix it: %q", line, refusal.Message)
		}
	}
}

// TestOtherPlaceholderSpellingsAreRefused matters because xargs and fd muscle
// memory is real, and passing {} through as a literal would be a quiet surprise.
func TestOtherPlaceholderSpellingsAreRefused(t *testing.T) {
	for _, line := range []string{"prog {}", "prog {clip}", "prog $clip", "prog %clip%"} {
		_, err := Build(line, "CLIP")
		var refusal *RefusalError
		if !errors.As(err, &refusal) {
			t.Fatalf("Build(%q) must name the right spelling, got %v", line, err)
		}
		if !strings.Contains(refusal.Message, Placeholder) {
			t.Errorf("Build(%q) must point at %s: %q", line, Placeholder, refusal.Message)
		}
	}
}

// TestShellOperatorsAreRefused is the one surprise this design creates. Running
// sort with a literal "|" argument is guaranteed wrong, so it is refused rather
// than run or merely warned about.
func TestShellOperatorsAreRefused(t *testing.T) {
	for _, item := range []struct {
		line, operator, expect string
	}{
		{"sort | head", "|", "instead of piping"},
		{"sort > out.txt", ">", "Press w to save"},
		{"git status ; ls", ";", "instead of starting another command"},
		{"prog && other", "&&", "instead of running the next command"},
	} {
		_, err := Build(item.line, "CLIP")
		var refusal *RefusalError
		if !errors.As(err, &refusal) {
			t.Fatalf("Build(%q) must refuse, got %v", item.line, err)
		}
		if !strings.Contains(refusal.Message, item.operator) {
			t.Errorf("Build(%q) must name %q: %q", item.line, item.operator, refusal.Message)
		}
		if !strings.Contains(refusal.Message, item.expect) {
			t.Errorf("Build(%q) must say what was lost (%q): %q", item.line, item.expect, refusal.Message)
		}
	}
}

// TestQuotingIsTheEscapeHatch is what makes refusing affordable. A quoted
// operator or placeholder is deliberate by construction, so it is never
// inspected and never refused.
func TestQuotingIsTheEscapeHatch(t *testing.T) {
	for _, item := range []struct {
		line string
		want string
	}{
		{`grep "|" file`, "|"},
		{`prog "@clip"`, "@clip"},
		{`prog '{}'`, "{}"},
		{`prog ";"`, ";"},
		{`prog '$clip'`, "$clip"},
	} {
		plan, err := Build(item.line, "CLIP")
		if err != nil {
			t.Fatalf("Build(%q) must accept a quoted literal: %v", item.line, err)
		}
		if plan.Args[1] != item.want {
			t.Errorf("Build(%q) argument = %q, want the literal %q", item.line, plan.Args[1], item.want)
		}
	}
}

// TestAQuotedPlaceholderDoesNotSubstitute is the other half: quoting it means
// the literal text, so the clip must still reach the program the only other way.
func TestAQuotedPlaceholderDoesNotSubstitute(t *testing.T) {
	plan, err := Build(`prog "@clip"`, "CLIP")
	if err != nil {
		t.Fatalf("Build: %v", err)
	}
	if plan.Args[1] != "@clip" {
		t.Fatalf("Args[1] = %q, want the literal placeholder", plan.Args[1])
	}
	if !plan.UsesStdin {
		t.Error("a quoted placeholder is not a substitution, so the clip should pipe")
	}
}

// TestOperatorsInAClipAreNotRefused matters because the clip is substituted
// after splitting and checking. A clip full of pipes is not a pipeline, and
// refusing it would make clips unusable for the reason they exist.
func TestOperatorsInAClipAreNotRefused(t *testing.T) {
	plan, err := Build("echo @clip", "a | b ; c && d > e")
	if err != nil {
		t.Fatalf("a clip containing operators must be allowed: %v", err)
	}
	if plan.Args[1] != "a | b ; c && d > e" {
		t.Fatalf("Args[1] = %q, want the clip verbatim", plan.Args[1])
	}
}

func TestQuotingKeepsOneArgument(t *testing.T) {
	for _, item := range []struct {
		line string
		want []string
	}{
		{`prog "two words" tail`, []string{"prog", "two words", "tail"}},
		{`prog 'two words' tail`, []string{"prog", "two words", "tail"}},
		{`prog "" tail`, []string{"prog", "", "tail"}},
		{`prog "say \"hi\"" tail`, []string{"prog", `say "hi"`, "tail"}},
		{`  prog   spaced   `, []string{"prog", "spaced"}},
	} {
		plan, err := Build(item.line, "unused")
		if err != nil {
			t.Fatalf("Build(%q): %v", item.line, err)
		}
		if strings.Join(plan.Args, "\x00") != strings.Join(item.want, "\x00") {
			t.Fatalf("Build(%q) = %q, want %q", item.line, plan.Args, item.want)
		}
	}
}

func TestUnbalancedQuoteIsRefused(t *testing.T) {
	_, err := Build(`prog "unterminated`, "clip")
	var refusal *RefusalError
	if !errors.As(err, &refusal) {
		t.Fatalf("an unbalanced quote must be reported, not guessed at, got %v", err)
	}
}

func TestEmptyCommandIsRefused(t *testing.T) {
	for _, line := range []string{"", "   ", "\t"} {
		if _, err := Build(line, "clip"); !errors.Is(err, ErrEmptyCommand) {
			t.Fatalf("Build(%q) error = %v, want ErrEmptyCommand", line, err)
		}
	}
}

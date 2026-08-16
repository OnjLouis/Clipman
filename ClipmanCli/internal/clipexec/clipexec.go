// Package clipexec turns a command line typed by the user into a program to run
// against a clip, without a shell.
//
// A clip is untrusted data. It is whatever the user copied, from anywhere, and
// it routinely holds URLs, configuration blobs, and code. Substituting it into a
// command string and handing that string to sh -c or cmd /c would mean a clip
// containing "; rm -rf ~" executes when the user asks to echo it. They would
// have typed nothing dangerous; the clip would have done it.
//
// So there is no shell anywhere in this package. The command line is split into
// arguments here, the clip replaces whole arguments that are never re-split, and
// the result goes to os/exec directly. A clip containing spaces, semicolons,
// quotes, or backticks is one inert argument.
//
// The cost is that shell operators are not operators. Rather than let "sort |
// head" run sort with two junk arguments, this package refuses it and says why.
// Refusing is affordable because quoting is the escape hatch: a quoted operator
// is obviously deliberate, so the warning fires only on the exact mistake.
package clipexec

import (
	"errors"
	"fmt"
	"strings"
)

// Placeholder is the argument replaced by the clip's text.
//
// It is spelled with an at sign rather than a dollar sign on purpose. "$clip"
// would promise shell expansion this package deliberately refuses, inviting
// "$HOME" and "${clip}" that silently stay literal. Braces were rejected for a
// different reason: at default punctuation verbosity many screen readers do not
// speak them, so "{clip}" and "clip" sound alike when a user reviews what they
// typed, and an unclosed brace then fails both silently and inaudibly.
const Placeholder = "@clip"

// Plan is a program to run and how the clip reaches it.
type Plan struct {
	// Args is the program and its arguments, already substituted. Args[0] is the
	// program. No element is ever re-split, so a clip is exactly one argument no
	// matter what it contains.
	Args []string
	// Stdin is written to the program's standard input when the command line
	// names no placeholder. Piping needs no substitution at all, which is why it
	// is the default rather than an option.
	Stdin string
	// UsesStdin separates an empty clip piped in from no piping at all, which a
	// program reading to EOF can tell apart.
	UsesStdin bool
}

// ErrEmptyCommand reports that nothing was typed.
var ErrEmptyCommand = errors.New("no command was given")

// RefusalError is a command this package will not run, carrying the sentence the
// user should hear. The wording is the point: every refusal names what was found,
// what would otherwise happen, and the way to get what was meant.
type RefusalError struct{ Message string }

func (e *RefusalError) Error() string { return e.Message }

func refuse(format string, args ...any) error {
	return &RefusalError{Message: fmt.Sprintf(format, args...)}
}

// operatorEffect describes what each shell operator would have done, so a
// refusal can say what was lost rather than only that something was wrong.
var operatorEffect = map[string]string{
	"|":  "instead of piping",
	"||": "instead of running the next command",
	">":  "instead of redirecting",
	">>": "instead of redirecting",
	"<":  "instead of redirecting",
	";":  "instead of starting another command",
	"&":  "instead of running it in the background",
	"&&": "instead of running the next command",
}

// Build parses commandLine and places clip into it.
//
// With the placeholder present the clip replaces those arguments and standard
// input is left empty. Without it the clip is piped to the program's standard
// input.
func Build(commandLine, clip string) (Plan, error) {
	tokens, err := split(commandLine)
	if err != nil {
		return Plan{}, err
	}
	if len(tokens) == 0 {
		return Plan{}, ErrEmptyCommand
	}
	program := tokens[0].text

	args := make([]string, 0, len(tokens))
	substituted := false
	for _, item := range tokens {
		// A quoted argument is deliberate by construction, so it is taken
		// literally and never inspected. That is what makes refusing the
		// unquoted forms affordable.
		if item.quoted {
			args = append(args, item.text)
			continue
		}
		if err := checkToken(item.text, program); err != nil {
			return Plan{}, err
		}
		if item.text == Placeholder {
			args = append(args, clip)
			substituted = true
			continue
		}
		args = append(args, item.text)
	}

	plan := Plan{Args: args}
	if !substituted {
		plan.Stdin = clip
		plan.UsesStdin = true
	}
	return plan, nil
}

// checkToken refuses the mistakes that would otherwise be silent.
func checkToken(text, program string) error {
	if effect, ok := operatorEffect[text]; ok {
		hint := "Run one program at a time"
		if text == ">" || text == ">>" {
			hint = "Press w to save the clip to a file"
		}
		return refuse("No shell is used, so %q would be handed to %s as an ordinary argument %s. %s, or put %q in quotes if you meant it literally.",
			text, program, effect, hint, text)
	}
	// xargs and fd spell this placeholder with braces, and that muscle memory is
	// real. Passing {} through as a literal argument would be a quiet surprise,
	// so it is named instead.
	for _, wrong := range []string{"{clip}", "{}", "$clip", "%clip%"} {
		if strings.Contains(text, wrong) {
			return refuse("Clipman spells the placeholder %s. Type %s where the clip text should go, or put %q in quotes if you meant it literally.",
				Placeholder, Placeholder, wrong)
		}
	}
	// Substitution is whole-argument only, so a placeholder glued to other text
	// cannot be honoured. Passing it through unchanged would look like the
	// substitution silently failed.
	if text != Placeholder && strings.Contains(text, Placeholder) {
		return refuse("%q is not exactly %s, so it would be passed through unchanged. Make %s an argument on its own, or put it in quotes if you meant it literally.",
			text, Placeholder, Placeholder)
	}
	return nil
}

// token is one argument and whether the user quoted it. The flag is what lets a
// quoted operator or a quoted placeholder be taken literally.
type token struct {
	text   string
	quoted bool
}

// split breaks a command line into arguments on whitespace, honouring single and
// double quotes so a path with a space can be one argument.
//
// This is deliberately not a shell parser. It knows about quoting and nothing
// else: no expansion, no substitution, no operators, and no escapes beyond a
// backslash before a quote or a backslash inside double quotes. Anything more
// would be the mini-shell this package exists to avoid.
func split(commandLine string) ([]token, error) {
	var tokens []token
	var current strings.Builder
	started, quoted := false, false
	quote := byte(0)

	flush := func() {
		if started {
			tokens = append(tokens, token{text: current.String(), quoted: quoted})
			current.Reset()
			started, quoted = false, false
		}
	}

	for index := 0; index < len(commandLine); index++ {
		c := commandLine[index]
		switch {
		case quote != 0 && c == quote:
			quote = 0
		case quote == '"' && c == '\\' && index+1 < len(commandLine) &&
			(commandLine[index+1] == '"' || commandLine[index+1] == '\\'):
			index++
			current.WriteByte(commandLine[index])
			started = true
		case quote != 0:
			current.WriteByte(c)
			started = true
		case c == '\'' || c == '"':
			quote = c
			// An empty quoted string is still an argument, and quoting any part
			// of an argument marks the whole of it as deliberate.
			started, quoted = true, true
		case c == ' ' || c == '\t':
			flush()
		default:
			current.WriteByte(c)
			started = true
		}
	}
	if quote != 0 {
		return nil, refuse("A %c quote was opened and never closed.", quote)
	}
	flush()
	return tokens, nil
}

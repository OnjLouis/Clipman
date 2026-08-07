package clipexec

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"io"
	"os/exec"
	"strings"
)

// OutputLimit caps how much of a program's output is kept.
//
// Without a cap, "x yes" grows a buffer until the process dies. A megabyte is
// far more than anyone reads through a screen reader and still enough that
// truncation is rare.
const OutputLimit = 1 << 20

// Result is what running a program produced. It is a value rather than a stream
// because the caller presents it in a viewer the user can move back through: a
// screen-reader user gets one pass at anything written to a terminal, and this
// output is worth being able to re-read.
type Result struct {
	Program   string
	Stdout    string
	Stderr    string
	ExitCode  int
	Truncated bool
	// Stopped records that the run was cancelled rather than finishing.
	Stopped bool
}

// Succeeded reports the plain reading of the exit status.
func (r Result) Succeeded() bool { return r.ExitCode == 0 && !r.Stopped }

// ErrProgramNotFound reports that the named program is not on the PATH. It is
// separated from other start failures because it is the one the user can act on,
// and because Go's own message ("exec: \"sort\": executable file not found in
// %PATH%") is not a sentence anyone wants read aloud.
var ErrProgramNotFound = errors.New("program not found")

// Run executes plan and captures what it produced.
//
// Nothing here is given the process's own standard output. That stream may be a
// pipe belonging to the user — `clipman-cli pick --tui | ssh host 'cat > f'` has
// one — and anything a child wrote into it would be injected into the payload
// and silently corrupt the file at the far end. Terminal and payload are
// different destinations, and a child process does not get to blur them.
//
// Standard input is the clip when the command asked for no placeholder, and the
// null device otherwise. It is never the console: a command that turns out to be
// interactive then reaches end of input and exits, rather than hanging on a
// terminal it should not have while the screen is torn down.
func Run(ctx context.Context, plan Plan) (Result, error) {
	if len(plan.Args) == 0 {
		return Result{}, ErrEmptyCommand
	}
	result := Result{Program: plan.Args[0]}

	command := exec.CommandContext(ctx, plan.Args[0], plan.Args[1:]...)
	stdout := &cappedBuffer{limit: OutputLimit}
	stderr := &cappedBuffer{limit: OutputLimit}
	command.Stdout = stdout
	command.Stderr = stderr

	var stdin io.WriteCloser
	if plan.UsesStdin {
		pipe, err := command.StdinPipe()
		if err != nil {
			return result, err
		}
		stdin = pipe
	}

	if err := command.Start(); err != nil {
		if stdin != nil {
			stdin.Close()
		}
		if errors.Is(err, exec.ErrNotFound) {
			return result, fmt.Errorf("%w: %s", ErrProgramNotFound, plan.Args[0])
		}
		return result, err
	}

	if stdin != nil {
		// Written on its own goroutine and always closed. A program that reads
		// only part of the clip — "head -1" is the obvious one — exits while the
		// write is still going, and the resulting broken pipe is that program
		// succeeding, not failing. Closing is what stops a program that reads to
		// end of input from waiting forever.
		go func() {
			io.Copy(stdin, strings.NewReader(plan.Stdin))
			stdin.Close()
		}()
	}

	err := command.Wait()
	result.Stdout = stdout.buf.String()
	result.Stderr = stderr.buf.String()
	result.Truncated = stdout.truncated || stderr.truncated

	var exitErr *exec.ExitError
	switch {
	case err == nil:
	case errors.As(err, &exitErr):
		result.ExitCode = exitErr.ExitCode()
	default:
		return result, err
	}
	if ctx.Err() != nil {
		result.Stopped = true
	}
	return result, nil
}

// cappedBuffer keeps the first limit bytes and remembers that it stopped.
//
// Writes past the limit are reported as successful rather than short. A short
// write would surface to the child as a broken pipe and kill it, which would
// turn "the output was long" into "the command failed".
type cappedBuffer struct {
	limit     int
	buf       bytes.Buffer
	truncated bool
}

func (c *cappedBuffer) Write(p []byte) (int, error) {
	remaining := c.limit - c.buf.Len()
	if remaining <= 0 {
		c.truncated = true
		return len(p), nil
	}
	if len(p) > remaining {
		c.buf.Write(p[:remaining])
		c.truncated = true
		return len(p), nil
	}
	return c.buf.Write(p)
}

// Package handoff carries the user's place from one interface to the other.
//
// Clipman CLI ships two interchangeable browsers over the same history, and
// neither can become the other in place: the full-screen interface owns the
// terminal through tcell, so the running one has to stop and the caller has to
// start the other.
//
// "The user pressed u" would be enough to do that, and would also be the wrong
// thing to build. The entire screen changes under someone who cannot see it, so
// arriving at page one of an unfiltered list is how a person loses their place.
// What travels in this struct is what makes the arrival recognisable as the
// same session.
package handoff

import "github.com/OnjLouis/Clipman/ClipmanCli/internal/operation"

// Request is returned as an error by whichever browser the user left. It is an
// error because that is the only channel a browser has back to its caller, not
// because anything failed, so callers match it with errors.As and must not
// report it as a failure.
type Request struct {
	// Selected is the position in the filtered view the user was resting on.
	Selected int
	// Filter is the active search text. Both interfaces apply the identical
	// predicate, so it transfers exactly rather than approximately.
	Filter string
	// Kind is the history, templates, or both view. The full-screen interface
	// changes it with Tab and the line interface cannot, so without carrying it
	// a user who switched view and then switched interface would land somewhere
	// they never asked for.
	Kind operation.Kind
}

// Error makes Request an error so a browser can return it through its ordinary
// return path. The text is never shown: every caller intercepts it.
func (r *Request) Error() string { return "switch to the other interface" }

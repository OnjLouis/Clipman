package clipdb_test

import "flag"

// exportDir opts into writing CLI-encoded blobs for the C# verifier. It is a
// flag rather than an environment variable so the intent is visible in the
// command line that produced the files.
var exportDir string

func init() {
	flag.StringVar(&exportDir, "clipman-export", "", "write CLI-encoded fixture blobs to this directory for cross-client verification")
}

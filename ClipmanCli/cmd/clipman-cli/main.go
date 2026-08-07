package main

import (
	"bufio"
	"context"
	"crypto/sha256"
	"crypto/tls"
	"crypto/x509"
	"encoding/json"
	"encoding/pem"
	"errors"
	"flag"
	"fmt"
	"io"
	"net"
	"net/url"
	"os"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/gdamore/tcell/v2"
	"golang.org/x/term"

	"github.com/OnjLouis/Clipman/ClipmanCli/internal/clipdb"
	"github.com/OnjLouis/Clipman/ClipmanCli/internal/config"
	"github.com/OnjLouis/Clipman/ClipmanCli/internal/identity"
	"github.com/OnjLouis/Clipman/ClipmanCli/internal/merge"
	"github.com/OnjLouis/Clipman/ClipmanCli/internal/model"
	"github.com/OnjLouis/Clipman/ClipmanCli/internal/operation"
	"github.com/OnjLouis/Clipman/ClipmanCli/internal/output"
	"github.com/OnjLouis/Clipman/ClipmanCli/internal/platform"
	"github.com/OnjLouis/Clipman/ClipmanCli/internal/server"
	"github.com/OnjLouis/Clipman/ClipmanCli/internal/syncengine"
	"github.com/OnjLouis/Clipman/ClipmanCli/internal/template"
	"github.com/OnjLouis/Clipman/ClipmanCli/internal/ui/handoff"
	"github.com/OnjLouis/Clipman/ClipmanCli/internal/ui/line"
	"github.com/OnjLouis/Clipman/ClipmanCli/internal/ui/tui"
)

var version = "0.3.0-dev"

type appError struct {
	code int
	err  error
}

func (e appError) Error() string { return e.err.Error() }
func fail(code int, format string, args ...any) error {
	return appError{code: code, err: fmt.Errorf(format, args...)}
}

// errHelpRequested reports that a command printed its own usage in response to
// --help or -h. It is not a failure and must not be written to standard error.
var errHelpRequested = errors.New("help requested")

type optionalString struct {
	value string
	set   bool
}
type globals struct {
	configPath, server, caCertFile          string
	password                                optionalString
	json, quiet, verbose, showVersion, help bool
	insecure                                bool
}
type appContext struct {
	globals                     globals
	configPath                  string
	config                      config.Config
	token, password, databaseID string
	client                      *server.Client
	engine                      *syncengine.Engine
}

func main() { code := run(os.Args[1:]); os.Exit(code) }
func run(args []string) int {
	globals, remaining, err := parseGlobals(args)
	if err != nil {
		return printError(err)
	}
	if globals.showVersion {
		if _, err := fmt.Printf("clipman-cli %s (%s/%s)\n", version, runtime.GOOS, runtime.GOARCH); err != nil {
			return printError(fail(1, "cannot write output: %v", err))
		}
		return 0
	}
	if len(remaining) == 0 {
		if globals.help {
			printUsage(os.Stdout)
			return 0
		}
		if platform.IsInteractive() {
			remaining = []string{"menu"}
		} else {
			printUsage(os.Stderr)
			return 2
		}
	}
	command := remaining[0]
	commandArgs := remaining[1:]
	if globals.help || hasHelpOption(commandArgs) {
		if printCommandUsage(os.Stdout, command) {
			return 0
		}
		return printError(fail(2, "unknown command %q", command))
	}
	if command == "help" {
		if len(commandArgs) == 0 {
			printUsage(os.Stdout)
			return 0
		}
		if len(commandArgs) == 1 && printCommandUsage(os.Stdout, commandArgs[0]) {
			return 0
		}
		return printError(fail(2, "usage: clipman-cli help [COMMAND]"))
	}
	known := map[string]bool{"init": true, "status": true, "list": true, "get": true, "put": true, "rm": true, "sync": true, "pick": true, "menu": true}
	if !known[command] {
		return printError(fail(2, "unknown command %q", command))
	}
	var commandErr error
	if command == "init" {
		commandErr = runInit(globals, commandArgs)
	} else {
		ctx, err := loadContext(globals)
		if err != nil {
			return printError(err)
		}
		switch command {
		case "status":
			commandErr = runStatus(ctx, commandArgs)
		case "list":
			commandErr = runList(ctx, commandArgs)
		case "get":
			commandErr = runGet(ctx, commandArgs)
		case "put":
			commandErr = runPut(ctx, commandArgs)
		case "rm":
			commandErr = runRemove(ctx, commandArgs)
		case "sync":
			commandErr = runSync(ctx, commandArgs)
		case "pick":
			commandErr = runPick(ctx, commandArgs)
		case "menu":
			commandErr = runMenu(ctx, commandArgs)
		}
	}
	return printError(commandErr)
}

func hasHelpOption(args []string) bool {
	return len(args) > 0 && (args[0] == "--help" || args[0] == "-h")
}
func printError(err error) int {
	if err == nil || errors.Is(err, errHelpRequested) {
		return 0
	}
	code := 1
	var app appError
	if errors.As(err, &app) {
		code = app.code
	}
	fmt.Fprintln(os.Stderr, "clipman-cli:", err)
	return code
}

func parseGlobals(args []string) (globals, []string, error) {
	var g globals
	value := func(index *int, arg, name string) (string, bool, error) {
		prefix := "--" + name + "="
		if strings.HasPrefix(arg, prefix) {
			return strings.TrimPrefix(arg, prefix), true, nil
		}
		if arg == "--"+name {
			if *index+1 >= len(args) {
				return "", false, fail(2, "%s requires a value", arg)
			}
			*index = *index + 1
			return args[*index], true, nil
		}
		return "", false, nil
	}
	for i := 0; i < len(args); i++ {
		arg := args[i]
		if arg == "--" {
			return g, args[i+1:], nil
		}
		if !strings.HasPrefix(arg, "-") {
			return g, args[i:], nil
		}
		if v, ok, err := value(&i, arg, "config"); err != nil {
			return g, nil, err
		} else if ok {
			g.configPath = v
			continue
		}
		if v, ok, err := value(&i, arg, "server"); err != nil {
			return g, nil, err
		} else if ok {
			g.server = v
			continue
		}
		if v, ok, err := value(&i, arg, "password"); err != nil {
			return g, nil, err
		} else if ok {
			g.password = optionalString{value: v, set: true}
			continue
		}
		if v, ok, err := value(&i, arg, "ca-cert"); err != nil {
			return g, nil, err
		} else if ok {
			g.caCertFile = v
			continue
		}
		switch arg {
		case "--json":
			g.json = true
		case "--quiet", "-q":
			g.quiet = true
		case "--verbose":
			g.verbose = true
		case "--insecure":
			g.insecure = true
		case "--version":
			g.showVersion = true
		case "--help", "-h":
			g.help = true
		default:
			return g, nil, fail(2, "unknown global option %q; place command options after the command", arg)
		}
	}
	return g, nil, nil
}

func addOutputFlags(fs *flag.FlagSet, g *globals) {
	fs.BoolVar(&g.json, "json", g.json, "write JSON output")
	fs.BoolVar(&g.quiet, "quiet", g.quiet, "suppress status messages")
	fs.BoolVar(&g.quiet, "q", g.quiet, "suppress status messages")
	fs.BoolVar(&g.verbose, "verbose", g.verbose, "write diagnostic status messages")
}

// newFlagSet builds a command flag set that writes nothing itself, so that
// parseCommandFlags is the single place that reports usage and errors. The flag
// package would otherwise repeat the error and add a long generated option
// dump, which is unordered and reads poorly aloud in a screen reader.
func newFlagSet(command string) *flag.FlagSet {
	fs := flag.NewFlagSet(command, flag.ContinueOnError)
	fs.SetOutput(io.Discard)
	fs.Usage = func() {}
	return fs
}

// parseCommandFlags parses args and turns a --help or -h anywhere in the
// command line into the command's usage on standard output, so that
// `get --json --help` behaves like `get --help`. Any other parse failure gets
// the same one-line syntax on standard error, followed by the error itself.
func parseCommandFlags(fs *flag.FlagSet, command string, args []string) error {
	if err := fs.Parse(args); err != nil {
		if errors.Is(err, flag.ErrHelp) {
			printCommandUsage(os.Stdout, command)
			return errHelpRequested
		}
		printCommandUsage(os.Stderr, command)
		return fail(2, "%v", err)
	}
	return nil
}

// permuteArgs moves positional operands behind the options so that options may
// follow an index, as the documented syntax implies. The flag package stops at
// the first operand, which would otherwise make `get 0 --json` read --json as a
// second index and report a confusing "only one index may be supplied".
func permuteArgs(fs *flag.FlagSet, args []string) []string {
	options := make([]string, 0, len(args))
	operands := make([]string, 0, len(args))
	for i := 0; i < len(args); i++ {
		arg := args[i]
		if arg == "--" {
			operands = append(operands, args[i+1:]...)
			break
		}
		if len(arg) < 2 || !strings.HasPrefix(arg, "-") {
			operands = append(operands, arg)
			continue
		}
		options = append(options, arg)
		if strings.Contains(arg, "=") {
			continue
		}
		defined := fs.Lookup(strings.TrimLeft(arg, "-"))
		if defined == nil {
			continue
		}
		if boolValue, ok := defined.Value.(interface{ IsBoolFlag() bool }); ok && boolValue.IsBoolFlag() {
			continue
		}
		if i+1 < len(args) {
			i++
			options = append(options, args[i])
		}
	}
	if len(operands) == 0 {
		return options
	}
	// The separator keeps an operand that begins with "-" from being reparsed
	// as an option once it has moved behind the options.
	return append(append(options, "--"), operands...)
}

// verbosef writes a diagnostic line to standard error for --verbose. It never
// reports a token, a password, or a full database identifier.
func verbosef(g globals, format string, args ...any) {
	if !g.verbose || g.quiet {
		return
	}
	fmt.Fprintf(os.Stderr, "clipman-cli: "+format+"\n", args...)
}

// tlsOptionsForGlobals resolves the TLS trust options to use for a connection,
// preferring explicit --insecure/--ca-cert global flags over whatever was
// persisted to the configuration file by `init`.
func tlsOptionsForGlobals(g globals, cfg config.Config) ([]server.Option, error) {
	if g.insecure && g.caCertFile != "" {
		return nil, fail(2, "--insecure and --ca-cert cannot be used together")
	}
	if g.insecure {
		fmt.Fprintln(os.Stderr, "Warning: --insecure disables TLS certificate verification. Use only on a trusted private network.")
		return []server.Option{server.WithInsecureSkipVerify()}, nil
	}
	if g.caCertFile != "" {
		pem, err := readCACertFile(g.caCertFile)
		if err != nil {
			return nil, err
		}
		return []server.Option{server.WithCACertPEM(pem)}, nil
	}
	if cfg.TLSInsecure {
		fmt.Fprintln(os.Stderr, "Warning: this profile disables TLS certificate verification. Use only on a trusted private network.")
		return []server.Option{server.WithInsecureSkipVerify()}, nil
	}
	if cfg.CACertPEM != "" {
		if cfg.CAExclusive {
			return []server.Option{server.WithExclusiveCACertPEM([]byte(cfg.CACertPEM))}, nil
		}
		return []server.Option{server.WithCACertPEM([]byte(cfg.CACertPEM))}, nil
	}
	return nil, nil
}

func readCACertFile(path string) ([]byte, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, fail(3, "cannot read CA certificate file: %v", err)
	}
	if !x509.NewCertPool().AppendCertsFromPEM(data) {
		return nil, fail(2, "%s does not contain a valid PEM certificate", path)
	}
	return data, nil
}

// isCertificateTrustError reports whether err is a TLS failure caused by an
// untrusted/unrecognized certificate, as opposed to a network or protocol
// failure that a trust prompt cannot help with.
func isCertificateTrustError(err error) bool {
	var verifyErr *tls.CertificateVerificationError
	if errors.As(err, &verifyErr) {
		err = verifyErr.Err
	}
	var unknownAuthority x509.UnknownAuthorityError
	return errors.As(err, &unknownAuthority)
}

// fetchServerCertificate connects to rawURL's host without verifying the
// certificate, purely to retrieve it for display in a trust prompt. It does
// not use the result to make the connection trusted.
func fetchServerCertificates(ctx context.Context, rawURL string) (*x509.Certificate, *x509.Certificate, error) {
	parsed, err := url.Parse(rawURL)
	if err != nil {
		return nil, nil, err
	}
	if parsed.Scheme != "https" {
		return nil, nil, errors.New("server does not use HTTPS")
	}
	host := parsed.Hostname()
	if host == "" {
		return nil, nil, errors.New("server host is missing")
	}
	port := parsed.Port()
	if port == "" {
		port = "443"
	}
	address := net.JoinHostPort(host, port)
	dialer := &tls.Dialer{
		NetDialer: &net.Dialer{Timeout: 8 * time.Second},
		Config: &tls.Config{
			InsecureSkipVerify: true,
			MinVersion:         tls.VersionTLS12,
			ServerName:         host,
		},
	}
	conn, err := dialer.DialContext(ctx, "tcp", address)
	if err != nil {
		return nil, nil, err
	}
	defer conn.Close()
	tlsConn, ok := conn.(*tls.Conn)
	if !ok {
		return nil, nil, errors.New("server connection did not negotiate TLS")
	}
	state := tlsConn.ConnectionState()
	if len(state.PeerCertificates) == 0 {
		return nil, nil, errors.New("server did not present a certificate")
	}
	return state.PeerCertificates[0], state.PeerCertificates[len(state.PeerCertificates)-1], nil
}

func certificateFingerprintSHA256(cert *x509.Certificate) string {
	sum := sha256.Sum256(cert.Raw)
	parts := make([]string, len(sum))
	for i, b := range sum {
		parts[i] = fmt.Sprintf("%02X", b)
	}
	return strings.Join(parts, ":")
}

// promptTrustCertificate shows the server's certificate details and fingerprint
// and asks the user to confirm trusting it, browser-exception style. It
// returns the PEM-encoded certificate to trust, or nil if the user declined
// or the certificate could not be retrieved for display.
func promptTrustCertificate(ctx context.Context, rawURL string) ([]byte, error) {
	leaf, authority, err := fetchServerCertificates(ctx, rawURL)
	if err != nil {
		fmt.Fprintf(os.Stderr, "Could not retrieve the server certificate to display: %v\n", err)
		return nil, nil
	}
	fmt.Fprintln(os.Stderr, "The server's TLS certificate is not trusted.")
	fmt.Fprintf(os.Stderr, "  Server subject: %s\n", leaf.Subject)
	fmt.Fprintf(os.Stderr, "  Server issuer: %s\n", leaf.Issuer)
	fmt.Fprintf(os.Stderr, "  Server certificate valid: %s to %s\n", leaf.NotBefore.Format("2006-01-02"), leaf.NotAfter.Format("2006-01-02"))
	fmt.Fprintf(os.Stderr, "  Authority SHA-256 fingerprint: %s\n", certificateFingerprintSHA256(authority))
	fmt.Fprintln(os.Stderr, "Compare the authority fingerprint with the one shown by the Clipman Server administrator before trusting it.")
	trust, err := promptYesNo("Trust this certificate for this server", false)
	if err != nil {
		return nil, err
	}
	if !trust {
		return nil, nil
	}
	return pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: authority.Raw}), nil
}

func loadContext(g globals) (*appContext, error) {
	path, err := platform.ConfigPath(g.configPath)
	if err != nil {
		return nil, fail(3, "cannot locate configuration: %v", err)
	}
	cfg, err := config.Load(path)
	if err != nil {
		if os.IsNotExist(err) {
			return nil, fail(3, "Clipman CLI is not configured; run clipman-cli init")
		}
		return nil, fail(3, "cannot read configuration: %v", err)
	}
	token, err := cfg.ResolvedToken()
	if err != nil {
		return nil, fail(3, "cannot unlock server token: %v", err)
	}
	password, err := resolvePassword(g, cfg, true)
	if err != nil {
		return nil, err
	}
	serverURL := cfg.Server
	if g.server != "" {
		serverURL = g.server
	}
	tlsOptions, err := tlsOptionsForGlobals(g, cfg)
	if err != nil {
		return nil, err
	}
	databaseID := identity.DatabaseID(token, password)
	client, err := server.New(serverURL, token, databaseID, version+" ("+runtime.GOOS+"/"+runtime.GOARCH+")", tlsOptions...)
	if err != nil {
		return nil, fail(2, "invalid server configuration: %v", err)
	}
	verbosef(g, "configuration %s", path)
	verbosef(g, "server %s", serverURL)
	verbosef(g, "history bucket %s", fingerprint(databaseID))
	limits := clipdb.Limits{MaxBlobBytes: cfg.Limits.MaxBlobBytes, MaxJSONBytes: cfg.Limits.MaxJSONBytes, MaxEntries: cfg.Limits.MaxEntries, MaxTextBytes: cfg.Limits.MaxTextBytes}
	engine := &syncengine.Engine{Client: client, Password: password, Limits: limits, Retries: 3}
	return &appContext{globals: g, configPath: path, config: cfg, token: token, password: password, databaseID: databaseID, client: client, engine: engine}, nil
}

func resolvePassword(g globals, cfg config.Config, allowPrompt bool) (string, error) {
	var password string
	if g.password.set {
		password = g.password.value
	} else if value, ok := os.LookupEnv("CLIPMAN_PASSWORD"); ok {
		password = value
	} else if value, ok, err := cfg.ResolvedPassword(); err != nil {
		return "", fail(3, "cannot unlock history password: %v", err)
	} else if ok {
		password = value
	} else if !allowPrompt {
		return "", fail(5, "history password is required; set CLIPMAN_PASSWORD or use --password")
	} else {
		var err error
		password, err = promptPassword("History password: ")
		if err != nil {
			return "", err
		}
	}
	if password == "" {
		return "", fail(5, "Clipman Server requires a nonblank history password")
	}
	return password, nil
}

func runInit(g globals, args []string) error {
	fs := newFlagSet("init")
	addOutputFlags(fs, &g)
	tokenValue := fs.String("token", "", "server token (visible in process lists)")
	tokenFile := fs.String("token-file", "", "read server token from a file")
	connectionFile := fs.String("connection-file", "", "read server address and token from Clipman connection details")
	savePassword := fs.String("save-password", "none", "none or config")
	machine := fs.String("machine", "", "source machine name")
	nonInteractive := fs.Bool("non-interactive", false, "do not prompt")
	force := fs.Bool("force", false, "replace existing configuration")
	portable := fs.Bool("portable", false, "write the configuration beside this executable")
	if err := parseCommandFlags(fs, "init", args); err != nil {
		return err
	}
	savePasswordExplicit := false
	fs.Visit(func(f *flag.Flag) {
		if f.Name == "save-password" {
			savePasswordExplicit = true
		}
	})
	// Where the settings go is asked before anything else, because it decides
	// which file the rest of this command is about to write.
	//
	// The question avoids "system wide", which would be wrong — nothing here
	// writes machine-wide, only to this user account — and "portable", which
	// is jargon that does not say portable relative to what. What a person
	// answering actually needs to know is which copies end up sharing the
	// settings.
	saveBesideProgram := *portable
	if !saveBesideProgram && shouldAskWhereToSave(g, *nonInteractive) {
		fmt.Fprintln(os.Stderr, "Settings are normally saved for your user account, where every copy of Clipman CLI shares them.")
		answer, promptErr := promptYesNo("Save them beside this program instead, so only this copy uses them?", false)
		if promptErr != nil {
			return promptErr
		}
		saveBesideProgram = answer
	}

	var path string
	var err error
	if saveBesideProgram {
		if g.configPath != "" {
			return fail(2, "--portable and --config cannot be used together")
		}
		path, err = platform.PortableConfigPath()
		if err != nil {
			return fail(3, "cannot locate this executable: %v", err)
		}
	} else {
		path, err = platform.ConfigPath(g.configPath)
		if err != nil {
			return fail(3, "cannot locate configuration: %v", err)
		}
	}
	if config.Exists(path) && !*force {
		return fail(2, "configuration already exists at %s; use --force to replace it", path)
	}
	serverURL := g.server
	var connectionCACertPEM []byte
	if *connectionFile == "" && *tokenValue == "" && *tokenFile == "" && serverURL == "" && !*nonInteractive {
		useFile, promptErr := promptYesNo("Do you have a Clipman Server connection file (.clpconf)?", false)
		if promptErr != nil {
			return promptErr
		}
		if useFile {
			filePath, promptErr := promptLine("Path to connection file: ")
			if promptErr != nil {
				return promptErr
			}
			*connectionFile = strings.Trim(strings.TrimSpace(filePath), "\"")
		}
	}
	if *connectionFile != "" {
		if *tokenFile != "" || *tokenValue != "" {
			return fail(2, "--connection-file cannot be combined with --token or --token-file")
		}
		connectionInfo, readErr := os.Stat(*connectionFile)
		if readErr != nil {
			return fail(3, "cannot inspect connection file: %v", readErr)
		}
		if connectionInfo.Size() > 65536 {
			return fail(2, "connection file is too large")
		}
		connectionData, readErr := os.ReadFile(*connectionFile)
		if readErr != nil {
			return fail(3, "cannot read connection file: %v", readErr)
		}
		extractedServer, extractedToken, extractedCA, profileErr := server.ConnectionProfile(string(connectionData))
		if profileErr != nil {
			return fail(2, "invalid connection file: %v", profileErr)
		}
		if serverURL == "" {
			serverURL = extractedServer
		}
		*tokenValue = extractedToken
		connectionCACertPEM = []byte(extractedCA)
	}
	if serverURL == "" {
		if *nonInteractive {
			return fail(2, "--server is required in non-interactive mode")
		}
		serverURL, err = promptLine("Clipman Server address: ")
		if err != nil {
			return err
		}
	}
	token := *tokenValue
	if *tokenFile != "" {
		if token != "" {
			return fail(2, "--token and --token-file cannot be used together")
		}
		data, readErr := os.ReadFile(*tokenFile)
		if readErr != nil {
			return fail(3, "cannot read token file: %v", readErr)
		}
		token = string(data)
	}
	if token == "" {
		if value := os.Getenv("CLIPMAN_TOKEN"); value != "" {
			token = value
		} else if *nonInteractive {
			return fail(2, "a token is required in non-interactive mode")
		} else {
			token, err = promptPassword("Clipman Server token: ")
			if err != nil {
				return err
			}
		}
	}
	token = server.CleanToken(token)
	if token == "" {
		return fail(2, "server token is empty")
	}
	var password string
	if g.password.set {
		password = g.password.value
	} else if value, ok := os.LookupEnv("CLIPMAN_PASSWORD"); ok {
		password = value
	} else if *nonInteractive {
		return fail(2, "provide a nonblank --password in non-interactive mode")
	} else {
		password, err = promptPassword("History password: ")
		if err != nil {
			return err
		}
	}
	if password == "" {
		return fail(5, "Clipman Server requires a nonblank history password")
	}
	if !savePasswordExplicit && !*nonInteractive {
		save, promptErr := promptYesNo("Save the history password in the configuration file so it is not requested again?", false)
		if promptErr != nil {
			return promptErr
		}
		if save {
			*savePassword = "config"
			if !g.quiet {
				if runtime.GOOS == "windows" {
					fmt.Fprintln(os.Stderr, "The password will be saved, encrypted for this Windows user account.")
				} else {
					fmt.Fprintln(os.Stderr, "The password will be saved in the configuration file, protected only by file permissions (owner-only, not encrypted). Anyone with access to this account or root can read it.")
				}
			}
		}
	}
	normalized, err := server.NormalizeURL(serverURL)
	if err != nil {
		return fail(2, "invalid server address: %v", err)
	}
	if server.IsInsecureRemoteURL(normalized) {
		fmt.Fprintln(os.Stderr, "Warning: plain HTTP exposes the server token on the network. Use HTTPS, a VPN, or a trusted private network.")
	}
	if g.insecure && g.caCertFile != "" {
		return fail(2, "--insecure and --ca-cert cannot be used together")
	}
	if len(connectionCACertPEM) > 0 && (g.insecure || g.caCertFile != "") {
		return fail(2, "a CA-bearing --connection-file cannot be combined with --insecure or --ca-cert")
	}
	var caCertPEM []byte
	var tlsOptions []server.Option
	switch {
	case len(connectionCACertPEM) > 0:
		caCertPEM = connectionCACertPEM
		tlsOptions = append(tlsOptions, server.WithExclusiveCACertPEM(caCertPEM))
	case g.insecure:
		fmt.Fprintln(os.Stderr, "Warning: --insecure disables TLS certificate verification. Use only on a trusted private network.")
		tlsOptions = append(tlsOptions, server.WithInsecureSkipVerify())
	case g.caCertFile != "":
		caCertPEM, err = readCACertFile(g.caCertFile)
		if err != nil {
			return err
		}
		tlsOptions = append(tlsOptions, server.WithCACertPEM(caCertPEM))
	}
	databaseID := identity.DatabaseID(token, password)
	client, err := server.New(normalized, token, databaseID, version+" ("+runtime.GOOS+"/"+runtime.GOARCH+")", tlsOptions...)
	if err != nil {
		return fail(2, "invalid server configuration: %v", err)
	}
	healthCtx, healthCancel := context.WithTimeout(context.Background(), 30*time.Second)
	_, healthErr := client.Health(healthCtx)
	healthCancel()
	if healthErr != nil && len(tlsOptions) == 0 && !*nonInteractive && isCertificateTrustError(healthErr) {
		fetchCtx, fetchCancel := context.WithTimeout(context.Background(), 15*time.Second)
		trustedPEM, promptErr := promptTrustCertificate(fetchCtx, normalized)
		fetchCancel()
		if promptErr != nil {
			return promptErr
		}
		if len(trustedPEM) > 0 {
			caCertPEM = trustedPEM
			tlsOptions = append(tlsOptions, server.WithCACertPEM(caCertPEM))
			client, err = server.New(normalized, token, databaseID, version+" ("+runtime.GOOS+"/"+runtime.GOARCH+")", tlsOptions...)
			if err != nil {
				return fail(2, "invalid server configuration: %v", err)
			}
			retryCtx, retryCancel := context.WithTimeout(context.Background(), 30*time.Second)
			_, healthErr = client.Health(retryCtx)
			retryCancel()
			if healthErr == nil && !g.quiet {
				fmt.Fprintln(os.Stderr, "Certificate trusted; it will be remembered for this server.")
			}
		}
	}
	if healthErr != nil {
		return mapRuntimeError("server health check failed", healthErr)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	exists := true
	validated := false
	download, err := client.Get(ctx)
	if errors.Is(err, server.ErrNotFound) {
		exists = false
	} else if err != nil {
		return mapRuntimeError("database check failed", err)
	} else {
		if _, err = clipdb.Decode(download.Data, password, clipdb.DefaultLimits()); err != nil {
			return mapRuntimeError("database could not be opened", err)
		}
		validated = true
	}
	cfg := config.Default()
	cfg.Server = normalized
	cfg.TLSInsecure = g.insecure
	cfg.CACertPEM = string(caCertPEM)
	if len(connectionCACertPEM) > 0 {
		authority, authorityErr := server.ParsePrivateAuthority(connectionCACertPEM, normalized)
		if authorityErr != nil {
			return fail(2, "invalid connection-file authority: %v", authorityErr)
		}
		cfg.CAExclusive = true
		cfg.CAHost = authority.Host
	}
	cfg.Machine = strings.TrimSpace(*machine)
	if cfg.Machine == "" {
		cfg.Machine = hostname()
	}
	protectedToken, err := config.ProtectForConfig(token)
	if err != nil {
		return fail(3, "cannot protect server token: %v", err)
	}
	cfg.TokenProtected = protectedToken
	switch strings.ToLower(*savePassword) {
	case "none":
		cfg.PasswordMode = "prompt"
	case "config":
		cfg.PasswordMode = "config"
		protected, protectErr := config.ProtectForConfig(password)
		if protectErr != nil {
			return fail(3, "cannot protect history password: %v", protectErr)
		}
		cfg.PasswordProtected = protected
	default:
		return fail(2, "--save-password must be none or config")
	}
	if err = config.Save(path, cfg); err != nil {
		return fail(3, "cannot save configuration: %v", err)
	}
	if g.json {
		return writeJSON(map[string]any{"server": normalized, "bucket_fingerprint": fingerprint(databaseID), "bucket_exists": exists, "password_validated": validated, "config_path": path})
	}
	fmt.Fprintf(os.Stderr, "Clipman CLI configured at %s.\n", path)
	if !exists {
		fmt.Fprintln(os.Stderr, "No database exists for this token/password combination. The password cannot be validated until this bucket contains data.")
	}
	return nil
}

// shouldAskWhereToSave reports whether init should ask where the settings
// belong. It stays quiet whenever the location has already been decided —
// by --config, CLIPMAN_CONFIG, or CLIPMAN_HOME — because asking after the
// user has named a location invites contradicting themselves.
func shouldAskWhereToSave(g globals, nonInteractive bool) bool {
	if nonInteractive || g.configPath != "" {
		return false
	}
	if os.Getenv("CLIPMAN_CONFIG") != "" || os.Getenv("CLIPMAN_HOME") != "" {
		return false
	}
	return platform.IsInteractive()
}

func runStatus(ctx *appContext, args []string) error {
	fs := newFlagSet("status")
	addOutputFlags(fs, &ctx.globals)
	refresh := fs.Bool("refresh", false, "download and validate the database")
	if err := parseCommandFlags(fs, "status", args); err != nil {
		return err
	}
	callCtx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	health, err := ctx.client.Health(callCtx)
	if err != nil {
		return mapRuntimeError("server is unavailable", err)
	}
	exists := true
	metadata, err := ctx.client.Head(callCtx)
	if errors.Is(err, server.ErrNotFound) {
		exists = false
		err = nil
	}
	if err != nil {
		return mapRuntimeError("database status failed", err)
	}
	// entries stays null in JSON unless --refresh actually counted them, so a
	// consumer cannot mistake "not counted" for a real count.
	var entries any
	if *refresh && exists {
		state, readErr := ctx.engine.Read(callCtx)
		if readErr != nil {
			return mapRuntimeError("database validation failed", readErr)
		}
		entries = len(state.Database.Entries)
	}
	result := map[string]any{"config_path": ctx.configPath, "server": ctx.client.BaseURL, "bucket_fingerprint": fingerprint(ctx.databaseID), "database_exists": exists, "revision": metadata.Revision, "length": metadata.Length, "entries": entries, "health": health, "interface": ctx.config.Renderer}
	if ctx.globals.json {
		return writeJSON(result)
	}
	// The configuration path leads, because with several profiles in play the
	// first question is which one this command is using.
	// The interface is reported here because it is the one question an
	// interactive session cannot answer for you: it names which of the two
	// browsers `menu` will open, from outside either of them.
	if _, err = fmt.Printf("Configuration: %s\nServer: %s\nDatabase: %s\nInterface: %s\n", ctx.configPath, ctx.client.BaseURL, map[bool]string{true: "available", false: "not yet created"}[exists], ctx.config.Renderer); err != nil {
		return fail(1, "cannot write output: %v", err)
	}
	if exists {
		if _, err = fmt.Printf("Revision: %s\nSize: %d bytes\n", metadata.Revision, metadata.Length); err != nil {
			return fail(1, "cannot write output: %v", err)
		}
	}
	if entries != nil {
		if _, err = fmt.Printf("Entries: %d\n", entries); err != nil {
			return fail(1, "cannot write output: %v", err)
		}
	}
	return nil
}

func runSync(ctx *appContext, args []string) error {
	fs := newFlagSet("sync")
	addOutputFlags(fs, &ctx.globals)
	if err := parseCommandFlags(fs, "sync", args); err != nil {
		return err
	}
	if len(fs.Args()) > 0 {
		return fail(2, "sync takes no positional arguments")
	}
	callCtx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	state, err := ctx.engine.Read(callCtx)
	if err != nil {
		return mapRuntimeError("sync failed", err)
	}
	if ctx.globals.json {
		return writeJSON(map[string]any{"revision": state.Revision, "database_exists": state.Exists, "entries": len(state.Database.Entries), "uploaded": false})
	}
	if !ctx.globals.quiet {
		// An absent database is not an empty history: it usually means the
		// history password or token differs from the one that holds the data,
		// so saying "history is current" here would hide a typed password.
		if !state.Exists {
			fmt.Fprintln(os.Stderr, "No history exists on the server for this token and history password yet.")
		} else {
			fmt.Fprintf(os.Stderr, "History is current: %d entries.\n", len(state.Database.Entries))
		}
	}
	return nil
}

func runList(ctx *appContext, args []string) error {
	fs := newFlagSet("list")
	addOutputFlags(fs, &ctx.globals)
	count := fs.Int("n", 20, "maximum entries")
	all := fs.Bool("all", false, "list all entries")
	group := fs.String("group", "", "filter group")
	search := fs.String("search", "", "search name and text")
	kind := fs.String("kind", ctx.config.DefaultKind, "history, templates, or all")
	pinned := fs.Bool("pinned-first", ctx.config.PinnedFirst, "show pinned entries first")
	porcelain := fs.Bool("porcelain", false, "stable tab-separated output")
	if err := parseCommandFlags(fs, "list", args); err != nil {
		return err
	}
	state, err := readState(ctx)
	if err != nil {
		return err
	}
	parsedKind, err := operation.ParseKind(*kind)
	if err != nil {
		return fail(2, "%v", err)
	}
	entries := operation.View(state.Database, parsedKind, *pinned)
	filtered := entries[:0]
	for _, entry := range entries {
		if *group != "" && !strings.EqualFold(entry.Group, *group) {
			continue
		}
		if *search != "" && !strings.Contains(strings.ToLower(entry.Name+"\n"+entry.Text), strings.ToLower(*search)) {
			continue
		}
		filtered = append(filtered, entry)
	}
	entries = filtered
	if !*all && *count >= 0 && len(entries) > *count {
		entries = entries[:*count]
	}
	if ctx.globals.json {
		items := make([]map[string]any, 0, len(entries))
		for index, entry := range entries {
			items = append(items, output.EntryJSON(index, entry))
		}
		return writeJSON(items)
	}
	now := time.Now()
	for index, entry := range entries {
		row := output.ListRow(index, entry, now)
		if *porcelain {
			row = output.PorcelainRow(index, entry, now)
		}
		if _, err = fmt.Println(row); err != nil {
			return fail(1, "cannot write output: %v", err)
		}
	}
	return nil
}

func runGet(ctx *appContext, args []string) error {
	selector, kind, pinned, touch, newline, raw, err := parseGet(args, ctx.config, &ctx.globals)
	if err != nil {
		return err
	}
	state, err := readState(ctx)
	if err != nil {
		return err
	}
	entries := operation.View(state.Database, kind, pinned)
	entry, index, err := operation.Select(entries, selector)
	if err != nil {
		return selectionError(err)
	}
	if touch {
		result, mutErr := ctx.engine.Mutate(context.Background(), func(database *model.Database, now int64) (bool, any, error) {
			updated, e := operation.Touch(database, entry.ID, now)
			return e == nil, updated, e
		})
		if mutErr != nil {
			return mapRuntimeError("touch failed", mutErr)
		}
		entry = result.(model.Entry)
	}
	if ctx.globals.json {
		value := output.EntryJSON(index, entry)
		if entry.IsTemplate && !raw {
			value["ResolvedText"] = template.Resolve(entry.Text, time.Now())
		}
		return writeJSON(value)
	}
	text := entry.Text
	if entry.IsTemplate && !raw {
		text = template.Resolve(text, time.Now())
	}
	_, err = os.Stdout.Write([]byte(text))
	if err != nil {
		return fail(1, "cannot write clip text: %v", err)
	}
	if newline && !strings.HasSuffix(text, "\n") {
		_, err = os.Stdout.Write([]byte("\n"))
	}
	return err
}

func runPut(ctx *appContext, args []string) error {
	fs := newFlagSet("put")
	addOutputFlags(fs, &ctx.globals)
	file := fs.String("file", "", "read text from file")
	textValue := fs.String("text", "", "text to store")
	name := fs.String("name", "", "entry name")
	group := fs.String("group", "", "entry group")
	pin := fs.Bool("pin", false, "pin the entry")
	template := fs.Bool("template", false, "create a template entry")
	duplicate := fs.String("duplicate", "movetotop", "ignore, movetotop, or keep")
	if err := parseCommandFlags(fs, "put", args); err != nil {
		return err
	}
	switch strings.ToLower(strings.TrimSpace(*duplicate)) {
	case "ignore", "movetotop", "keep":
	default:
		return fail(2, "--duplicate must be ignore, movetotop, or keep")
	}
	if *file != "" && *textValue != "" {
		return fail(2, "--file and --text cannot be used together")
	}
	var data []byte
	var err error
	if *file != "" {
		data, err = os.ReadFile(*file)
	} else if *textValue != "" {
		data = []byte(*textValue)
	} else {
		data, err = io.ReadAll(io.LimitReader(os.Stdin, ctx.config.Limits.MaxTextBytes+1))
	}
	if err != nil {
		return fail(1, "cannot read input: %v", err)
	}
	if int64(len(data)) > ctx.config.Limits.MaxTextBytes {
		return fail(1, "input exceeds %d-byte limit", ctx.config.Limits.MaxTextBytes)
	}
	if len(data) == 0 {
		return fail(2, "clip text cannot be empty")
	}
	if !utf8.Valid(data) {
		return fail(1, "clip text is not valid UTF-8")
	}
	text := string(data)
	newID := merge.NewID()
	result, err := ctx.engine.Mutate(context.Background(), func(database *model.Database, now int64) (bool, any, error) {
		entry, outcome := operation.Put(database, text, *name, *group, ctx.config.Machine, *duplicate, newID, *pin, *template, now)
		return outcome != "ignored", map[string]any{"entry": entry, "outcome": outcome}, nil
	})
	if err != nil {
		return mapRuntimeError("put failed", err)
	}
	if ctx.globals.json {
		return writeJSON(result)
	}
	if !ctx.globals.quiet {
		value := result.(map[string]any)
		entry := value["entry"].(model.Entry)
		fmt.Fprintf(os.Stderr, "%s %s\n", value["outcome"], entry.ID)
	}
	return nil
}

func runRemove(ctx *appContext, args []string) error {
	fs := newFlagSet("rm")
	addOutputFlags(fs, &ctx.globals)
	id := fs.String("id", "", "exact entry ID")
	name := fs.String("name", "", "exact entry name")
	search := fs.String("search", "", "search entry text or name")
	kindValue := fs.String("kind", ctx.config.DefaultKind, "history, templates, or all")
	yes := fs.Bool("yes", false, "skip confirmation")
	caseSensitive := fs.Bool("case-sensitive", false, "case-sensitive name/search")
	if err := parseCommandFlags(fs, "rm", permuteArgs(fs, args)); err != nil {
		return err
	}
	selector, err := buildSelector(fs.Args(), *id, *name, *search, false, *caseSensitive)
	if err != nil {
		return err
	}
	state, err := readState(ctx)
	if err != nil {
		return err
	}
	parsedKind, err := operation.ParseKind(*kindValue)
	if err != nil {
		return fail(2, "%v", err)
	}
	entries := operation.View(state.Database, parsedKind, ctx.config.PinnedFirst)
	entry, index, err := operation.Select(entries, selector)
	if err != nil {
		return selectionError(err)
	}
	if !*yes {
		answer, askErr := promptLine(fmt.Sprintf("Delete entry %d (%s)? Type yes to confirm: ", index, output.Preview(entry)))
		if askErr != nil {
			return askErr
		}
		if !strings.EqualFold(strings.TrimSpace(answer), "yes") {
			return fail(2, "deletion cancelled")
		}
	}
	result, err := ctx.engine.Mutate(context.Background(), func(database *model.Database, now int64) (bool, any, error) {
		removed, e := operation.Delete(database, entry.ID, ctx.config.Machine, now)
		return e == nil, removed, e
	})
	if err != nil {
		return mapRuntimeError("delete failed", err)
	}
	removed := result.(model.Entry)
	if ctx.globals.json {
		return writeJSON(map[string]any{"id": removed.ID, "index": index, "kind": *kindValue})
	}
	if !ctx.globals.quiet {
		fmt.Fprintf(os.Stderr, "Deleted %s.\n", removed.ID)
	}
	return nil
}

// cliStore adapts the sync engine to the browsers' Store interface. Load is
// the only network read a browser performs unless the user asks to refresh, so
// a session costs one download rather than one per command.
//
// It is a pointer receiver for SetKind alone: the full-screen renderer can
// switch between history and templates, and the store has to follow.
type cliStore struct {
	ctx         *appContext
	kind        operation.Kind
	pinnedFirst bool
	// last is the database the most recent download produced, kept so switching
	// interfaces can hand it to the next one.
	last *model.Database
	// reuse, when set, is that database being handed over. Switching tears the
	// screen down before the new interface draws anything, and a download plus a
	// PBKDF2 decrypt in that gap is silence with nothing to explain it. It is
	// consumed once, so an explicit reload still asks the server.
	reuse *model.Database
}

func (s *cliStore) SetKind(kind operation.Kind) { s.kind = kind }

func (s *cliStore) Load(context.Context) ([]model.Entry, error) {
	if s.reuse != nil {
		database := *s.reuse
		s.reuse = nil
		// Re-derived rather than reused wholesale: the view is rebuilt for the
		// kind now in force, which Tab may have changed on the way out.
		return operation.View(database, s.kind, s.pinnedFirst), nil
	}
	state, err := readState(s.ctx)
	if err != nil {
		return nil, err
	}
	database := state.Database
	s.last = &database
	return operation.View(database, s.kind, s.pinnedFirst), nil
}

// handOver arms the next Load with what has already been downloaded.
func (s *cliStore) handOver() { s.reuse = s.last }

func (s *cliStore) Delete(callCtx context.Context, id string) error {
	_, err := s.ctx.engine.Mutate(callCtx, func(database *model.Database, now int64) (bool, any, error) {
		removed, deleteErr := operation.Delete(database, id, s.ctx.config.Machine, now)
		return deleteErr == nil, removed, deleteErr
	})
	if err != nil {
		return mapRuntimeError("delete failed", err)
	}
	return nil
}

func (s *cliStore) Create(callCtx context.Context, text, name string) (model.Entry, error) {
	// A clip typed into the browser belongs to the kind being browsed, so
	// adding one while viewing templates creates a template.
	isTemplate := s.kind == operation.Templates
	newID := merge.NewID()
	result, err := s.ctx.engine.Mutate(callCtx, func(database *model.Database, now int64) (bool, any, error) {
		entry, outcome := operation.Put(database, text, name, "", s.ctx.config.Machine, "movetotop", newID, false, isTemplate, now)
		return outcome != "ignored", entry, nil
	})
	if err != nil {
		return model.Entry{}, mapRuntimeError("add failed", err)
	}
	return result.(model.Entry), nil
}

// terminalConsole routes the browser's prompts and announcements to the
// controlling terminal, keeping them out of the payload stream.
type terminalConsole struct{}

func (terminalConsole) Say(text string) {
	console, err := platform.OpenConsoleOutput()
	if err != nil {
		fmt.Fprintln(os.Stderr, text)
		return
	}
	defer console.Close()
	fmt.Fprintln(console, text)
}

func (terminalConsole) ReadLine(prompt string) (string, error) { return promptLine(prompt) }

func runPick(ctx *appContext, args []string) error {
	options, err := parseInteractiveOptions(ctx, args, "pick")
	if err != nil {
		return err
	}
	if options.renderer == rendererTUI {
		return interactiveError(runTUI(options, true))
	}
	return interactiveError(options.lineBrowser().Pick(context.Background()))
}

func runMenu(ctx *appContext, args []string) error {
	if ctx.globals.json {
		return fail(2, "menu does not support JSON output")
	}
	options, err := parseInteractiveOptions(ctx, args, "menu")
	if err != nil {
		return err
	}
	return interactiveError(browseUntilDone(ctx, options))
}

// browseUntilDone runs the configured interface, and starts the other one when
// the user asks to switch.
//
// The loop turns only on a deliberate keystroke that has already been confirmed,
// so it cannot spin: nothing in here retries on its own, and a terminal that
// cannot run what was asked for stops the switch rather than repeating it.
func browseUntilDone(ctx *appContext, options interactiveOptions) error {
	for {
		var err error
		if options.renderer == rendererTUI {
			err = runTUI(options, false)
		} else {
			err = options.lineBrowser().Run(context.Background())
		}
		// A switch is not a failure; it is the only channel a browser has back
		// to its caller. Everything else, including success, ends the session.
		var request *handoff.Request
		if !errors.As(err, &request) {
			return err
		}
		options = switchTo(ctx, options, request)
	}
}

// switchTo prepares the other interface. Three things happen here, and each of
// them is what keeps a switch from costing the user something:
//
//   - the terminal is proven able to run what is being asked for before the
//     choice is committed, so an unusable one costs no session and no setting;
//   - the history already downloaded is handed to the next interface, because
//     the screen is torn down before the new one draws and a download in that
//     gap is silence with nothing to explain it;
//   - the preference is written to the configuration file, so the next run
//     starts where this one ended.
func switchTo(ctx *appContext, options interactiveOptions, request *handoff.Request) interactiveOptions {
	options.arrival = request
	options.kind = request.Kind
	options.store.SetKind(request.Kind)
	options.store.handOver()
	options.screen = nil

	if options.renderer == rendererTUI {
		options.renderer = rendererLine
		saveRenderer(ctx, "line")
		return options
	}
	// Created before the choice is saved. A terminal that cannot take a
	// full-screen interface must lose the user nothing: they stay where they
	// are, the configuration is untouched, and they are told why.
	screen, err := tcell.NewScreen()
	if err != nil {
		fmt.Fprintf(os.Stderr, "The full-screen interface is unavailable on this terminal (%v).\nStaying in the line interface.\n", err)
		return options
	}
	options.renderer = rendererTUI
	options.screen = screen
	saveRenderer(ctx, "tui")
	return options
}

// saveRenderer records the choice so the next run starts in the same interface.
//
// A failure to write is announced and then ignored. The user asked to move, not
// to save; refusing the move because a preference file could not be written
// would cost them the session over something they did not ask for.
func saveRenderer(ctx *appContext, name string) {
	updated := ctx.config
	updated.Renderer = name
	if err := config.Save(ctx.configPath, updated); err != nil {
		fmt.Fprintf(os.Stderr, "Switched, but the choice could not be saved: %v\nUse --renderer %s to make it permanent.\n", err, name)
		return
	}
	ctx.config = updated
}

// interactiveError maps a renderer's sentinel outcomes onto exit codes. Both
// renderers report the same conditions, so the mapping lives in one place.
func interactiveError(err error) error {
	switch {
	case err == nil:
		return nil
	case errors.Is(err, line.ErrCancelled), errors.Is(err, tui.ErrCancelled):
		return fail(2, "selection cancelled")
	case errors.Is(err, line.ErrNoEntries), errors.Is(err, tui.ErrNoEntries):
		return fail(6, "no matching entries")
	}
	return err
}

type rendererChoice int

const (
	rendererLine rendererChoice = iota
	rendererTUI
)

type interactiveOptions struct {
	ctx         *appContext
	store       *cliStore
	kind        operation.Kind
	renderer    rendererChoice
	pageSize    int
	pinnedFirst bool
	debugPath   string
	// arrival carries the user's place across a switch between interfaces.
	arrival *handoff.Request
	// screen, when set, is a terminal screen already proven to work. A switch
	// creates it up front so an unusable terminal is discovered before the
	// choice is committed, rather than after the session has been lost.
	screen tcell.Screen
}

func (o interactiveOptions) lineBrowser() *line.Browser {
	return &line.Browser{
		Store:       o.store,
		Console:     terminalConsole{},
		Stdout:      os.Stdout,
		PageSize:    o.pageSize,
		PinnedFirst: o.pinnedFirst,
		Now:         time.Now,
		Kind:        o.kind,
		Arrival:     o.arrival,
	}
}

// runTUI starts the full-screen renderer. A terminal that cannot run it is
// reported plainly, with the line renderer offered by name: silently falling
// back would change where output goes without the user asking.
func runTUI(options interactiveOptions, pickOnly bool) error {
	screen := options.screen
	if screen == nil {
		created, err := tcell.NewScreen()
		if err != nil {
			return fail(1, "the full-screen interface is unavailable on this terminal (%v); rerun with --renderer line", err)
		}
		screen = created
	}
	// Where the trace is going is announced before the screen is taken over,
	// so it is on the terminal before the interface starts and still in the
	// scrollback afterwards. Anything printed on the way out is discarded when
	// the screen is restored.
	if options.debugPath != "" {
		fmt.Fprintf(os.Stderr, "Writing a caret trace to %s\n", options.debugPath)
	}
	browser := &tui.Browser{
		Store: options.store, Screen: screen, Stdout: os.Stdout,
		PinnedFirst: options.pinnedFirst, Kind: options.kind,
		Now: time.Now, PickOnly: pickOnly, DebugPath: options.debugPath,
		Arrival: options.arrival,
	}
	err := browser.Run(context.Background())
	// A switch request travels back as an error and must reach the caller
	// untouched; wrapping it here would report a deliberate move as a failure.
	var switching *handoff.Request
	if errors.As(err, &switching) {
		return err
	}
	if err != nil && !errors.Is(err, tui.ErrCancelled) && !errors.Is(err, tui.ErrNoEntries) {
		var appErr appError
		if !errors.As(err, &appErr) {
			return fail(1, "%v; rerun with --renderer line if this terminal cannot run it", err)
		}
	}
	return err
}

// parseInteractiveOptions parses the options menu and pick share. For the line
// renderer -n is the page size and every entry stays reachable by paging; for
// pick, which offers one choice and exits, it bounds the whole list.
func parseInteractiveOptions(ctx *appContext, args []string, command string) (interactiveOptions, error) {
	fs := newFlagSet(command)
	count := fs.Int("n", 20, "entries announced at once")
	all := fs.Bool("all", false, "announce every entry without paging")
	kindValue := fs.String("kind", ctx.config.DefaultKind, "history, templates, or all")
	pinned := fs.Bool("pinned-first", ctx.config.PinnedFirst, "show pinned entries first")
	rendererValue := fs.String("renderer", ctx.config.Renderer, "line or tui")
	useTUI := fs.Bool("tui", false, "shorthand for --renderer tui")
	useLine := fs.Bool("line", false, "shorthand for --renderer line")
	debug := fs.Bool("debug", false, "write a caret trace beside this program")
	debugLog := fs.String("debug-log", "", "write the caret trace to this file")
	if err := parseCommandFlags(fs, command, args); err != nil {
		return interactiveOptions{}, err
	}
	if len(fs.Args()) != 0 {
		return interactiveOptions{}, fail(2, "%s takes no positional arguments", command)
	}
	if *useTUI && *useLine {
		return interactiveOptions{}, fail(2, "--tui and --line cannot be used together")
	}
	kind, err := operation.ParseKind(*kindValue)
	if err != nil {
		return interactiveOptions{}, fail(2, "%v", err)
	}
	renderer := rendererLine
	switch {
	case *useTUI:
		renderer = rendererTUI
	case *useLine:
		renderer = rendererLine
	default:
		switch strings.ToLower(strings.TrimSpace(*rendererValue)) {
		case "", "line":
			renderer = rendererLine
		case "tui":
			renderer = rendererTUI
		default:
			return interactiveOptions{}, fail(2, "--renderer must be line or tui")
		}
	}
	if !platform.IsInteractive() {
		return interactiveOptions{}, fail(2, "%s needs a controlling terminal", command)
	}
	pageSize := *count
	if *all || pageSize == 0 {
		pageSize = -1
	}
	return interactiveOptions{
		ctx:         ctx,
		store:       &cliStore{ctx: ctx, kind: kind, pinnedFirst: *pinned},
		kind:        kind,
		renderer:    renderer,
		pageSize:    pageSize,
		pinnedFirst: *pinned,
		debugPath:   debugTracePath(*debug, *debugLog),
	}, nil
}

// debugTracePath resolves where a caret trace should go. --debug-log names the
// file, --debug takes the default beside the program, and neither can be
// defeated by the difference between cmd and PowerShell quoting the way an
// environment variable can.
func debugTracePath(enabled bool, explicit string) string {
	if value := strings.TrimSpace(explicit); value != "" {
		if absolute, err := filepath.Abs(value); err == nil {
			return absolute
		}
		return value
	}
	if !enabled {
		return ""
	}
	return tui.DefaultDebugPath()
}

func parseGet(args []string, cfg config.Config, g *globals) (operation.Selector, operation.Kind, bool, bool, bool, bool, error) {
	fs := newFlagSet("get")
	addOutputFlags(fs, g)
	id := fs.String("id", "", "exact entry ID")
	name := fs.String("name", "", "exact entry name")
	search := fs.String("search", "", "search entry text or name")
	kind := fs.String("kind", cfg.DefaultKind, "history, templates, or all")
	first := fs.Bool("first", false, "use first ambiguous match")
	caseSensitive := fs.Bool("case-sensitive", false, "case-sensitive name/search")
	pinned := fs.Bool("pinned-first", cfg.PinnedFirst, "show pinned entries first")
	touch := fs.Bool("touch", false, "mark the entry used")
	newline := fs.Bool("newline", false, "ensure a final LF")
	raw := fs.Bool("raw", false, "do not resolve template variables")
	fs.BoolVar(newline, "n", false, "ensure a final LF")
	if err := parseCommandFlags(fs, "get", permuteArgs(fs, args)); err != nil {
		return operation.Selector{}, operation.History, false, false, false, false, err
	}
	parsedKind, err := operation.ParseKind(*kind)
	if err != nil {
		return operation.Selector{}, operation.History, false, false, false, false, fail(2, "%v", err)
	}
	selector, err := buildSelector(fs.Args(), *id, *name, *search, *first, *caseSensitive)
	return selector, parsedKind, *pinned, *touch, *newline, *raw, err
}
func buildSelector(args []string, id, name, search string, first, caseSensitive bool) (operation.Selector, error) {
	used := 0
	if id != "" {
		used++
	}
	if name != "" {
		used++
	}
	if search != "" {
		used++
	}
	var index *int
	if len(args) > 1 {
		return operation.Selector{}, fail(2, "only one index may be supplied")
	}
	if len(args) == 1 {
		value, err := strconv.Atoi(args[0])
		if err != nil || value < 0 {
			return operation.Selector{}, fail(2, "index must be a non-negative number")
		}
		index = &value
		used++
	}
	if used > 1 {
		return operation.Selector{}, fail(2, "index, --id, --name, and --search are mutually exclusive")
	}
	return operation.Selector{Index: index, ID: id, Name: name, Search: search, First: first, CaseSensitive: caseSensitive}, nil
}
func readState(ctx *appContext) (syncengine.State, error) {
	callCtx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	state, err := ctx.engine.Read(callCtx)
	if err != nil {
		return state, mapRuntimeError("history could not be loaded", err)
	}
	merge.Normalize(&state.Database, time.Now().UnixMilli())
	if state.Exists {
		verbosef(ctx.globals, "downloaded revision %s, %d entries", state.Revision, len(state.Database.Entries))
	} else {
		verbosef(ctx.globals, "no database exists for this token and history password")
	}
	return state, nil
}
func selectionError(err error) error {
	if strings.Contains(err.Error(), "ambiguous") {
		return fail(2, "%v; use an exact ID or index", err)
	}
	return fail(6, "%v", err)
}
func mapRuntimeError(prefix string, err error) error {
	switch {
	case errors.Is(err, server.ErrUnauthorized):
		return fail(3, "%s: %v", prefix, err)
	case errors.Is(err, server.ErrNotFound):
		return fail(6, "%s: %v", prefix, err)
	case errors.Is(err, clipdb.ErrPasswordRequired), errors.Is(err, clipdb.ErrPasswordOrData):
		return fail(5, "%s: %v", prefix, err)
	}
	if isNetworkFailure(err) {
		return fail(4, "%s: %v", prefix, err)
	}
	// Anything left is local: an encode, decode, merge, or normalization failure
	// that happened to surface through a call which also touches the network.
	// Reporting those as 4 told a script to retry something that retrying cannot
	// fix, and told a user the network was at fault when it was not.
	return fail(1, "%s: %v", prefix, err)
}

// isNetworkFailure reports whether err is the network's or the server's fault,
// which is what exit code 4 means. Everything it does not claim is local, and
// falls to 1.
func isNetworkFailure(err error) bool {
	// net.Error covers timeouts, refused connections, DNS failures, and the
	// *url.Error the HTTP client wraps its transport errors in — including TLS
	// handshake failures, which reach us through that wrapper.
	var netErr net.Error
	if errors.As(err, &netErr) {
		return true
	}
	// A TLS trust failure that arrives unwrapped is still a connection that
	// could not be established.
	if isCertificateTrustError(err) {
		return true
	}
	var statusErr *server.StatusError
	if errors.As(err, &statusErr) {
		return statusErr.Remote()
	}
	return false
}

func promptPassword(label string) (string, error) {
	console, err := platform.OpenConsole()
	if err != nil {
		return "", fail(2, "interactive terminal is unavailable")
	}
	defer console.Close()
	output, outputErr := platform.OpenConsoleOutput()
	if outputErr != nil {
		return "", fail(2, "interactive terminal output is unavailable")
	}
	defer output.Close()
	fmt.Fprint(output, label)
	value, err := term.ReadPassword(int(console.Fd()))
	fmt.Fprintln(output)
	if err != nil {
		return "", fail(2, "password input failed: %v", err)
	}
	return string(value), nil
}
func promptLine(label string) (string, error) {
	console, err := platform.OpenConsole()
	if err != nil {
		return "", fail(2, "interactive terminal is unavailable")
	}
	defer console.Close()
	output, outputErr := platform.OpenConsoleOutput()
	if outputErr != nil {
		return "", fail(2, "interactive terminal output is unavailable")
	}
	defer output.Close()
	fmt.Fprint(output, label)
	line, err := bufio.NewReader(console).ReadString('\n')
	if err != nil && err != io.EOF {
		return "", fail(2, "input failed: %v", err)
	}
	return strings.TrimRight(line, "\r\n"), nil
}
func promptYesNo(label string, defaultYes bool) (bool, error) {
	suffix := " [y/N]: "
	if defaultYes {
		suffix = " [Y/n]: "
	}
	for {
		line, err := promptLine(label + suffix)
		if err != nil {
			return false, err
		}
		switch strings.ToLower(strings.TrimSpace(line)) {
		case "":
			return defaultYes, nil
		case "y", "yes":
			return true, nil
		case "n", "no":
			return false, nil
		default:
			fmt.Fprintln(os.Stderr, "Please answer y or n.")
		}
	}
}
func hostname() string {
	value, err := os.Hostname()
	if err != nil || strings.TrimSpace(value) == "" {
		return runtime.GOOS
	}
	return value
}
func fingerprint(id string) string {
	if len(id) > 8 {
		return id[:8]
	}
	return id
}
func writeJSON(value any) error {
	encoder := json.NewEncoder(os.Stdout)
	encoder.SetEscapeHTML(false)
	return encoder.Encode(value)
}
func printUsage(out io.Writer) {
	fmt.Fprintln(out, "Clipman CLI - terminal access to Clipman text history\n\nUsage: clipman-cli [global options] <command> [options]\n\nCommands:\n  init     Configure a Clipman Server profile\n  status   Check server and history status\n  list     List text-history entries\n  get      Write one entry to standard output\n  put      Read UTF-8 text and add it to history\n  rm       Delete exactly one entry\n  pick     Select one entry and write it to standard output\n  menu     Browse history interactively; the default when no command is given\n  sync     Download and validate current history\n\nGlobal options:\n  --config PATH     Select a configuration file\n  --server URL      Override the configured server\n  --password VALUE  Supply the history password\n  --ca-cert FILE    Trust an additional PEM CA/certificate for a self-signed server\n  --insecure        Disable TLS certificate verification (use only on a trusted network)\n  --json            Emit structured JSON where supported\n  --quiet, -q       Suppress nonessential messages\n  --verbose         Write diagnostic messages to standard error\n  --version         Show version information")
}

func printCommandUsage(out io.Writer, command string) bool {
	usage := map[string]string{
		"init":   "Usage: clipman-cli [global options] init [--connection-file FILE | --token-file FILE | --token VALUE] [--save-password none|config] [--machine NAME] [--non-interactive] [--force] [--portable]\n  (use the global --ca-cert FILE or --insecure option before init to trust a self-signed server certificate)\n  (without --save-password, an interactive run asks whether to save the history password)\n  (--portable writes config.toml beside this executable; it is then used automatically by that copy)",
		"status": "Usage: clipman-cli [global options] status [--refresh] [--json]",
		"list":   "Usage: clipman-cli [global options] list [-n COUNT | --all] [--group NAME] [--search TEXT] [--kind history|templates|all] [--pinned-first] [--porcelain] [--json]",
		"get":    "Usage: clipman-cli [global options] get [INDEX | --id ID | --name NAME | --search TEXT] [--kind history|templates|all] [--first] [--touch] [--newline] [--raw] [--json]",
		"put":    "Usage: clipman-cli [global options] put [--file FILE | --text TEXT] [--name NAME] [--group NAME] [--pin] [--template] [--duplicate ignore|movetotop|keep] [--json]",
		"rm":     "Usage: clipman-cli [global options] rm [INDEX | --id ID | --name NAME | --search TEXT] [--kind history|templates|all] [--case-sensitive] [--yes] [--json]",
		"sync":   "Usage: clipman-cli [global options] sync [--json] [--quiet]",
		"pick":   "Usage: clipman-cli [global options] pick [-n COUNT | --all] [--kind history|templates|all] [--pinned-first] [--renderer line|tui | --tui | --line]\n  (-n sets how many entries are announced at once; n and p move between pages)",
		"menu":   "Usage: clipman-cli [global options] menu [-n COUNT | --all] [--kind history|templates|all] [--pinned-first] [--renderer line|tui | --tui | --line]\n  (-n sets the page size; every entry stays reachable by paging, and --all announces them at once)\n  (line renderer: NUMBER views, o NUMBER outputs, d NUMBER deletes, /TEXT searches, n and p page, a adds, r reloads, u switches interface, ? helps, q quits)\n  (full-screen renderer: arrows move, g goes to a number, Enter outputs, / filters, Tab switches kind, d deletes, r reloads, u switches interface, ? shows keys, q quits)\n  (--debug writes a caret trace beside this program; --debug-log FILE chooses where)",
		"help":   "Usage: clipman-cli help",
	}
	text, ok := usage[command]
	if !ok {
		return false
	}
	fmt.Fprintln(out, text)
	return true
}

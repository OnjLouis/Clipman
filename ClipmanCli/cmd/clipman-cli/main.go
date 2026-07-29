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
	"runtime"
	"strconv"
	"strings"
	"time"
	"unicode/utf8"

	"golang.org/x/term"

	"github.com/OnjLouis/Clipman/ClipmanCli/internal/clipdb"
	"github.com/OnjLouis/Clipman/ClipmanCli/internal/config"
	"github.com/OnjLouis/Clipman/ClipmanCli/internal/identity"
	"github.com/OnjLouis/Clipman/ClipmanCli/internal/merge"
	"github.com/OnjLouis/Clipman/ClipmanCli/internal/model"
	"github.com/OnjLouis/Clipman/ClipmanCli/internal/operation"
	"github.com/OnjLouis/Clipman/ClipmanCli/internal/platform"
	"github.com/OnjLouis/Clipman/ClipmanCli/internal/server"
	"github.com/OnjLouis/Clipman/ClipmanCli/internal/syncengine"
	"github.com/OnjLouis/Clipman/ClipmanCli/internal/template"
)

var version = "0.1.1-dev"

type appError struct {
	code int
	err  error
}

func (e appError) Error() string { return e.err.Error() }
func fail(code int, format string, args ...any) error {
	return appError{code: code, err: fmt.Errorf(format, args...)}
}

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
	if err == nil {
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

// tlsOptionsForGlobals resolves the TLS trust options to use for a connection,
// preferring explicit --insecure/--ca-cert global flags over whatever was
// persisted to the configuration file by `init`.
func tlsOptionsForGlobals(g globals, cfg config.Config) ([]server.Option, error) {
	if g.insecure && g.caCertFile != "" {
		return nil, fail(2, "--insecure and --ca-cert cannot be used together")
	}
	if g.insecure {
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
		return []server.Option{server.WithInsecureSkipVerify()}, nil
	}
	if cfg.CACertPEM != "" {
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
		return true
	}
	var unknownAuthority x509.UnknownAuthorityError
	if errors.As(err, &unknownAuthority) {
		return true
	}
	var hostnameErr x509.HostnameError
	if errors.As(err, &hostnameErr) {
		return true
	}
	var certInvalid x509.CertificateInvalidError
	if errors.As(err, &certInvalid) {
		return true
	}
	return false
}

// fetchServerCertificate connects to rawURL's host without verifying the
// certificate, purely to retrieve it for display in a trust prompt. It does
// not use the result to make the connection trusted.
func fetchServerCertificate(ctx context.Context, rawURL string) (*x509.Certificate, error) {
	parsed, err := url.Parse(rawURL)
	if err != nil {
		return nil, err
	}
	if parsed.Scheme != "https" {
		return nil, errors.New("server does not use HTTPS")
	}
	host := parsed.Host
	if !strings.Contains(host, ":") {
		host += ":443"
	}
	dialer := &tls.Dialer{NetDialer: &net.Dialer{Timeout: 8 * time.Second}, Config: &tls.Config{InsecureSkipVerify: true}}
	conn, err := dialer.DialContext(ctx, "tcp", host)
	if err != nil {
		return nil, err
	}
	defer conn.Close()
	state := conn.(*tls.Conn).ConnectionState()
	if len(state.PeerCertificates) == 0 {
		return nil, errors.New("server did not present a certificate")
	}
	return state.PeerCertificates[0], nil
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
	cert, err := fetchServerCertificate(ctx, rawURL)
	if err != nil {
		fmt.Fprintf(os.Stderr, "Could not retrieve the server certificate to display: %v\n", err)
		return nil, nil
	}
	fmt.Fprintln(os.Stderr, "The server's TLS certificate is not trusted.")
	fmt.Fprintf(os.Stderr, "  Subject: %s\n", cert.Subject)
	fmt.Fprintf(os.Stderr, "  Issuer: %s\n", cert.Issuer)
	fmt.Fprintf(os.Stderr, "  Valid: %s to %s\n", cert.NotBefore.Format("2006-01-02"), cert.NotAfter.Format("2006-01-02"))
	fmt.Fprintf(os.Stderr, "  SHA-256 fingerprint: %s\n", certificateFingerprintSHA256(cert))
	fmt.Fprintln(os.Stderr, "Compare this fingerprint with the one shown by the server administrator before trusting it.")
	trust, err := promptYesNo("Trust this certificate for this server", false)
	if err != nil {
		return nil, err
	}
	if !trust {
		return nil, nil
	}
	return pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: cert.Raw}), nil
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
	fs := flag.NewFlagSet("init", flag.ContinueOnError)
	fs.SetOutput(os.Stderr)
	addOutputFlags(fs, &g)
	tokenValue := fs.String("token", "", "server token (visible in process lists)")
	tokenFile := fs.String("token-file", "", "read server token from a file")
	connectionFile := fs.String("connection-file", "", "read server address and token from Clipman connection details")
	savePassword := fs.String("save-password", "none", "none or config")
	machine := fs.String("machine", "", "source machine name")
	nonInteractive := fs.Bool("non-interactive", false, "do not prompt")
	force := fs.Bool("force", false, "replace existing configuration")
	if err := fs.Parse(args); err != nil {
		return fail(2, "%v", err)
	}
	savePasswordExplicit := false
	fs.Visit(func(f *flag.Flag) {
		if f.Name == "save-password" {
			savePasswordExplicit = true
		}
	})
	path, err := platform.ConfigPath(g.configPath)
	if err != nil {
		return fail(3, "cannot locate configuration: %v", err)
	}
	if config.Exists(path) && !*force {
		return fail(2, "configuration already exists at %s; use --force to replace it", path)
	}
	serverURL := g.server
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
			*connectionFile = strings.TrimSpace(filePath)
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
		extractedServer, extractedToken := server.ConnectionDetails(string(connectionData))
		if serverURL == "" {
			serverURL = extractedServer
		}
		*tokenValue = extractedToken
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
	if server.IsInsecureRemoteURL(normalized) && !g.quiet {
		fmt.Fprintln(os.Stderr, "Warning: plain HTTP exposes the server token on the network. Use HTTPS, a VPN, or a trusted private network.")
	}
	if g.insecure && g.caCertFile != "" {
		return fail(2, "--insecure and --ca-cert cannot be used together")
	}
	var caCertPEM []byte
	var tlsOptions []server.Option
	switch {
	case g.insecure:
		if !g.quiet {
			fmt.Fprintln(os.Stderr, "Warning: --insecure disables TLS certificate verification. Use only on a trusted private network.")
		}
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

func runStatus(ctx *appContext, args []string) error {
	fs := flag.NewFlagSet("status", flag.ContinueOnError)
	fs.SetOutput(os.Stderr)
	addOutputFlags(fs, &ctx.globals)
	refresh := fs.Bool("refresh", false, "download and validate the database")
	if err := fs.Parse(args); err != nil {
		return fail(2, "%v", err)
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
	entries := -1
	if *refresh && exists {
		state, readErr := ctx.engine.Read(callCtx)
		if readErr != nil {
			return mapRuntimeError("database validation failed", readErr)
		}
		entries = len(state.Database.Entries)
	}
	result := map[string]any{"server": ctx.client.BaseURL, "bucket_fingerprint": fingerprint(ctx.databaseID), "database_exists": exists, "revision": metadata.Revision, "length": metadata.Length, "entries": entries, "health": health}
	if ctx.globals.json {
		return writeJSON(result)
	}
	if _, err = fmt.Printf("Server: %s\nDatabase: %s\n", ctx.client.BaseURL, map[bool]string{true: "available", false: "not yet created"}[exists]); err != nil {
		return fail(1, "cannot write output: %v", err)
	}
	if exists {
		if _, err = fmt.Printf("Revision: %s\nSize: %d bytes\n", metadata.Revision, metadata.Length); err != nil {
			return fail(1, "cannot write output: %v", err)
		}
	}
	if entries >= 0 {
		if _, err = fmt.Printf("Entries: %d\n", entries); err != nil {
			return fail(1, "cannot write output: %v", err)
		}
	}
	return nil
}

func runSync(ctx *appContext, args []string) error {
	fs := flag.NewFlagSet("sync", flag.ContinueOnError)
	fs.SetOutput(os.Stderr)
	addOutputFlags(fs, &ctx.globals)
	if err := fs.Parse(args); err != nil {
		return fail(2, "%v", err)
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
		fmt.Fprintf(os.Stderr, "History is current: %d entries.\n", len(state.Database.Entries))
	}
	return nil
}

func runList(ctx *appContext, args []string) error {
	fs := flag.NewFlagSet("list", flag.ContinueOnError)
	fs.SetOutput(os.Stderr)
	addOutputFlags(fs, &ctx.globals)
	count := fs.Int("n", 20, "maximum entries")
	all := fs.Bool("all", false, "list all entries")
	group := fs.String("group", "", "filter group")
	search := fs.String("search", "", "search name and text")
	kind := fs.String("kind", ctx.config.DefaultKind, "history, templates, or all")
	pinned := fs.Bool("pinned-first", ctx.config.PinnedFirst, "show pinned entries first")
	porcelain := fs.Bool("porcelain", false, "stable tab-separated output")
	if err := fs.Parse(args); err != nil {
		return fail(2, "%v", err)
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
			items = append(items, entryJSON(index, entry))
		}
		return writeJSON(items)
	}
	nowUnixMs := time.Now().UnixMilli()
	for index, entry := range entries {
		if *porcelain {
			if _, err = fmt.Printf("%d\t%s\t%d\t%s\t%s\t%s\n", index, entry.ID, nowUnixMs-entry.LastUsedUnixMs, escape(entry.SourceMachine), escape(entry.Name), escape(oneLine(entry.Text))); err != nil {
				return fail(1, "cannot write output: %v", err)
			}
		} else {
			flags := "--"
			if entry.Pinned {
				flags = "P-"
			}
			if entry.IsTemplate {
				flags = strings.Replace(flags, "-", "T", 1)
			}
			label := entry.Name
			if label == "" {
				label = oneLine(entry.Text)
			}
			if _, err = fmt.Printf("%d  %s  %s  %s  %s\n", index, flags, age(entry.LastUsedUnixMs), emptyDash(entry.SourceMachine), label); err != nil {
				return fail(1, "cannot write output: %v", err)
			}
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
		value := entryJSON(index, entry)
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
	fs := flag.NewFlagSet("put", flag.ContinueOnError)
	fs.SetOutput(os.Stderr)
	addOutputFlags(fs, &ctx.globals)
	file := fs.String("file", "", "read text from file")
	textValue := fs.String("text", "", "text to store")
	name := fs.String("name", "", "entry name")
	group := fs.String("group", "", "entry group")
	pin := fs.Bool("pin", false, "pin the entry")
	template := fs.Bool("template", false, "create a template entry")
	duplicate := fs.String("duplicate", "movetotop", "ignore, movetotop, or keep")
	if err := fs.Parse(args); err != nil {
		return fail(2, "%v", err)
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
	fs := flag.NewFlagSet("rm", flag.ContinueOnError)
	fs.SetOutput(os.Stderr)
	addOutputFlags(fs, &ctx.globals)
	id := fs.String("id", "", "exact entry ID")
	name := fs.String("name", "", "exact entry name")
	search := fs.String("search", "", "search entry text or name")
	kindValue := fs.String("kind", ctx.config.DefaultKind, "history, templates, or all")
	yes := fs.Bool("yes", false, "skip confirmation")
	caseSensitive := fs.Bool("case-sensitive", false, "case-sensitive name/search")
	if err := fs.Parse(args); err != nil {
		return fail(2, "%v", err)
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
		answer, askErr := promptLine(fmt.Sprintf("Delete entry %d (%s)? Type yes to confirm: ", index, preview(entry)))
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

func runPick(ctx *appContext, args []string) error {
	entries, err := interactiveEntries(ctx, args, "pick")
	if err != nil {
		return err
	}
	if len(entries) == 0 {
		return fail(6, "no matching entries")
	}
	console, err := platform.OpenConsoleOutput()
	if err != nil {
		return fail(2, "interactive terminal is unavailable")
	}
	printEntryLines(console, entries)
	console.Close()
	answer, err := promptLine("Select an entry number, or q to cancel: ")
	if err != nil {
		return err
	}
	if strings.EqualFold(strings.TrimSpace(answer), "q") {
		return fail(2, "selection cancelled")
	}
	index, err := strconv.Atoi(strings.TrimSpace(answer))
	if err != nil || index < 0 || index >= len(entries) {
		return fail(2, "selection must be a listed entry number")
	}
	text := entries[index].Text
	if entries[index].IsTemplate {
		text = template.Resolve(text, time.Now())
	}
	_, err = os.Stdout.Write([]byte(text))
	return err
}

func runMenu(ctx *appContext, args []string) error {
	if ctx.globals.json {
		return fail(2, "menu does not support JSON output")
	}
	for {
		entries, err := interactiveEntries(ctx, args, "menu")
		if err != nil {
			return err
		}
		console, err := platform.OpenConsoleOutput()
		if err != nil {
			return fail(2, "interactive terminal is unavailable")
		}
		fmt.Fprintln(console, "\nClipman history")
		printEntryLines(console, entries)
		console.Close()
		answer, err := promptLine("Command: number to view, o number to output, d number to delete, r to refresh, q to quit: ")
		if err != nil {
			return err
		}
		answer = strings.TrimSpace(answer)
		if strings.EqualFold(answer, "q") {
			return nil
		}
		if strings.EqualFold(answer, "r") {
			continue
		}
		action := "view"
		value := answer
		parts := strings.Fields(answer)
		if len(parts) == 2 {
			action = strings.ToLower(parts[0])
			value = parts[1]
		}
		index, conversionErr := strconv.Atoi(value)
		if conversionErr != nil || index < 0 || index >= len(entries) {
			writeConsoleLine("That command does not identify a listed entry.")
			continue
		}
		entry := entries[index]
		switch action {
		case "view":
			text := entry.Text
			if entry.IsTemplate {
				text = template.Resolve(text, time.Now())
			}
			writeConsoleLine("\n" + text + "\n")
		case "o":
			text := entry.Text
			if entry.IsTemplate {
				text = template.Resolve(text, time.Now())
			}
			_, err = os.Stdout.Write([]byte(text))
			return err
		case "d":
			confirmation, askErr := promptLine(fmt.Sprintf("Delete %s? Type yes to confirm: ", preview(entry)))
			if askErr != nil {
				return askErr
			}
			if !strings.EqualFold(strings.TrimSpace(confirmation), "yes") {
				writeConsoleLine("Deletion cancelled.")
				continue
			}
			_, err = ctx.engine.Mutate(context.Background(), func(database *model.Database, now int64) (bool, any, error) {
				removed, deleteErr := operation.Delete(database, entry.ID, ctx.config.Machine, now)
				return deleteErr == nil, removed, deleteErr
			})
			if err != nil {
				return mapRuntimeError("delete failed", err)
			}
			writeConsoleLine("Entry deleted.")
		default:
			writeConsoleLine("Unknown action. Use a number, o, d, r, or q.")
		}
	}
}

func interactiveEntries(ctx *appContext, args []string, command string) ([]model.Entry, error) {
	fs := flag.NewFlagSet(command, flag.ContinueOnError)
	fs.SetOutput(os.Stderr)
	count := fs.Int("n", 20, "maximum entries")
	all := fs.Bool("all", false, "show all entries")
	kindValue := fs.String("kind", ctx.config.DefaultKind, "history, templates, or all")
	pinned := fs.Bool("pinned-first", ctx.config.PinnedFirst, "show pinned entries first")
	if err := fs.Parse(args); err != nil {
		return nil, fail(2, "%v", err)
	}
	if len(fs.Args()) != 0 {
		return nil, fail(2, "%s takes no positional arguments", command)
	}
	kind, err := operation.ParseKind(*kindValue)
	if err != nil {
		return nil, fail(2, "%v", err)
	}
	state, err := readState(ctx)
	if err != nil {
		return nil, err
	}
	entries := operation.View(state.Database, kind, *pinned)
	if !*all && *count >= 0 && len(entries) > *count {
		entries = entries[:*count]
	}
	return entries, nil
}

func printEntryLines(out io.Writer, entries []model.Entry) {
	for index, entry := range entries {
		flags := ""
		if entry.Pinned {
			flags += " pinned"
		}
		if entry.IsTemplate {
			flags += " template"
		}
		label := preview(entry)
		fmt.Fprintf(out, "%d. %s;%s group: %s; device: %s; last used: %s\n", index, label, flags, emptyDash(entry.Group), emptyDash(entry.SourceMachine), time.UnixMilli(entry.LastUsedUnixMs).Format("2006-01-02 15:04:05"))
	}
}

func writeConsoleLine(value string) {
	console, err := platform.OpenConsoleOutput()
	if err != nil {
		fmt.Fprintln(os.Stderr, value)
		return
	}
	defer console.Close()
	fmt.Fprintln(console, value)
}

func parseGet(args []string, cfg config.Config, g *globals) (operation.Selector, operation.Kind, bool, bool, bool, bool, error) {
	fs := flag.NewFlagSet("get", flag.ContinueOnError)
	fs.SetOutput(os.Stderr)
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
	if err := fs.Parse(args); err != nil {
		return operation.Selector{}, operation.History, false, false, false, false, fail(2, "%v", err)
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
		if err != nil {
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
	var netErr interface{ Timeout() bool }
	if errors.As(err, &netErr) && netErr.Timeout() {
		return fail(4, "%s: %v", prefix, err)
	}
	return fail(4, "%s: %v", prefix, err)
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
		return false, fail(2, "please answer y or n")
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
func entryJSON(index int, entry model.Entry) map[string]any {
	return map[string]any{"Index": index, "Id": entry.ID, "Text": entry.Text, "Name": entry.Name, "Group": entry.Group, "SourceMachine": entry.SourceMachine, "CreatedUnixMs": entry.CreatedUnixMs, "LastUsedUnixMs": entry.LastUsedUnixMs, "Pinned": entry.Pinned, "IsTemplate": entry.IsTemplate, "ManualOrder": entry.ManualOrder}
}
func oneLine(value string) string {
	value = strings.ReplaceAll(value, "\r\n", " ")
	value = strings.ReplaceAll(value, "\n", " ")
	value = strings.ReplaceAll(value, "\r", " ")
	value = strings.TrimSpace(value)
	runes := []rune(value)
	if len(runes) > 80 {
		return string(runes[:77]) + "..."
	}
	return value
}
func preview(entry model.Entry) string {
	if entry.Name != "" {
		return entry.Name
	}
	return oneLine(entry.Text)
}
func age(unixMs int64) string {
	duration := time.Since(time.UnixMilli(unixMs))
	if duration < time.Minute {
		return "now"
	}
	if duration < time.Hour {
		return fmt.Sprintf("%dm", int(duration.Minutes()))
	}
	if duration < 24*time.Hour {
		return fmt.Sprintf("%dh", int(duration.Hours()))
	}
	return fmt.Sprintf("%dd", int(duration.Hours()/24))
}
func emptyDash(value string) string {
	if value == "" {
		return "-"
	}
	return value
}
func escape(value string) string {
	replacer := strings.NewReplacer("\\", "\\\\", "\t", "\\t", "\n", "\\n", "\r", "\\r")
	return replacer.Replace(value)
}
func printUsage(out io.Writer) {
	fmt.Fprintln(out, "Clipman CLI - terminal access to Clipman text history\n\nUsage: clipman-cli [global options] <command> [options]\n\nCommands:\n  init     Configure a Clipman Server profile\n  status   Check server and history status\n  list     List text-history entries\n  get      Write one entry to standard output\n  put      Read UTF-8 text and add it to history\n  rm       Delete exactly one entry\n  pick     Select one entry and write it to standard output\n  menu     Open the accessible line-based history manager\n  sync     Download and validate current history\n\nGlobal options:\n  --config PATH     Select a configuration file\n  --server URL      Override the configured server\n  --password VALUE  Supply the history password\n  --ca-cert FILE    Trust an additional PEM CA/certificate for a self-signed server\n  --insecure        Disable TLS certificate verification (use only on a trusted network)\n  --json            Emit structured JSON where supported\n  --quiet, -q       Suppress nonessential messages\n  --version         Show version information")
}

func printCommandUsage(out io.Writer, command string) bool {
	usage := map[string]string{
		"init":   "Usage: clipman-cli [global options] init [--connection-file FILE | --token-file FILE | --token VALUE] [--save-password none|config] [--machine NAME] [--non-interactive] [--force]\n  (use the global --ca-cert FILE or --insecure option before init to trust a self-signed server certificate)\n  (without --save-password, an interactive run asks whether to save the history password)",
		"status": "Usage: clipman-cli [global options] status [--refresh] [--json]",
		"list":   "Usage: clipman-cli [global options] list [-n COUNT | --all] [--group NAME] [--search TEXT] [--kind history|templates|all] [--pinned-first] [--porcelain] [--json]",
		"get":    "Usage: clipman-cli [global options] get [INDEX | --id ID | --name NAME | --search TEXT] [--kind history|templates|all] [--first] [--touch] [--newline] [--raw] [--json]",
		"put":    "Usage: clipman-cli [global options] put [--file FILE | --text TEXT] [--name NAME] [--group NAME] [--pin] [--template] [--duplicate ignore|movetotop|keep] [--json]",
		"rm":     "Usage: clipman-cli [global options] rm [INDEX | --id ID | --name NAME | --search TEXT] [--kind history|templates|all] [--case-sensitive] [--yes] [--json]",
		"sync":   "Usage: clipman-cli [global options] sync [--json] [--quiet]",
		"pick":   "Usage: clipman-cli [global options] pick [-n COUNT | --all] [--kind history|templates|all] [--pinned-first]",
		"menu":   "Usage: clipman-cli [global options] menu [-n COUNT | --all] [--kind history|templates|all] [--pinned-first]",
		"help":   "Usage: clipman-cli help",
	}
	text, ok := usage[command]
	if !ok {
		return false
	}
	fmt.Fprintln(out, text)
	return true
}

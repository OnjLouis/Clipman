package main

import (
	"context"
	"fmt"
	"os"
	"time"
	"unicode/utf8"

	"github.com/OnjLouis/Clipman/ClipmanCli/internal/agent"
	"github.com/OnjLouis/Clipman/ClipmanCli/internal/config"
	"github.com/OnjLouis/Clipman/ClipmanCli/internal/platform"
)

const agentRequestTimeout = 30 * time.Second

type agentRequest struct {
	command string
	query   agent.Query
	id      string
}

func runAgent(g globals, args []string) error {
	if len(args) == 0 {
		return fail(2, "use agent permissions, search or get; see agent --help")
	}
	if g.server != "" || g.password.set || g.insecure || g.caCertFile != "" || g.verbose {
		return fail(2, "agent commands use the selected profile without server, password, certificate or verbose overrides")
	}
	if args[0] == "permissions" {
		return runAgentPermissions(g, args[1:])
	}
	request, err := parseAgentRequest(args, time.Now())
	if err != nil {
		return err
	}
	path, err := platform.ConfigPath(g.configPath)
	if err != nil {
		return fail(3, "cannot locate configuration: %v", err)
	}
	cfg, err := config.Load(path)
	if err != nil {
		return fail(3, "cannot read configuration: %v", err)
	}
	if err := agentReadAllowed(cfg); err != nil {
		return err
	}
	// Never open a credential prompt in an unattended integration. The ordinary
	// CLI remains available for interactive setup and credential configuration.
	ctx, err := loadContextWithPrompt(g, false)
	if err != nil {
		return err
	}
	return executeAgentRead(ctx, request)
}

func runAgentPermissions(g globals, args []string) error {
	fs := newFlagSet("agent permissions")
	read := fs.String("read", "", "allow or deny agent history reads")
	yes := fs.Bool("yes", false, "acknowledge that returned clips may reach an AI provider")
	if err := parseCommandFlags(fs, "agent permissions", args); err != nil {
		return err
	}
	if len(fs.Args()) != 0 || (*read != "" && *read != "allow" && *read != "deny") {
		return fail(2, "permissions accepts --read allow or --read deny")
	}
	if *read == "allow" && !*yes {
		return fail(2, "ordinary history can contain sensitive information and returned clips may reach your AI provider; enabling reads requires --yes")
	}
	path, err := platform.ConfigPath(g.configPath)
	if err != nil {
		return fail(3, "cannot locate configuration: %v", err)
	}
	cfg, err := config.Load(path)
	if err != nil {
		return fail(3, "cannot read configuration: %v", err)
	}
	if *read != "" {
		cfg.AgentRead = *read == "allow"
		if err := config.Save(path, cfg); err != nil {
			return fail(3, "cannot save agent permission: %v", err)
		}
	}
	return writeJSON(map[string]any{"schema_version": 1, "read_allowed": cfg.AgentRead, "write_allowed": false})
}

func agentReadAllowed(cfg config.Config) error {
	if !cfg.AgentRead {
		return fail(3, "agent history reads are disabled for this profile")
	}
	if cfg.TLSInsecure {
		return fail(3, "agent history reads require TLS certificate verification; configure a trusted authority instead")
	}
	return nil
}

func parseAgentRequest(args []string, now time.Time) (agentRequest, error) {
	request := agentRequest{command: args[0]}
	fs := newFlagSet("agent " + request.command)
	switch request.command {
	case "search":
		text := fs.String("query", "", "required literal text search")
		from := fs.String("from", "", "first creation date, YYYY-MM-DD")
		through := fs.String("through", "", "last creation date, YYYY-MM-DD")
		group := fs.String("group", "", "exact group filter, ignoring case")
		device := fs.String("device", "", "exact device filter, ignoring case")
		limit := fs.Int("limit", agent.DefaultResults, "maximum results, 1 to 50")
		if err := parseCommandFlags(fs, "agent search", args[1:]); err != nil {
			return request, err
		}
		start, end, err := agent.DateRange(*from, *through, now)
		if err != nil {
			return request, fail(2, "%v", err)
		}
		request.query = agent.Query{Text: *text, Group: *group, Device: *device, From: start, Through: end, Limit: *limit}
		if err := request.query.Validate(); err != nil {
			return request, fail(2, "%v", err)
		}
	case "get":
		id := fs.String("id", "", "exact ID from a search result")
		if err := parseCommandFlags(fs, "agent get", args[1:]); err != nil {
			return request, err
		}
		request.id = *id
		if request.id == "" || len(request.id) > agent.MaxIDBytes || !utf8.ValidString(request.id) {
			return request, fail(2, "get requires an exact --id of at most 128 bytes")
		}
	default:
		return request, fail(2, "agent supports permissions, search and get only")
	}
	if len(fs.Args()) != 0 {
		return request, fail(2, "agent commands do not accept positional arguments")
	}
	return request, nil
}

func executeAgentRead(ctx *appContext, request agentRequest) error {
	if err := agentReadAllowed(ctx.config); err != nil {
		return err
	}
	callCtx, cancel := context.WithTimeout(context.Background(), agentRequestTimeout)
	defer cancel()
	view, err := ctx.engine.ReadViewReadOnly(callCtx, ctx.config.Machine)
	if err != nil {
		return mapRuntimeError("agent history read failed", err)
	}
	var response any
	switch request.command {
	case "search":
		result, err := agent.Search(view.View.Entries, request.query)
		if err != nil {
			return fail(2, "%v", err)
		}
		response = result
	case "get":
		entry, err := agent.Get(view.View.Entries, request.id)
		if err != nil {
			return fail(6, "%v", err)
		}
		response = map[string]any{"schema_version": 1, "freshness": "server", "content_trust": "untrusted_data", "entry": entry}
	default:
		return fail(2, "unsupported agent read")
	}
	data, err := agent.Encode(response)
	if err != nil {
		return fail(2, "%v", err)
	}
	if _, err := os.Stdout.Write(data); err != nil {
		return fmt.Errorf("cannot write agent response: %w", err)
	}
	return nil
}

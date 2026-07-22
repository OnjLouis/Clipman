package config

import (
	"bufio"
	"bytes"
	"errors"
	"fmt"
	"os"
	"strconv"
	"strings"

	"github.com/OnjLouis/Clipman/ClipmanCli/internal/platform"
)

type Limits struct{ MaxBlobBytes, MaxJSONBytes, MaxEntries, MaxTextBytes int64 }
type Config struct {
	Server, Token, TokenProtected, Machine, Renderer, DefaultKind, PasswordMode, Password, PasswordProtected string
	PinnedFirst                                                                                              bool
	Limits                                                                                                   Limits
}

func Default() Config {
	return Config{Renderer: "line", DefaultKind: "history", PasswordMode: "prompt", Limits: Limits{MaxBlobBytes: 64 << 20, MaxJSONBytes: 256 << 20, MaxEntries: 100000, MaxTextBytes: 64 << 20}}
}

func Load(path string) (Config, error) {
	result := Default()
	data, err := platform.ReadPrivate(path)
	if err != nil {
		return result, err
	}
	section := ""
	scanner := bufio.NewScanner(bytes.NewReader(data))
	line := 0
	for scanner.Scan() {
		line++
		text := strings.TrimSpace(scanner.Text())
		if text == "" || strings.HasPrefix(text, "#") {
			continue
		}
		if strings.HasPrefix(text, "[") && strings.HasSuffix(text, "]") {
			section = strings.TrimSpace(text[1 : len(text)-1])
			continue
		}
		parts := strings.SplitN(text, "=", 2)
		if len(parts) != 2 {
			return result, fmt.Errorf("invalid config line %d", line)
		}
		key := strings.TrimSpace(parts[0])
		raw := strings.TrimSpace(parts[1])
		if hash := commentIndex(raw); hash >= 0 {
			raw = strings.TrimSpace(raw[:hash])
		}
		if err := assign(&result, section, key, raw); err != nil {
			return result, fmt.Errorf("config line %d: %w", line, err)
		}
	}
	if err := scanner.Err(); err != nil {
		return result, err
	}
	if err := Validate(result); err != nil {
		return result, err
	}
	return result, nil
}

func Save(path string, value Config) error {
	if err := Validate(value); err != nil {
		return err
	}
	var out strings.Builder
	writeString := func(key, value string) { fmt.Fprintf(&out, "%s = %s\n", key, strconv.Quote(value)) }
	writeString("server", value.Server)
	if value.TokenProtected != "" {
		writeString("token_protected", value.TokenProtected)
	} else {
		writeString("token", value.Token)
	}
	writeString("machine", value.Machine)
	writeString("renderer", value.Renderer)
	fmt.Fprintf(&out, "pinned_first = %t\n", value.PinnedFirst)
	writeString("default_kind", value.DefaultKind)
	writeString("password_mode", strings.ToLower(strings.TrimSpace(value.PasswordMode)))
	if value.PasswordProtected != "" {
		writeString("password_protected", value.PasswordProtected)
	} else if strings.EqualFold(value.PasswordMode, "config") {
		writeString("password", value.Password)
	}
	out.WriteString("\n[limits]\n")
	fmt.Fprintf(&out, "max_blob_bytes = %d\nmax_json_bytes = %d\nmax_entries = %d\nmax_text_bytes = %d\n", value.Limits.MaxBlobBytes, value.Limits.MaxJSONBytes, value.Limits.MaxEntries, value.Limits.MaxTextBytes)
	return platform.SavePrivate(path, []byte(out.String()))
}

func (c Config) ResolvedToken() (string, error) {
	if c.TokenProtected != "" {
		value, err := platform.Unprotect(c.TokenProtected)
		return string(value), err
	}
	return c.Token, nil
}
func (c Config) ResolvedPassword() (string, bool, error) {
	switch strings.ToLower(strings.TrimSpace(c.PasswordMode)) {
	case "passwordless":
		return "", true, nil
	case "config":
		if c.PasswordProtected != "" {
			value, err := platform.Unprotect(c.PasswordProtected)
			return string(value), true, err
		}
		return c.Password, true, nil
	default:
		return "", false, nil
	}
}
func ProtectForConfig(value string) (string, error) { return platform.Protect([]byte(value)) }
func Exists(path string) bool                       { _, err := os.Stat(path); return err == nil }

func Validate(value Config) error {
	if value.Token != "" && value.TokenProtected != "" {
		return errors.New("configuration contains both token and token_protected")
	}
	if value.Password != "" && value.PasswordProtected != "" {
		return errors.New("configuration contains both password and password_protected")
	}
	if !strings.EqualFold(value.PasswordMode, "config") && (value.Password != "" || value.PasswordProtected != "") {
		return errors.New("saved password values require password_mode config")
	}
	switch strings.ToLower(strings.TrimSpace(value.Renderer)) {
	case "line":
	default:
		return errors.New("renderer must be line")
	}
	switch strings.ToLower(strings.TrimSpace(value.DefaultKind)) {
	case "history", "templates", "all":
	default:
		return errors.New("default_kind must be history, templates, or all")
	}
	switch strings.ToLower(strings.TrimSpace(value.PasswordMode)) {
	case "prompt", "config", "passwordless":
	default:
		return errors.New("password_mode must be prompt, config, or passwordless")
	}
	limits := []struct {
		name       string
		value, max int64
	}{
		{"max_blob_bytes", value.Limits.MaxBlobBytes, 1 << 30},
		{"max_json_bytes", value.Limits.MaxJSONBytes, 2 << 30},
		{"max_entries", value.Limits.MaxEntries, 1000000},
		{"max_text_bytes", value.Limits.MaxTextBytes, 256 << 20},
	}
	for _, limit := range limits {
		if limit.value <= 0 || limit.value > limit.max {
			return fmt.Errorf("%s must be between 1 and %d", limit.name, limit.max)
		}
	}
	return nil
}

func assign(c *Config, section, key, raw string) error {
	if section != "" && section != "limits" {
		return fmt.Errorf("unknown config section %q", section)
	}
	if section == "limits" {
		value, err := strconv.ParseInt(raw, 10, 64)
		if err != nil {
			return err
		}
		switch key {
		case "max_blob_bytes":
			c.Limits.MaxBlobBytes = value
		case "max_json_bytes":
			c.Limits.MaxJSONBytes = value
		case "max_entries":
			c.Limits.MaxEntries = value
		case "max_text_bytes":
			c.Limits.MaxTextBytes = value
		default:
			return fmt.Errorf("unknown limits key %q", key)
		}
		return nil
	}
	stringValue := func() (string, error) {
		value, err := strconv.Unquote(raw)
		if err != nil {
			return "", errors.New("strings must be quoted")
		}
		return value, nil
	}
	setString := func(target *string) error {
		value, err := stringValue()
		if err != nil {
			return err
		}
		*target = value
		return nil
	}
	switch key {
	case "server":
		return setString(&c.Server)
	case "token":
		return setString(&c.Token)
	case "token_protected":
		return setString(&c.TokenProtected)
	case "machine":
		return setString(&c.Machine)
	case "renderer":
		return setString(&c.Renderer)
	case "default_kind":
		return setString(&c.DefaultKind)
	case "password_mode":
		return setString(&c.PasswordMode)
	case "password":
		return setString(&c.Password)
	case "password_protected":
		return setString(&c.PasswordProtected)
	case "pinned_first":
		value, err := strconv.ParseBool(raw)
		if err != nil {
			return err
		}
		c.PinnedFirst = value
	default:
		return fmt.Errorf("unknown config key %q", key)
	}
	return nil
}
func commentIndex(value string) int {
	quoted := false
	escaped := false
	for index, r := range value {
		if escaped {
			escaped = false
			continue
		}
		if r == '\\' && quoted {
			escaped = true
			continue
		}
		if r == '"' {
			quoted = !quoted
			continue
		}
		if r == '#' && !quoted {
			return index
		}
	}
	return -1
}

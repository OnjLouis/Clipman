package main

import "testing"

func TestAssetFilenameAllowsOnlyFixedFiles(t *testing.T) {
	for path, want := range map[string]string{
		"/client.wasm": "client.wasm", "/wasm_exec.js": "wasm_exec.js", "/icon.png": "icon.png",
		"/../settings.json": "", "/client.wasm/../settings.json": "", "/%2e%2e/settings.json": "",
		"/client.wasm?token=x": "", "/client.wasm/": "", "//client.wasm": "", "": "",
	} {
		if got := assetFilename(path); got != want {
			t.Errorf("assetFilename(%q) = %q, want %q", path, got, want)
		}
	}
}

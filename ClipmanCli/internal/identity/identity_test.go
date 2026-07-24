package identity

import "testing"

func TestDatabaseIDMatchesWindows(t *testing.T) {
	tests := []struct{ token, password, want string }{
		{"test-token", "", ""},
		{" test-token ", "päss", "ShGLB0kQ00qrtqAM_rcw3MOSKf4M-D3X9VuDaLD5TA0"},
	}
	for _, test := range tests {
		if got := DatabaseID(test.token, test.password); got != test.want {
			t.Fatalf("DatabaseID(%q) = %q, want %q", test.password, got, test.want)
		}
	}
}

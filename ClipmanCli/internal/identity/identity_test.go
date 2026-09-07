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

func TestChannelDatabaseIDMatchesFixture(t *testing.T) {
	got := ChannelDatabaseID("example-token", "example-password", "work")
	want := "F0MZBlui50Vd37JVf-JcvOWvoHV71IDlQE5OnfVBKeA"
	if got != want {
		t.Fatalf("channel id = %q, want %q", got, want)
	}
	if got := ChannelDatabaseID("example-token", "example-password", "desktop only"); got != "02tgOt5QC_sWY2RmoI2pqII9MocLQ7-XIMHaSRVBE1o" {
		t.Fatalf("desktop only channel id = %q", got)
	}
	if ChannelDatabaseID("", "p", "work") != "" || ChannelDatabaseID("t", "", "work") != "" {
		t.Fatal("blank token or password must yield empty id")
	}
}

func TestSyncRulesDatabaseIDMatchesFixture(t *testing.T) {
	got := SyncRulesDatabaseID("example-token", "example-password")
	want := "j5Z6kOIWgsJMqS0IRzNJEq38aqJ-iA8e6yzyX0W71WQ"
	if got != want {
		t.Fatalf("rules id = %q, want %q", got, want)
	}
}

package template

import (
	"runtime"
	"strings"
	"testing"
	"time"
)

func TestResolveDateAndUnknownVariable(t *testing.T) {
	zone := time.FixedZone("BST", 3600)
	now := time.Date(2026, time.July, 22, 7, 5, 9, 0, zone)
	input := "{{year_full}}/{{month_num_padded}}/{{day_of_month_padded}} {{day_name_short}} {{hour_12_padded}}:{{minute_padded}} {{utc_offset}} {{unknown}}"
	want := "2026/07/22 Wed 07:05 +1:00 {{unknown}}"
	if got := Resolve(input, now); got != want {
		t.Fatalf("Resolve = %q, want %q", got, want)
	}
}

func TestResolveSystemVariables(t *testing.T) {
	value := Resolve("{{os_name}} {{os_version}} {{username}}", time.Now())
	if strings.Contains(value, "{{") {
		t.Fatalf("system variable remained unresolved: %q", value)
	}
	if strings.Contains(value, runtime.GOOS+"/"+runtime.GOARCH) {
		t.Fatalf("operating-system version must not be an architecture label: %q", value)
	}
}

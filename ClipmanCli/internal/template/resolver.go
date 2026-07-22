package template

import (
	"fmt"
	"os"
	"os/user"
	"regexp"
	"runtime"
	"strings"
	"time"

	"github.com/OnjLouis/Clipman/ClipmanCli/internal/platform"
)

var variablePattern = regexp.MustCompile(`\{\{([A-Za-z0-9_]+)\}\}`)

var monthFull = [...]string{"", "January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December"}
var monthShort = [...]string{"", "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"}
var dayFull = [...]string{"Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"}
var dayShort = [...]string{"Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"}

func Resolve(text string, now time.Time) string {
	if text == "" {
		return ""
	}
	return variablePattern.ReplaceAllStringFunc(text, func(match string) string {
		parts := variablePattern.FindStringSubmatch(match)
		if len(parts) != 2 {
			return match
		}
		value, ok := variable(parts[1], now)
		if !ok {
			return match
		}
		return value
	})
}

func variable(name string, now time.Time) (string, bool) {
	hour12 := now.Hour() % 12
	if hour12 == 0 {
		hour12 = 12
	}
	zoneName, offset := now.Zone()
	username := os.Getenv("USER")
	if current, err := user.Current(); err == nil && current.Username != "" {
		username = current.Username
	}
	switch strings.ToLower(strings.TrimSpace(name)) {
	case "year_full":
		return fmt.Sprintf("%04d", now.Year()), true
	case "year_short":
		return fmt.Sprintf("%02d", now.Year()%100), true
	case "month_name", "month_name_full":
		return monthFull[now.Month()], true
	case "month_name_short":
		return monthShort[now.Month()], true
	case "month_num":
		return fmt.Sprintf("%d", now.Month()), true
	case "month_num_padded":
		return fmt.Sprintf("%02d", now.Month()), true
	case "day_of_month":
		return fmt.Sprintf("%d", now.Day()), true
	case "day_of_month_padded":
		return fmt.Sprintf("%02d", now.Day()), true
	case "day_name_full":
		return dayFull[now.Weekday()], true
	case "day_name_short":
		return dayShort[now.Weekday()], true
	case "hour_24":
		return fmt.Sprintf("%d", now.Hour()), true
	case "hour_24_padded":
		return fmt.Sprintf("%02d", now.Hour()), true
	case "hour_12":
		return fmt.Sprintf("%d", hour12), true
	case "hour_12_padded":
		return fmt.Sprintf("%02d", hour12), true
	case "minute":
		return fmt.Sprintf("%d", now.Minute()), true
	case "minute_padded":
		return fmt.Sprintf("%02d", now.Minute()), true
	case "second":
		return fmt.Sprintf("%d", now.Second()), true
	case "second_padded":
		return fmt.Sprintf("%02d", now.Second()), true
	case "utc_offset":
		sign := "+"
		if offset < 0 {
			sign = "-"
			offset = -offset
		}
		return fmt.Sprintf("%s%d:%02d", sign, offset/3600, (offset%3600)/60), true
	case "time_zone", "time_zone_short":
		return zoneName, true
	case "os_name":
		return osName(), true
	case "os_version":
		return platform.OSVersion(), true
	case "username":
		return username, true
	default:
		return "", false
	}
}

func osName() string {
	switch runtime.GOOS {
	case "windows":
		return "Windows"
	case "darwin":
		return "macOS"
	case "linux":
		return "Linux"
	default:
		return runtime.GOOS
	}
}

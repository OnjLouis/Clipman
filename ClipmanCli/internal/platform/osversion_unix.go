//go:build !windows

package platform

import (
	"runtime"

	"golang.org/x/sys/unix"
)

func OSVersion() string {
	var info unix.Utsname
	if err := unix.Uname(&info); err != nil {
		return runtime.GOOS
	}
	result := make([]byte, 0, len(info.Release))
	for _, value := range info.Release {
		if value == 0 {
			break
		}
		result = append(result, byte(value))
	}
	if len(result) == 0 {
		return runtime.GOOS
	}
	return string(result)
}

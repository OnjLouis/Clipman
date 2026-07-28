//go:build windows

package platform

import (
	"fmt"
	"syscall"
	"unsafe"
)

type rtlOSVersionInfo struct {
	size        uint32
	major       uint32
	minor       uint32
	build       uint32
	platformID  uint32
	servicePack [128]uint16
}

var rtlGetVersion = syscall.NewLazyDLL("ntdll.dll").NewProc("RtlGetVersion")

func OSVersion() string {
	info := rtlOSVersionInfo{size: uint32(unsafe.Sizeof(rtlOSVersionInfo{}))}
	status, _, _ := rtlGetVersion.Call(uintptr(unsafe.Pointer(&info)))
	if status != 0 {
		return "Windows"
	}
	return fmt.Sprintf("%d.%d.%d", info.major, info.minor, info.build)
}

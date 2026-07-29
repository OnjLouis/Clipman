//go:build !windows

package platform

import "os"

func OpenConsole() (*os.File, error)       { return os.OpenFile("/dev/tty", os.O_RDWR, 0) }
func OpenConsoleOutput() (*os.File, error) { return os.OpenFile("/dev/tty", os.O_WRONLY, 0) }
func IsInteractive() bool {
	console, err := OpenConsole()
	if err != nil {
		return false
	}
	return console.Close() == nil
}

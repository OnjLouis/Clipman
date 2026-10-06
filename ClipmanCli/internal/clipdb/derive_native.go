//go:build !js

package clipdb

func acceleratedDerivation(password, salt []byte) []byte { return nil }

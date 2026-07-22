package identity

import (
	"crypto/hmac"
	"crypto/sha256"
	"encoding/base64"
	"strings"
)

const purpose = "Clipman.ServerDatabaseId.v1"
const noPassword = "<clipman-no-history-password>"

func DatabaseID(token, password string) string {
	token = strings.TrimSpace(token)
	if token == "" {
		return ""
	}
	component := password
	if component == "" {
		component = noPassword
	}
	key := sha256.Sum256([]byte(token))
	mac := hmac.New(sha256.New, key[:])
	_, _ = mac.Write([]byte(purpose + "\n" + component))
	return base64.RawURLEncoding.EncodeToString(mac.Sum(nil))
}

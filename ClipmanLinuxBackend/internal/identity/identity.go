package identity

import (
	"crypto/hmac"
	"crypto/sha256"
	"encoding/base64"
	"strings"
)

const purpose = "Clipman.ServerDatabaseId.v1"
const channelPurpose = "Clipman.ServerChannelId.v1"
const syncRulesPurpose = "Clipman.ServerSyncRulesId.v1"

func DatabaseID(token, password string) string {
	token = strings.TrimSpace(token)
	if token == "" || password == "" {
		return ""
	}
	key := sha256.Sum256([]byte(token))
	mac := hmac.New(sha256.New, key[:])
	_, _ = mac.Write([]byte(purpose + "\n" + password))
	return base64.RawURLEncoding.EncodeToString(mac.Sum(nil))
}

func ChannelDatabaseID(token, password, channelKey string) string {
	token = strings.TrimSpace(token)
	if token == "" || password == "" {
		return ""
	}
	key := sha256.Sum256([]byte(token))
	mac := hmac.New(sha256.New, key[:])
	_, _ = mac.Write([]byte(channelPurpose + "\n" + password + "\n" + channelKey))
	return base64.RawURLEncoding.EncodeToString(mac.Sum(nil))
}

func SyncRulesDatabaseID(token, password string) string {
	token = strings.TrimSpace(token)
	if token == "" || password == "" {
		return ""
	}
	key := sha256.Sum256([]byte(token))
	mac := hmac.New(sha256.New, key[:])
	_, _ = mac.Write([]byte(syncRulesPurpose + "\n" + password))
	return base64.RawURLEncoding.EncodeToString(mac.Sum(nil))
}

package clipdb

import (
	"bytes"
	"compress/gzip"
	"crypto/aes"
	"crypto/cipher"
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha1"
	"crypto/sha256"
	"encoding/binary"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"time"
	"unicode/utf8"

	"github.com/OnjLouis/Clipman/ClipmanCli/internal/model"
)

var compressedMagic = []byte("CLIPDB1")
var encryptedMagic = []byte("CLIPDB2")

const (
	DefaultMaxBlobBytes = 64 << 20
	DefaultMaxJSONBytes = 256 << 20
	DefaultMaxEntries   = 100000
	DefaultMaxTextBytes = 64 << 20
	DefaultMaxJSONDepth = 100
	iterations          = 150000
)

var ErrPasswordRequired = errors.New("history password required")
var ErrPasswordOrData = errors.New("history password is incorrect or the database is damaged")

type Limits struct {
	MaxBlobBytes int64
	MaxJSONBytes int64
	MaxEntries   int64
	MaxTextBytes int64
	MaxJSONDepth int
}

func DefaultLimits() Limits {
	return Limits{MaxBlobBytes: DefaultMaxBlobBytes, MaxJSONBytes: DefaultMaxJSONBytes, MaxEntries: DefaultMaxEntries, MaxTextBytes: DefaultMaxTextBytes, MaxJSONDepth: DefaultMaxJSONDepth}
}

func Decode(blob []byte, password string, limits Limits) (model.Database, error) {
	if limits.MaxBlobBytes <= 0 {
		limits.MaxBlobBytes = DefaultMaxBlobBytes
	}
	if limits.MaxJSONBytes <= 0 {
		limits.MaxJSONBytes = DefaultMaxJSONBytes
	}
	if limits.MaxEntries <= 0 {
		limits.MaxEntries = DefaultMaxEntries
	}
	if limits.MaxTextBytes <= 0 {
		limits.MaxTextBytes = DefaultMaxTextBytes
	}
	if limits.MaxJSONDepth <= 0 {
		limits.MaxJSONDepth = DefaultMaxJSONDepth
	}
	if int64(len(blob)) > limits.MaxBlobBytes {
		return model.Database{}, fmt.Errorf("database exceeds %d-byte limit", limits.MaxBlobBytes)
	}
	var compressed []byte
	switch {
	case bytes.HasPrefix(blob, encryptedMagic):
		if password == "" {
			return model.Database{}, ErrPasswordRequired
		}
		plain, err := decrypt(blob, password)
		if err != nil {
			return model.Database{}, err
		}
		compressed = plain
	case bytes.HasPrefix(blob, compressedMagic):
		compressed = blob[len(compressedMagic):]
	default:
		compressed = blob
	}
	jsonBytes, err := gunzipLimited(compressed, limits.MaxJSONBytes)
	if err != nil {
		return model.Database{}, fmt.Errorf("invalid Clipman database: %w", err)
	}
	jsonBytes = bytes.TrimPrefix(jsonBytes, []byte{0xEF, 0xBB, 0xBF})
	if !utf8.Valid(jsonBytes) {
		return model.Database{}, errors.New("invalid Clipman JSON: text is not valid UTF-8")
	}
	if err := checkJSONDepth(jsonBytes, limits.MaxJSONDepth); err != nil {
		return model.Database{}, err
	}
	decoder := json.NewDecoder(bytes.NewReader(jsonBytes))
	var database model.Database
	if err := decoder.Decode(&database); err != nil {
		return model.Database{}, fmt.Errorf("invalid Clipman JSON: %w", err)
	}
	var trailing any
	if err := decoder.Decode(&trailing); err != io.EOF {
		return model.Database{}, errors.New("invalid Clipman JSON: trailing data")
	}
	if int64(len(database.Entries)) > limits.MaxEntries {
		return model.Database{}, fmt.Errorf("database exceeds %d-entry limit", limits.MaxEntries)
	}
	if int64(len(database.Deleted)) > limits.MaxEntries {
		return model.Database{}, fmt.Errorf("database exceeds %d-tombstone limit", limits.MaxEntries)
	}
	for _, entry := range database.Entries {
		if int64(len(entry.Text)) > limits.MaxTextBytes {
			return model.Database{}, fmt.Errorf("entry %q exceeds %d-byte text limit", entry.ID, limits.MaxTextBytes)
		}
	}
	return database, nil
}

func Encode(database model.Database, password string, existing []byte) ([]byte, error) {
	jsonBytes, err := json.Marshal(database)
	if err != nil {
		return nil, err
	}
	compressed, err := gzipBytes(jsonBytes)
	if err != nil {
		return nil, err
	}
	if password == "" {
		return append(append([]byte(nil), compressedMagic...), compressed...), nil
	}
	var salt []byte
	if len(existing) >= len(encryptedMagic)+1+16 && bytes.HasPrefix(existing, encryptedMagic) && existing[len(encryptedMagic)] == 1 {
		salt = append([]byte(nil), existing[len(encryptedMagic)+1:len(encryptedMagic)+1+16]...)
	}
	if len(salt) == 0 {
		salt = make([]byte, 16)
		if _, err = io.ReadFull(rand.Reader, salt); err != nil {
			return nil, err
		}
	}
	iv := make([]byte, 16)
	if _, err = io.ReadFull(rand.Reader, iv); err != nil {
		return nil, err
	}
	encKey, macKey := derive([]byte(password), salt)
	block, err := aes.NewCipher(encKey)
	if err != nil {
		return nil, err
	}
	padded := pkcs7Pad(compressed, aes.BlockSize)
	cipherText := make([]byte, len(padded))
	cipher.NewCBCEncrypter(block, iv).CryptBlocks(cipherText, padded)
	out := make([]byte, 0, len(encryptedMagic)+1+16+16+len(cipherText)+32)
	out = append(out, encryptedMagic...)
	out = append(out, 1)
	out = append(out, salt...)
	out = append(out, iv...)
	out = append(out, cipherText...)
	mac := hmac.New(sha256.New, macKey)
	_, _ = mac.Write(out)
	out = append(out, mac.Sum(nil)...)
	return out, nil
}

func decrypt(blob []byte, password string) ([]byte, error) {
	minimum := len(encryptedMagic) + 1 + 16 + 16 + aes.BlockSize + 32
	if len(blob) < minimum {
		return nil, ErrPasswordOrData
	}
	offset := len(encryptedMagic)
	if blob[offset] != 1 {
		return nil, fmt.Errorf("unsupported encrypted database version %d", blob[offset])
	}
	offset++
	salt := blob[offset : offset+16]
	offset += 16
	iv := blob[offset : offset+16]
	offset += 16
	cipherEnd := len(blob) - 32
	cipherText := blob[offset:cipherEnd]
	if len(cipherText) == 0 || len(cipherText)%aes.BlockSize != 0 {
		return nil, ErrPasswordOrData
	}
	encKey, macKey := derive([]byte(password), salt)
	mac := hmac.New(sha256.New, macKey)
	_, _ = mac.Write(blob[:cipherEnd])
	if !hmac.Equal(mac.Sum(nil), blob[cipherEnd:]) {
		return nil, ErrPasswordOrData
	}
	block, err := aes.NewCipher(encKey)
	if err != nil {
		return nil, err
	}
	plain := make([]byte, len(cipherText))
	cipher.NewCBCDecrypter(block, iv).CryptBlocks(plain, cipherText)
	return pkcs7Unpad(plain, aes.BlockSize)
}

func derive(password, salt []byte) ([]byte, []byte) {
	dk := pbkdf2(password, salt, iterations, 64)
	return dk[:32], dk[32:]
}
func pbkdf2(password, salt []byte, count, length int) []byte {
	hLen := sha1.Size
	numBlocks := (length + hLen - 1) / hLen
	out := make([]byte, 0, numBlocks*hLen)
	for block := 1; block <= numBlocks; block++ {
		mac := hmac.New(sha1.New, password)
		_, _ = mac.Write(salt)
		var counter [4]byte
		binary.BigEndian.PutUint32(counter[:], uint32(block))
		_, _ = mac.Write(counter[:])
		u := mac.Sum(nil)
		t := append([]byte(nil), u...)
		for i := 1; i < count; i++ {
			mac = hmac.New(sha1.New, password)
			_, _ = mac.Write(u)
			u = mac.Sum(nil)
			for j := range t {
				t[j] ^= u[j]
			}
		}
		out = append(out, t...)
	}
	return out[:length]
}
func gzipBytes(value []byte) ([]byte, error) {
	var out bytes.Buffer
	writer := gzip.NewWriter(&out)
	writer.Header.ModTime = time.Unix(0, 0)
	if _, err := writer.Write(value); err != nil {
		return nil, err
	}
	if err := writer.Close(); err != nil {
		return nil, err
	}
	return out.Bytes(), nil
}
func gunzipLimited(value []byte, limit int64) ([]byte, error) {
	reader, err := gzip.NewReader(bytes.NewReader(value))
	if err != nil {
		return nil, err
	}
	defer reader.Close()
	limited := io.LimitReader(reader, limit+1)
	out, err := io.ReadAll(limited)
	if err != nil {
		return nil, err
	}
	if int64(len(out)) > limit {
		return nil, fmt.Errorf("decompressed database exceeds %d-byte limit", limit)
	}
	return out, nil
}

func checkJSONDepth(value []byte, maximum int) error {
	decoder := json.NewDecoder(bytes.NewReader(value))
	depth := 0
	for {
		token, err := decoder.Token()
		if err == io.EOF {
			return nil
		}
		if err != nil {
			return fmt.Errorf("invalid Clipman JSON: %w", err)
		}
		delimiter, ok := token.(json.Delim)
		if !ok {
			continue
		}
		switch delimiter {
		case '{', '[':
			depth++
			if depth > maximum {
				return fmt.Errorf("Clipman JSON exceeds nesting depth %d", maximum)
			}
		case '}', ']':
			depth--
		}
	}
}
func pkcs7Pad(value []byte, size int) []byte {
	padding := size - len(value)%size
	out := make([]byte, len(value)+padding)
	copy(out, value)
	for i := len(value); i < len(out); i++ {
		out[i] = byte(padding)
	}
	return out
}
func pkcs7Unpad(value []byte, size int) ([]byte, error) {
	if len(value) == 0 || len(value)%size != 0 {
		return nil, ErrPasswordOrData
	}
	padding := int(value[len(value)-1])
	if padding == 0 || padding > size || padding > len(value) {
		return nil, ErrPasswordOrData
	}
	for _, b := range value[len(value)-padding:] {
		if int(b) != padding {
			return nil, ErrPasswordOrData
		}
	}
	return value[:len(value)-padding], nil
}

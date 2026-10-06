//go:build js && wasm

package clipdb

import "syscall/js"

// WebCrypto uses the same PBKDF2 parameters and key bytes as the native codec.
// If unavailable, the existing Go implementation remains the compatibility path.
func acceleratedDerivation(password, salt []byte) (derived []byte) {
	defer func() {
		if recover() != nil {
			derived = nil
		}
	}()
	crypto := js.Global().Get("crypto")
	if crypto.IsUndefined() || crypto.Get("subtle").IsUndefined() {
		return nil
	}
	subtle := crypto.Get("subtle")
	passwordBytes := js.Global().Get("Uint8Array").New(len(password))
	js.CopyBytesToJS(passwordBytes, password)
	defer passwordBytes.Call("fill", 0)
	saltBytes := js.Global().Get("Uint8Array").New(len(salt))
	js.CopyBytesToJS(saltBytes, salt)
	key, ok := awaitCrypto(subtle.Call("importKey", "raw", passwordBytes, "PBKDF2", false, js.ValueOf([]any{"deriveBits"})))
	if !ok {
		return nil
	}
	parameters := js.ValueOf(map[string]any{"name": "PBKDF2", "hash": "SHA-1", "salt": saltBytes, "iterations": iterations})
	bits, ok := awaitCrypto(subtle.Call("deriveBits", parameters, key, 512))
	if !ok {
		return nil
	}
	array := js.Global().Get("Uint8Array").New(bits)
	defer array.Call("fill", 0)
	derived = make([]byte, 64)
	if js.CopyBytesToGo(derived, array) != len(derived) {
		return nil
	}
	return derived
}

func awaitCrypto(promise js.Value) (js.Value, bool) {
	type result struct {
		value js.Value
		ok    bool
	}
	settled := make(chan result, 1)
	success := js.FuncOf(func(this js.Value, args []js.Value) any { settled <- result{args[0], true}; return nil })
	failure := js.FuncOf(func(this js.Value, args []js.Value) any { settled <- result{}; return nil })
	defer success.Release()
	defer failure.Release()
	promise.Call("then", success, failure)
	answer := <-settled
	return answer.value, answer.ok
}

//go:build js && wasm

package main

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"sync/atomic"
	"syscall/js"
	"time"

	"github.com/OnjLouis/Clipman/ClipmanCli/internal/webclient"
)

type request struct {
	ID                                                                               int `json:"id"`
	Action, Token, Password, Device, Endpoint, Key, Text, Name, Query, EntryID, Area string
	Offset                                                                           int
}
type result struct {
	ID    int                     `json:"id"`
	Error string                  `json:"error,omitempty"`
	Page  *webclient.Page         `json:"page,omitempty"`
	Text  string                  `json:"text,omitempty"`
	Rich  *webclient.RichDocument `json:"rich,omitempty"`
}
type browserTransport struct{ key string }

func (t browserTransport) RoundTrip(r *http.Request) (*http.Response, error) {
	if t.key != "" {
		r.Header.Set("X-Clipman-Preview", t.key)
	} else {
		r.Header.Set("X-Clipman-Web", "1")
	}
	r.Header.Set("js.fetch:credentials", "omit")
	r.Header.Set("js.fetch:redirect", "error")
	return (&http.Transport{}).RoundTrip(r)
}

func main() {
	var session *webclient.Session
	var busy atomic.Bool
	dispatch := js.FuncOf(func(this js.Value, args []js.Value) any {
		if len(args) != 1 {
			return nil
		}
		var r request
		if json.Unmarshal([]byte(args[0].String()), &r) != nil {
			return nil
		}
		if !busy.CompareAndSwap(false, true) {
			return nil
		}
		go func() {
			defer busy.Store(false)
			ctx, cancel := context.WithTimeout(context.Background(), 45*time.Second)
			defer cancel()
			out := result{ID: r.ID}
			var err error
			switch r.Action {
			case "connect":
				if session != nil {
					session.Close()
					session = nil
				}
				session, err = webclient.Connect(ctx, r.Endpoint, r.Token, r.Password, r.Device, browserTransport{r.Key})
			case "refresh":
				if session == nil {
					err = errors.New("history is locked")
				} else {
					err = session.Refresh(ctx)
				}
			case "page":
				if session == nil {
					err = errors.New("history is locked")
				}
			case "copy":
				if session == nil {
					err = errors.New("history is locked")
				} else {
					out.Text, err = session.Copy(r.EntryID)
				}
			case "rich":
				if session == nil {
					err = errors.New("history is locked")
				} else {
					out.Rich, err = session.Rich(r.EntryID)
				}
			case "add":
				if session == nil {
					err = errors.New("history is locked")
				} else {
					err = session.Add(ctx, r.Text, r.Name)
				}
			default:
				err = errors.New("unsupported action")
			}
			if err != nil {
				out.Error = err.Error()
			} else if session != nil && r.Action != "copy" && r.Action != "rich" {
				page := session.PageForArea(r.Query, r.Offset, r.Area)
				out.Page = &page
			}
			data, _ := json.Marshal(out)
			js.Global().Call("clipmanResult", string(data))
		}()
		return nil
	})
	js.Global().Set("clipmanExecute", dispatch)
	js.Global().Call("clipmanReady")
	select {}
}

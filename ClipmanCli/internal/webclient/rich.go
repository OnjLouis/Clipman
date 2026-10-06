package webclient

import (
	"bytes"
	"encoding/base64"
	"encoding/json"
	"errors"
	"image"
	_ "image/jpeg"
	_ "image/png"
	"strings"
	"unicode/utf8"

	"github.com/OnjLouis/Clipman/ClipmanCli/internal/agent"
	"github.com/OnjLouis/Clipman/ClipmanCli/internal/model"
	"golang.org/x/net/html"
)

const MaxRichHTMLBytes = 768 * 1024
const maxRichRTFBytes = 1024 * 1024
const maxStoredImageBytes = 512 * 1024
const maxStoredImageDimension = 2048
const maxRichNodes = 4096

type RichDocument struct {
	Text    string `json:"text"`
	HTML    string `json:"html"`
	RTFOnly bool   `json:"rtfOnly"`
}

type richPayload struct{ HtmlFragment, RtfBase64 string }

func entryRichPayload(e model.Entry) *richPayload {
	if e.IsTemplate || e.ID == "" || len(e.ID) > agent.MaxIDBytes || !utf8.ValidString(e.ID) {
		return nil
	}
	raw := e.Extra["RichText"]
	if len(raw) > MaxRichHTMLBytes+base64.StdEncoding.EncodedLen(maxRichRTFBytes)+4096 {
		return nil
	}
	var payload richPayload
	if json.Unmarshal(raw, &payload) != nil || len(payload.HtmlFragment) > MaxRichHTMLBytes {
		return nil
	}
	if payload.HtmlFragment == "" && payload.RtfBase64 == "" {
		return nil
	}
	return &payload
}

func (s *Session) Rich(id string) (*RichDocument, error) {
	if s == nil || s.state == nil {
		return nil, errors.New("history is locked")
	}
	for _, e := range s.state.View.Entries {
		if e.ID != id {
			continue
		}
		payload := entryRichPayload(e)
		if payload == nil {
			break
		}
		if len(e.Text) > MaxClipBytes {
			return nil, errors.New("entry exceeds the preview's 1 MiB text limit")
		}
		fragment, err := boundedRichHTML(payload.HtmlFragment)
		if err != nil {
			return nil, err
		}
		return &RichDocument{Text: e.Text, HTML: fragment, RTFOnly: payload.HtmlFragment == ""}, nil
	}
	return nil, errors.New("rich entry is no longer available; refresh history")
}

// Only inspect image headers: never decode an untrusted image's pixels here.
func safeEmbeddedImage(src string) bool {
	meta, encoded, ok := strings.Cut(src, ",")
	if !ok || (meta != "data:image/png;base64" && meta != "data:image/jpeg;base64") || len(encoded) > base64.StdEncoding.EncodedLen(maxStoredImageBytes) {
		return false
	}
	data, err := base64.StdEncoding.DecodeString(encoded)
	if err != nil || len(data) > maxStoredImageBytes {
		return false
	}
	config, format, err := image.DecodeConfig(bytes.NewReader(data))
	return err == nil && "data:image/"+format+";base64" == meta && config.Width > 0 && config.Height > 0 && config.Width <= maxStoredImageDimension && config.Height <= maxStoredImageDimension
}

func boundedRichHTML(fragment string) (string, error) {
	if len(fragment) > MaxRichHTMLBytes {
		return "", errors.New("formatted content exceeds the 768 KiB preview limit")
	}
	if fragment == "" {
		return "", nil
	}
	doc, err := html.Parse(strings.NewReader(fragment))
	if err != nil {
		return "", errors.New("formatted content could not be parsed")
	}
	count := 0
	var body *html.Node
	for node := range doc.Descendants() {
		count++
		if count > maxRichNodes {
			return "", errors.New("formatted content is too complex to preview")
		}
		if node.Type == html.ElementNode && node.Data == "body" {
			body = node
		}
		if node.Type != html.ElementNode || node.Data != "img" {
			continue
		}
		attrs := node.Attr[:0]
		for _, attr := range node.Attr {
			if attr.Key == "srcset" || attr.Key == "src" && !safeEmbeddedImage(attr.Val) {
				continue
			}
			attrs = append(attrs, attr)
		}
		node.Attr = attrs
	}
	if body == nil {
		return "", errors.New("formatted content has no readable body")
	}
	var output strings.Builder
	for node := body.FirstChild; node != nil; node = node.NextSibling {
		if err := html.Render(&output, node); err != nil {
			return "", err
		}
		if output.Len() > MaxRichHTMLBytes {
			return "", errors.New("formatted content exceeds the preview limit")
		}
	}
	return output.String(), nil
}

package migration

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"regexp"
	"strconv"
	"strings"
)

var unknownField = regexp.MustCompile(`^json: unknown field "(.*)"$`)

// ParseStrictBatch decodes a single normalized service intent object or an array of them. Unknown
// fields are rejected (DisallowUnknownFields), and so is anything after the value. Each parsed
// input is folded on entry (foldOnEntry, input.go) before this returns, so every validator sees
// constructs only. batch reports whether the input was an array, which decides
// whether causes are prefixed with input[i].
//
// A body that is not a JSON object or array is a *MalformedError; an object the strict decoder
// refuses (an unknown field, a wrong type) is a *ValidationError naming the property, collected
// across every item of the batch.
func ParseStrictBatch(data []byte) (inputs []ServiceInput, batch bool, err error) {
	trim := bytes.TrimSpace(data)
	if len(trim) == 0 {
		return nil, false, &MalformedError{Cause: "input: empty; expected a normalized service intent object or an array of them"}
	}
	switch trim[0] {
	case '{':
		var in ServiceInput
		if cause, malformed := strictDecode(trim, &in); cause != "" {
			if malformed {
				return nil, false, &MalformedError{Cause: cause}
			}
			return nil, false, &ValidationError{Causes: []string{cause}}
		}
		foldOnEntry(&in)
		return []ServiceInput{in}, false, nil
	case '[':
		var raws []json.RawMessage
		if err := json.Unmarshal(trim, &raws); err != nil {
			return nil, true, &MalformedError{Cause: "input: not valid JSON: " + err.Error()}
		}
		if len(raws) == 0 {
			return nil, true, &ValidationError{Causes: []string{"input: an empty array; at least one normalized service intent is required"}}
		}
		var causes []string
		out := make([]ServiceInput, 0, len(raws))
		for i, raw := range raws {
			r := bytes.TrimSpace(raw)
			if len(r) == 0 || r[0] != '{' {
				causes = append(causes, fmt.Sprintf("input[%d]: expected a normalized service intent object, got %s", i, string(r)))
				continue
			}
			var in ServiceInput
			if cause, _ := strictDecode(r, &in); cause != "" {
				causes = append(causes, fmt.Sprintf("input[%d].%s", i, cause))
				continue
			}
			foldOnEntry(&in)
			out = append(out, in)
		}
		if len(causes) > 0 {
			return nil, true, &ValidationError{Causes: causes}
		}
		return out, true, nil
	default:
		return nil, false, &MalformedError{Cause: "input: not a JSON object or array; expected a normalized service intent object or an array of them"}
	}
}

// strictDecode decodes one object. It returns "" on success, or a cause that starts with the
// offending property path; malformed is true when the bytes are not JSON at all.
func strictDecode(b []byte, v any) (cause string, malformed bool) {
	dec := json.NewDecoder(bytes.NewReader(b))
	dec.DisallowUnknownFields()
	err := dec.Decode(v)
	if err == nil {
		if _, extra := dec.Token(); extra != io.EOF {
			return "input: unexpected data after the JSON value", true
		}
		return "", false
	}
	var syn *json.SyntaxError
	var typ *json.UnmarshalTypeError
	switch {
	case errors.As(err, &syn):
		return fmt.Sprintf("input: not valid JSON at offset %d: %s", syn.Offset, syn.Error()), true
	case errors.Is(err, io.ErrUnexpectedEOF):
		return "input: not valid JSON: unexpected end of input", true
	case errors.As(err, &typ) && typ.Field == "acl" && typ.Value == "string":
		// An access list named instead of declared: a reference to a list held elsewhere.
		return aclReferenceCause(b), false
	case errors.As(err, &typ):
		path := jsonPath(typ.Field)
		return fmt.Sprintf("%s: expected %s, got JSON %s", path, jsonKind(typ.Type.Kind().String()), typ.Value), false
	}
	if m := unknownField.FindStringSubmatch(err.Error()); m != nil {
		return fmt.Sprintf("%s: unknown field %q; the normalized service intent does not carry it, and unknown fields are rejected, never ignored", m[1], m[1]), false
	}
	return "input: " + err.Error(), false
}

// jsonPath renders the decoder's dotted field path ("endpoints.0.vlan") as a property path
// ("endpoints[0].vlan").
func jsonPath(field string) string {
	if field == "" {
		return "input"
	}
	var b strings.Builder
	for i, seg := range strings.Split(field, ".") {
		if _, err := strconv.Atoi(seg); err == nil {
			b.WriteString("[" + seg + "]")
			continue
		}
		if i > 0 {
			b.WriteByte('.')
		}
		b.WriteString(seg)
	}
	return b.String()
}

func jsonKind(goKind string) string {
	switch goKind {
	case "int", "int64", "int32":
		return "an integer"
	case "string":
		return "a string"
	case "slice":
		return "an array"
	case "struct", "map", "ptr":
		return "an object"
	case "bool":
		return "a boolean"
	}
	return goKind
}

// aclReferenceCause is the refusal of an access list given by name (a JSON string) rather than
// declared inline (FR-040): a list belongs to exactly one service and is never a second named
// object with its own lifecycle.
func aclReferenceCause(b []byte) string {
	var probe struct {
		ACL json.RawMessage `json:"acl"`
	}
	name := "a name"
	if json.Unmarshal(b, &probe) == nil {
		var s string
		if json.Unmarshal(probe.ACL, &s) == nil {
			name = strconv.Quote(s)
		}
	}
	return fmt.Sprintf("acl: %s names an access list by reference; an access list belongs to exactly one service and cannot be referenced by another, and no named, separately managed list exists to point at — declare its stage, type and rules inline", name)
}

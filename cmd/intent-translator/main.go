// Command intent-translator is the translator sidecar of the deployer pod (T097;
// contracts/translator-api.md; FR-060, FR-065, FR-045, D-30, AD-41, AD-56): a thin HTTP wrapper over
// pkg/migration — the same strict-parse → validate → translate path the CLI calls, and no semantics
// of its own.
//
//	POST /v1/translate  a normalized service intent object or an array of them
//	                    200 {"manifests":[<Network>…],"yaml":"<the same objects as YAML>"}
//	                    422 {"error":"validation","causes":[…]}   all-or-nothing, nothing emitted
//	                    400 {"error":"malformed","causes":[…]}    not a JSON object or array
//	GET  /healthz       200 {"status":"ok"}
//
// It listens on 127.0.0.1:8090 — pod-local only: no Service and no NetworkPolicy allowance exist for
// it (the deployer reaches it at TRANSLATOR_URL=http://127.0.0.1:8090). --listen or
// TRANSLATOR_LISTEN_ADDR overrides the address (tests). The site inventory and the fabric ASN come
// from FABRIC_NODE_MAP, FABRIC_PORT_MAP and FABRIC_ASN (pkg/migration/site.go); a value that does not
// parse refuses to start. It imports no cluster client: it reads and writes JSON and YAML only.
// Logging is NFR-014's one JSON object per line on stdout (internal/telemetry/jsonlog).
package main

import (
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"os/signal"
	"regexp"
	"syscall"
	"time"

	"github.com/go-logr/logr"

	"github.com/mairp/agentic-netops-srl/internal/telemetry/jsonlog"
	"github.com/mairp/agentic-netops-srl/pkg/migration"
)

const (
	component   = "intent-translator"
	defaultAddr = "127.0.0.1:8090"
	// EnvListenAddr overrides the listen address.
	EnvListenAddr = "TRANSLATOR_LISTEN_ADDR"
	// maxBody bounds a request: a batch of normalized intents is a few kilobytes.
	maxBody = 1 << 20
)

func main() { os.Exit(run(context.Background(), os.Args[1:], os.Stdout)) }

func run(ctx context.Context, args []string, stdout io.Writer) int {
	log := jsonlog.NewLogger(stdout, component, false, nil)
	fs := flag.NewFlagSet(component, flag.ContinueOnError)
	fs.SetOutput(io.Discard)
	def := defaultAddr
	if v := os.Getenv(EnvListenAddr); v != "" {
		def = v
	}
	addr := fs.String("listen", def, "listen address (loopback only in the pod)")
	if err := fs.Parse(args); err != nil || fs.NArg() > 0 {
		log.Error(fmt.Errorf("usage: intent-translator [--listen host:port]: %v", err), "intent-translator refused to start")
		return 2
	}
	opt, err := migration.OptionsFromEnv()
	if err != nil {
		log.Error(err, "intent-translator refused to start: the site inventory in the environment does not parse")
		return 2
	}
	ln, err := net.Listen("tcp", *addr)
	if err != nil {
		log.Error(err, "intent-translator refused to start: cannot listen", "address", *addr)
		return 1
	}
	srv := &http.Server{
		Handler:           newHandler(opt, log),
		ReadHeaderTimeout: 5 * time.Second,
		ReadTimeout:       30 * time.Second,
		WriteTimeout:      30 * time.Second,
		IdleTimeout:       120 * time.Second,
	}
	sites := "none (node and port unchecked)"
	if opt.Site != nil {
		sites = fmt.Sprintf("%d node(s)", len(opt.Site.Roles))
	}
	log.Info("intent-translator listening", "address", ln.Addr().String(), "siteInventory", sites,
		"fabricASN", opt.FabricASN, "translatorVersion", migration.TranslatorVersion)

	ctx, stop := signal.NotifyContext(ctx, syscall.SIGTERM, syscall.SIGINT)
	defer stop()
	errc := make(chan error, 1)
	go func() { errc <- srv.Serve(ln) }()
	select {
	case err := <-errc:
		log.Error(err, "intent-translator stopped")
		return 1
	case <-ctx.Done():
		shut, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer cancel()
		_ = srv.Shutdown(shut)
		log.Info("intent-translator stopped on signal")
		return 0
	}
}

// CorrelationHeader carries the request's correlation id — the deployer's trace id — so the
// sidecar's lines for a request carry it (NFR-014). A value that is not 32 lower-case hex digits
// is ignored rather than logged.
const CorrelationHeader = "X-Correlation-Id"

var correlationID = regexp.MustCompile(`^[0-9a-f]{32}$`)

// translateResponse is the 200 body.
type translateResponse struct {
	Manifests []json.RawMessage `json:"manifests"`
	YAML      string            `json:"yaml"`
}

func newHandler(opt migration.Options, log logr.Logger) http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("/healthz", func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodGet && r.Method != http.MethodHead {
			w.Header().Set("Allow", "GET, HEAD")
			writeJSON(w, http.StatusMethodNotAllowed, migration.StructuredError{Error: "method", Causes: []string{"/healthz answers GET"}})
			return
		}
		writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
	})
	mux.HandleFunc("/v1/translate", func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()
		log := log
		if cid := r.Header.Get(CorrelationHeader); correlationID.MatchString(cid) {
			// every line of a request carries its correlation id (NFR-014, data-model.md §27)
			log = log.WithValues("correlation_id", cid)
		}
		if r.Method != http.MethodPost {
			w.Header().Set("Allow", "POST")
			writeJSON(w, http.StatusMethodNotAllowed, migration.StructuredError{Error: "method", Causes: []string{"/v1/translate answers POST with a normalized service intent"}})
			return
		}
		body, err := io.ReadAll(http.MaxBytesReader(w, r.Body, maxBody))
		if err != nil {
			var tooBig *http.MaxBytesError
			cause := "input: the request body could not be read: " + err.Error()
			if errors.As(err, &tooBig) {
				cause = fmt.Sprintf("input: the request body exceeds %d bytes", maxBody)
			}
			writeJSON(w, http.StatusBadRequest, migration.StructuredError{Error: "malformed", Causes: []string{cause}})
			log.Info("translation refused: unreadable body", "status", http.StatusBadRequest, "durationMs", time.Since(start).Milliseconds())
			return
		}
		res, err := migration.TranslateJSON(body, opt)
		if err != nil {
			status := http.StatusUnprocessableEntity
			if migration.ErrorKind(err) == "malformed" {
				status = http.StatusBadRequest
			}
			causes := migration.ErrorCauses(err)
			writeJSON(w, status, migration.StructuredError{Error: migration.ErrorKind(err), Causes: causes})
			log.Info("translation refused", "status", status, "causes", causes, "durationMs", time.Since(start).Milliseconds())
			return
		}
		out := translateResponse{YAML: res.YAML}
		names := make([]string, 0, len(res.Manifests))
		for _, n := range res.Manifests {
			out.Manifests = append(out.Manifests, n.JSON())
			names = append(names, n.Metadata.Name)
		}
		writeJSON(w, http.StatusOK, out)
		log.Info("translation emitted", "status", http.StatusOK, "networks", names, "durationMs", time.Since(start).Milliseconds())
	})
	return mux
}

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	enc := json.NewEncoder(w)
	enc.SetEscapeHTML(false)
	_ = enc.Encode(v)
}

package main

// The Network validating webhook's registration (T061; contracts/crd-api.md §"The webhook fails
// closed", AD-52, AD-61). The provider serves it by default: the shipped
// ValidatingWebhookConfiguration (deploy/agentic-netops/webhook.yaml) states failurePolicy Fail,
// so a provider that did not serve it would refuse every Network create and update — which is
// why WEBHOOK_SERVE=false exists only for a process run outside the cluster.
//
// The server is the provider's own controller-runtime webhook server, added to the manager as
// a runnable (it needs no leader: every replica serves), its serving certificate read from
// WEBHOOK_CERT_DIR — the cert-manager-issued Secret srl-provider-webhook-tls mounted by the
// Deployment. The readiness probe includes it, so the Service routes to a Pod only once it
// serves.

import (
	"fmt"
	"strconv"

	ctrl "sigs.k8s.io/controller-runtime"
	ctrlwebhook "sigs.k8s.io/controller-runtime/pkg/webhook"

	"github.com/mairp/agentic-netops-srl/internal/webhook"
)

// Webhook settings and their defaults.
const (
	EnvWebhookServe   = "WEBHOOK_SERVE"    // default true
	EnvWebhookPort    = "WEBHOOK_PORT"     // default 9443
	EnvWebhookCertDir = "WEBHOOK_CERT_DIR" // default /tmp/k8s-webhook-server/serving-certs

	WebhookPortDefault    = 9443
	WebhookCertDirDefault = "/tmp/k8s-webhook-server/serving-certs"
)

// webhookSettings is the parsed webhook configuration.
type webhookSettings struct {
	Serve   bool
	Port    int
	CertDir string
}

// loadWebhookSettings parses the WEBHOOK_* variables; a refused value names the variable.
func loadWebhookSettings(lookup func(string) (string, bool)) (webhookSettings, error) {
	s := webhookSettings{Serve: true, Port: WebhookPortDefault, CertDir: WebhookCertDirDefault}
	if v, ok := lookup(EnvWebhookServe); ok {
		b, err := strconv.ParseBool(v)
		if err != nil {
			return s, fmt.Errorf("%s=%q is not a boolean", EnvWebhookServe, v)
		}
		s.Serve = b
	}
	if v, ok := lookup(EnvWebhookPort); ok {
		p, err := strconv.Atoi(v)
		if err != nil || p < 1 || p > 65535 {
			return s, fmt.Errorf("%s=%q is not a port 1–65535", EnvWebhookPort, v)
		}
		s.Port = p
	}
	if v, ok := lookup(EnvWebhookCertDir); ok {
		if v == "" {
			return s, fmt.Errorf("%s is set but empty", EnvWebhookCertDir)
		}
		s.CertDir = v
	}
	return s, nil
}

// setupWebhook registers the Network validating webhook (T061) on its own webhook server.
func setupWebhook(mgr ctrl.Manager, lookup func(string) (string, bool)) error {
	s, err := loadWebhookSettings(lookup)
	if err != nil {
		return fmt.Errorf("refusing to start: %w", err)
	}
	if !s.Serve {
		return nil
	}
	srv := ctrlwebhook.NewServer(ctrlwebhook.Options{Port: s.Port, CertDir: s.CertDir})
	// Live reads through the API reader: Networks cluster-wide, Fabrics and the qualification
	// record in agentic-netops-system (internal/webhook).
	webhook.Register(srv, mgr.GetAPIReader(), mgr.GetScheme())
	if err := mgr.Add(srv); err != nil {
		return err
	}
	return mgr.AddReadyzCheck("webhook", srv.StartedChecker())
}

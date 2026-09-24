// The chat surface as manifests (deploy/agents/ui.yaml, T126; US10; FR-102, AD-46;
// contracts/kubernetes-objects.md: Deployment/Service ui 3000, ConfigMap ui-env, ServiceAccount
// intent-ui), decoded strictly with the upstream types of the pinned API:
//
//   - ConfigMap ui-env carries only base URLs by cluster service DNS (http://<svc>.<ns>.svc[:port]),
//     SUPERVISOR_BASE_URL = the supervisor's; no value carries a credential (no userinfo, no query,
//     no credential-named key);
//   - Service ui is NodePort, port 3000 → nodePort 30300, selecting the ui pods; the Kind config maps
//     30300 exactly once, on 127.0.0.1 only (host port 13000) — loopback, never 0.0.0.0;
//   - ServiceAccount intent-ui mounts no token (deploy/rbac/serviceaccounts.yaml) and the pod spec
//     says so too; serviceAccountName intent-ui;
//   - Deployment ui: one replica, the tier's labels, image ui:<64 hex> (never `latest`) with
//     imagePullPolicy Never and a 64-hex newTag in the kustomization's images: override, ui-env
//     reaching the container per key, liveness and readiness GET /healthz on 3000, requests and
//     limits, non-root with a read-only root filesystem and no privilege escalation;
//   - ui.yaml is a kustomization resource.
//
// Each check has a negative control: the same predicate refuses a mutated copy.
package manifests_test

import (
	"fmt"
	"net/url"
	"path/filepath"
	"regexp"
	"slices"
	"strings"
	"testing"

	corev1 "k8s.io/api/core/v1"
	"sigs.k8s.io/yaml"
)

const (
	uiName           = "ui"
	uiSA             = "intent-ui"
	uiPort           = 3000
	uiNodePort       = 30300
	uiHostPort       = 13000
	uiSupervisorBase = "http://supervisor.agentic-netops-agents.svc:9090"
)

var (
	clusterSvcHost = regexp.MustCompile(`^[a-z0-9]([-a-z0-9]*[a-z0-9])?\.[a-z0-9]([-a-z0-9]*[a-z0-9])?\.svc(\.cluster\.local)?$`)
	credentialKey  = regexp.MustCompile(`(?i)pass|secret|token|user|auth|cred|api[_-]?key`)
)

// kindConfig is the part of config/kind/cluster.yaml the loopback check reads.
type kindConfig struct {
	Nodes []struct {
		ExtraPortMappings []struct {
			ContainerPort int32  `json:"containerPort"`
			HostPort      int32  `json:"hostPort"`
			ListenAddress string `json:"listenAddress"`
			Protocol      string `json:"protocol"`
		} `json:"extraPortMappings"`
	} `json:"nodes"`
}

func loadKindConfig(t *testing.T) kindConfig {
	t.Helper()
	var k kindConfig
	if err := yaml.Unmarshal(mustRead(t, filepath.Join(repoRoot(t), "config", "kind", "cluster.yaml")), &k); err != nil {
		t.Fatal(err)
	}
	return k
}

func loadServiceAccounts(t *testing.T) map[string]corev1.ServiceAccount {
	t.Helper()
	path := rbacFile(t, "serviceaccounts.yaml")
	out := map[string]corev1.ServiceAccount{}
	for _, d := range docs(t, path) {
		var sa corev1.ServiceAccount
		strict(t, path, d, &sa)
		out[sa.Name] = sa
	}
	return out
}

func uiEnvProblems(o tierObjects) []string {
	var msgs []string
	cm, ok := o.configMaps["ui-env"]
	if !ok {
		return []string{"ConfigMap ui-env missing"}
	}
	if len(cm.BinaryData) > 0 {
		msgs = append(msgs, "ui-env: binaryData present")
	}
	if cm.Data["SUPERVISOR_BASE_URL"] != uiSupervisorBase {
		msgs = append(msgs, fmt.Sprintf("ui-env: SUPERVISOR_BASE_URL=%q, want %q", cm.Data["SUPERVISOR_BASE_URL"], uiSupervisorBase))
	}
	for k, v := range cm.Data {
		if credentialKey.MatchString(k) {
			msgs = append(msgs, "ui-env: key "+k+" names a credential")
		}
		u, err := url.Parse(v)
		if err != nil || u.Scheme != "http" && u.Scheme != "https" {
			msgs = append(msgs, fmt.Sprintf("ui-env: %s=%q is not an http(s) base URL", k, v))
			continue
		}
		if u.User != nil || strings.Contains(v, "@") {
			msgs = append(msgs, "ui-env: "+k+" carries userinfo (a credential)")
		}
		if u.RawQuery != "" || u.Fragment != "" {
			msgs = append(msgs, "ui-env: "+k+" carries a query or fragment")
		}
		if !clusterSvcHost.MatchString(u.Hostname()) {
			msgs = append(msgs, fmt.Sprintf("ui-env: %s host %q is not a cluster service DNS name (<svc>.<ns>.svc)", k, u.Hostname()))
		}
	}
	return msgs
}

func uiServiceProblems(o tierObjects, k kindConfig) []string {
	var msgs []string
	s, ok := o.services[uiName]
	if !ok || s.Spec.Type != corev1.ServiceTypeNodePort || len(s.Spec.Ports) != 1 ||
		s.Spec.Ports[0].Port != uiPort || s.Spec.Ports[0].NodePort != uiNodePort || s.Spec.Ports[0].Protocol != corev1.ProtocolTCP {
		msgs = append(msgs, fmt.Sprintf("Service ui: want NodePort TCP %d → %d", uiPort, uiNodePort))
	}
	if ok && s.Spec.Selector["app.kubernetes.io/name"] != uiName {
		msgs = append(msgs, fmt.Sprintf("Service ui selects %v, want app.kubernetes.io/name=ui", s.Spec.Selector))
	}
	n := 0
	for _, node := range k.Nodes {
		for _, m := range node.ExtraPortMappings {
			if m.ContainerPort != uiNodePort {
				continue
			}
			n++
			if m.ListenAddress != "127.0.0.1" {
				msgs = append(msgs, fmt.Sprintf("Kind maps NodePort %d on %q, want 127.0.0.1 only", uiNodePort, m.ListenAddress))
			}
			if m.HostPort != uiHostPort {
				msgs = append(msgs, fmt.Sprintf("Kind maps NodePort %d to host port %d, want %d", uiNodePort, m.HostPort, uiHostPort))
			}
		}
	}
	if n != 1 {
		msgs = append(msgs, fmt.Sprintf("Kind maps NodePort %d %d times, want exactly once (127.0.0.1:%d)", uiNodePort, n, uiHostPort))
	}
	return msgs
}

func uiDeploymentProblems(o tierObjects, sas map[string]corev1.ServiceAccount, kustomImages map[string]string) []string {
	var msgs []string
	sa, ok := sas[uiSA]
	if !ok || sa.AutomountServiceAccountToken == nil || *sa.AutomountServiceAccountToken {
		msgs = append(msgs, "ServiceAccount intent-ui: want automountServiceAccountToken: false")
	}
	w, ok := o.workloads[uiName]
	if !ok || w.kind != "Deployment" {
		return append(msgs, "Deployment ui missing")
	}
	if w.replicas == nil || *w.replicas != 1 {
		msgs = append(msgs, "ui: want exactly one replica")
	}
	for k, v := range map[string]string{"app.kubernetes.io/name": uiName, "app.kubernetes.io/part-of": "agentic-netops-intent-tier",
		"agentic-netops.io/tier": "intent", "agentic-netops.io/identity": uiSA} {
		if w.meta[k] != v {
			msgs = append(msgs, fmt.Sprintf("ui: label %s=%q, want %q", k, w.meta[k], v))
		}
	}
	if w.pod.ServiceAccountName != uiSA {
		msgs = append(msgs, "ui: serviceAccountName "+w.pod.ServiceAccountName+", want "+uiSA)
	}
	if w.pod.AutomountServiceAccountToken == nil || *w.pod.AutomountServiceAccountToken {
		msgs = append(msgs, "ui: the pod spec must set automountServiceAccountToken: false")
	}
	if psc := w.pod.SecurityContext; psc == nil || psc.RunAsNonRoot == nil || !*psc.RunAsNonRoot {
		msgs = append(msgs, "ui: want runAsNonRoot")
	}
	if len(w.pod.Containers) != 1 || len(w.pod.InitContainers) != 0 {
		return append(msgs, "ui: want exactly one container")
	}
	c := w.pod.Containers[0]
	repo, tag, _ := strings.Cut(c.Image, ":")
	if repo != uiName || !hashTag.MatchString(tag) {
		msgs = append(msgs, "ui: image "+c.Image+", want ui:<64 hex> (never latest)")
	}
	if nt := kustomImages[uiName]; !hashTag.MatchString(nt) {
		msgs = append(msgs, fmt.Sprintf("kustomization images: ui newTag %q, want 64 hex (never latest)", nt))
	}
	if c.ImagePullPolicy != corev1.PullNever {
		msgs = append(msgs, "ui: imagePullPolicy "+string(c.ImagePullPolicy)+", want Never")
	}
	portOK := slices.ContainsFunc(c.Ports, func(p corev1.ContainerPort) bool {
		return p.Name == "http" && p.ContainerPort == uiPort && p.Protocol == corev1.ProtocolTCP
	})
	if !portOK {
		msgs = append(msgs, fmt.Sprintf("ui: want containerPort http %d/TCP", uiPort))
	}
	for name, p := range map[string]*corev1.Probe{"liveness": c.LivenessProbe, "readiness": c.ReadinessProbe} {
		if p == nil || p.HTTPGet == nil || p.HTTPGet.Path != "/healthz" ||
			!(p.HTTPGet.Port.IntValue() == uiPort || (p.HTTPGet.Port.String() == "http" && portOK)) {
			msgs = append(msgs, "ui: "+name+" probe must be GET /healthz on 3000")
		}
	}
	env := map[string]*corev1.EnvVarSource{}
	for _, e := range c.Env {
		if e.Value != "" {
			msgs = append(msgs, "ui: env "+e.Name+" is a literal; base URLs come from ConfigMap ui-env")
		}
		env[e.Name] = e.ValueFrom
	}
	if v := env["SUPERVISOR_BASE_URL"]; v == nil || v.ConfigMapKeyRef == nil || v.ConfigMapKeyRef.Name != "ui-env" ||
		v.ConfigMapKeyRef.Key != "SUPERVISOR_BASE_URL" || (v.ConfigMapKeyRef.Optional != nil && *v.ConfigMapKeyRef.Optional) {
		msgs = append(msgs, "ui: env SUPERVISOR_BASE_URL is not configMapKeyRef ui-env/SUPERVISOR_BASE_URL")
	}
	for _, e := range c.Env {
		if e.ValueFrom != nil && e.ValueFrom.SecretKeyRef != nil {
			msgs = append(msgs, "ui: env "+e.Name+" reads a Secret; the ui holds no credential")
		}
	}
	if len(c.EnvFrom) > 0 {
		msgs = append(msgs, "ui: envFrom present; ui-env reaches the container per key")
	}
	for _, v := range w.pod.Volumes {
		if v.Secret != nil || v.Projected != nil {
			msgs = append(msgs, "ui: volume "+v.Name+" mounts a Secret or projected token; the ui holds no credential")
		}
	}
	for _, r := range []corev1.ResourceName{corev1.ResourceCPU, corev1.ResourceMemory} {
		if q, ok := c.Resources.Requests[r]; !ok || q.IsZero() {
			msgs = append(msgs, "ui: no "+string(r)+" request")
		}
		if q, ok := c.Resources.Limits[r]; !ok || q.IsZero() {
			msgs = append(msgs, "ui: no "+string(r)+" limit")
		}
	}
	if sc := c.SecurityContext; sc == nil || sc.ReadOnlyRootFilesystem == nil || !*sc.ReadOnlyRootFilesystem ||
		sc.AllowPrivilegeEscalation == nil || *sc.AllowPrivilegeEscalation {
		msgs = append(msgs, "ui: want readOnlyRootFilesystem and no privilege escalation")
	}
	return msgs
}

func kustomizationImages(t *testing.T) (map[string]string, []string) {
	t.Helper()
	var k struct {
		Resources []string `json:"resources"`
		Images    []struct {
			Name   string `json:"name"`
			NewTag string `json:"newTag"`
		} `json:"images"`
	}
	if err := yaml.Unmarshal(mustRead(t, filepath.Join(agentsDir(t), "kustomization.yaml")), &k); err != nil {
		t.Fatal(err)
	}
	imgs := map[string]string{}
	for _, i := range k.Images {
		imgs[i.Name] = i.NewTag
	}
	return imgs, k.Resources
}

// cloneTier copies what the negative controls mutate.
func cloneTier(o tierObjects) tierObjects {
	bad := o
	bad.workloads = map[string]*workload{}
	for k, v := range o.workloads {
		c := *v
		c.pod = *v.pod.DeepCopy()
		c.meta = maps(v.meta)
		bad.workloads[k] = &c
	}
	bad.services = map[string]corev1.Service{}
	for k, v := range o.services {
		bad.services[k] = *v.DeepCopy()
	}
	bad.configMaps = map[string]corev1.ConfigMap{}
	for k, v := range o.configMaps {
		bad.configMaps[k] = *v.DeepCopy()
	}
	return bad
}

func TestUIEnvClusterDNSNoCredential(t *testing.T) {
	o := loadTier(t)
	for _, m := range uiEnvProblems(o) {
		t.Error(m)
	}
	for _, mutate := range []func(c *corev1.ConfigMap){
		func(c *corev1.ConfigMap) { c.Data["SUPERVISOR_BASE_URL"] = "http://127.0.0.1:19090" },
		func(c *corev1.ConfigMap) {
			c.Data["SUPERVISOR_BASE_URL"] = "http://operator:pw@supervisor.agentic-netops-agents.svc:9090"
		},
		func(c *corev1.ConfigMap) { c.Data["API_TOKEN"] = "http://supervisor.agentic-netops-agents.svc:9090" },
		func(c *corev1.ConfigMap) { c.Data["OTHER_BASE_URL"] = "http://example.com" },
		func(c *corev1.ConfigMap) {
			c.Data["SUPERVISOR_BASE_URL"] = "http://supervisor.agentic-netops-agents.svc:9090?token=x"
		},
	} {
		bad := cloneTier(o)
		c := bad.configMaps["ui-env"]
		mutate(&c)
		bad.configMaps["ui-env"] = c
		if len(uiEnvProblems(bad)) == 0 {
			t.Errorf("negative control: a mutated ui-env was accepted: %v", c.Data)
		}
	}
}

func TestUIServiceLoopbackNodePort(t *testing.T) {
	o := loadTier(t)
	k := loadKindConfig(t)
	for _, m := range uiServiceProblems(o, k) {
		t.Error(m)
	}
	// negative controls: a different nodePort; a ClusterIP Service; a Kind mapping on every address
	bad := cloneTier(o)
	s := bad.services[uiName]
	s.Spec.Ports[0].NodePort = 31300
	bad.services[uiName] = s
	if len(uiServiceProblems(bad, k)) == 0 {
		t.Error("negative control: Service ui on nodePort 31300 was accepted")
	}
	bad = cloneTier(o)
	s = bad.services[uiName]
	s.Spec.Type = corev1.ServiceTypeClusterIP
	bad.services[uiName] = s
	if len(uiServiceProblems(bad, k)) == 0 {
		t.Error("negative control: a ClusterIP Service ui was accepted")
	}
	open := loadKindConfig(t)
	for i := range open.Nodes {
		for j := range open.Nodes[i].ExtraPortMappings {
			if open.Nodes[i].ExtraPortMappings[j].ContainerPort == uiNodePort {
				open.Nodes[i].ExtraPortMappings[j].ListenAddress = "0.0.0.0"
			}
		}
	}
	if len(uiServiceProblems(o, open)) == 0 {
		t.Error("negative control: a Kind mapping of 30300 on 0.0.0.0 was accepted")
	}
}

func TestUIDeployment(t *testing.T) {
	o := loadTier(t)
	sas := loadServiceAccounts(t)
	imgs, resources := kustomizationImages(t)
	for _, m := range uiDeploymentProblems(o, sas, imgs) {
		t.Error(m)
	}
	if !slices.Contains(resources, "ui.yaml") {
		t.Error("kustomization resources: ui.yaml missing")
	}
	if strings.Contains(o.raw["ui.yaml"], "latest") {
		t.Error("ui.yaml mentions `latest`")
	}
	// negative controls
	for i, mutate := range []func(w *workload){
		func(w *workload) { f := true; w.pod.AutomountServiceAccountToken = &f },
		func(w *workload) { w.pod.AutomountServiceAccountToken = nil },
		func(w *workload) { w.pod.ServiceAccountName = "intent-supervisor" },
		func(w *workload) { w.pod.Containers[0].ImagePullPolicy = corev1.PullIfNotPresent },
		func(w *workload) { w.pod.Containers[0].Image = "ui:latest" },
		func(w *workload) { w.pod.Containers[0].LivenessProbe.HTTPGet.Path = "/" },
		func(w *workload) { w.pod.Containers[0].Resources.Limits = nil },
		func(w *workload) { w.pod.Containers[0].SecurityContext.ReadOnlyRootFilesystem = nil },
		func(w *workload) {
			w.pod.Containers[0].Env = []corev1.EnvVar{{Name: "SUPERVISOR_BASE_URL", Value: uiSupervisorBase}}
		},
		func(w *workload) { delete(w.meta, "agentic-netops.io/tier") },
	} {
		bad := cloneTier(o)
		mutate(bad.workloads[uiName])
		if len(uiDeploymentProblems(bad, sas, imgs)) == 0 {
			t.Errorf("negative control %d: a mutated ui Deployment was accepted", i)
		}
	}
	tokened := map[string]corev1.ServiceAccount{}
	for k, v := range sas {
		tokened[k] = *v.DeepCopy()
	}
	sa := tokened[uiSA]
	f := true
	sa.AutomountServiceAccountToken = &f
	tokened[uiSA] = sa
	if len(uiDeploymentProblems(o, tokened, imgs)) == 0 {
		t.Error("negative control: ServiceAccount intent-ui mounting a token was accepted")
	}
	latest := maps(imgs)
	latest[uiName] = "latest"
	if len(uiDeploymentProblems(o, sas, latest)) == 0 {
		t.Error("negative control: kustomization newTag latest for ui was accepted")
	}
}

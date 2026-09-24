// The intent tier's workloads as manifests (deploy/agents/, T082, T086, T087; FR-072, FR-078, FR-102,
// FR-106, AD-45, AD-54, AD-67, NFR-003; contracts/kubernetes-objects.md, contracts/a2a-transport.md,
// data-model.md §25, §26), decoded strictly with the upstream types of the pinned API:
//
//   - every container (init containers included) of every workload declares cpu and memory requests
//     AND limits;
//   - llm-provider reaches the four agents only as a read-only volume — never secretKeyRef or envFrom
//     anywhere under deploy/agents; operator-credentials is mounted read-only in the supervisor and in
//     no other workload;
//   - the supervisor: one replica, strategy Recreate, PVC supervisor-checkpoint at /var/lib/supervisor,
//     liveness GET /health (generous) vs readiness GET /v1/health; every agent the same probe split;
//   - slim: Service and containers expose 46357 only — 46358 is nowhere; slim-config has server TLS on
//     (cert_file/key_file, never insecure) and the gateway password as an env reference;
//   - the tier collector has exactly one exporter, clickhouse, with no TTL, on every pipeline;
//   - the four agent images are `<name>:<64 hex>` with imagePullPolicy Never, overridden by the
//     kustomization's images: block with a 64-hex newTag; third-party images are the lock's pinned refs;
//   - TRANSPORT_SERVER_ENDPOINT is http://slim.agentic-netops-agents.svc:46357 in every agent;
//   - the translator sidecar (T097, contracts/translator-api.md) is the deployer's second container and
//     nowhere else: intent-translator:<64 hex>, never pulled, listening on 127.0.0.1:8090, its site
//     inventory from ConfigMap site-inventory keys, exec probes, requests and limits — and no Service
//     and no NetworkPolicy reaches port 8090; the deployer reaches it at TRANSLATOR_URL on loopback.
//
// Each check has a negative control: the same predicate refuses a mutated copy.
package manifests_test

import (
	"fmt"
	"path/filepath"
	"regexp"
	"slices"
	"strings"
	"testing"

	appsv1 "k8s.io/api/apps/v1"
	corev1 "k8s.io/api/core/v1"
	networkingv1 "k8s.io/api/networking/v1"
	"sigs.k8s.io/yaml"
)

const (
	transportEndpoint = "http://slim.agentic-netops-agents.svc:46357"
	llmSecret         = "llm-provider"
	operatorSecret    = "operator-credentials"
	slimDataPort      = 46357
	slimControlPort   = 46358
	sidecarName       = "intent-translator"
	sidecarAddr       = "127.0.0.1:8090"
	translatorURL     = "http://127.0.0.1:8090"
)

var (
	agentNames = []string{"supervisor", "mapper", "allocator", "deployer"}
	// localImages are the first-party images built by scripts/lib/image_build.sh: the four agents and
	// the deployer's translator sidecar.
	localImages = append(slices.Clone(agentNames), sidecarName)
	hashTag     = regexp.MustCompile(`^[0-9a-f]{64}$`)
)

// workload is one pod-bearing object of deploy/agents.
type workload struct {
	file, kind, name string
	meta             map[string]string // labels of the object
	replicas         *int32
	strategy         string
	pod              corev1.PodSpec
}

// tierObjects holds every decoded object of deploy/agents/*.yaml (the kustomization and cards excepted).
type tierObjects struct {
	workloads  map[string]*workload
	services   map[string]corev1.Service
	configMaps map[string]corev1.ConfigMap
	pvcs       map[string]corev1.PersistentVolumeClaim
	policies   map[string]networkingv1.NetworkPolicy
	raw        map[string]string // file -> content
}

func agentsDir(t *testing.T) string {
	t.Helper()
	return filepath.Join(repoRoot(t), "deploy", "agents")
}

func loadTier(t *testing.T) tierObjects {
	t.Helper()
	files, err := filepath.Glob(filepath.Join(agentsDir(t), "*.yaml"))
	if err != nil {
		t.Fatal(err)
	}
	o := tierObjects{
		workloads: map[string]*workload{}, services: map[string]corev1.Service{},
		configMaps: map[string]corev1.ConfigMap{}, pvcs: map[string]corev1.PersistentVolumeClaim{},
		policies: map[string]networkingv1.NetworkPolicy{}, raw: map[string]string{},
	}
	for _, path := range files {
		base := filepath.Base(path)
		if base == "kustomization.yaml" {
			continue
		}
		o.raw[base] = uncommented(string(mustRead(t, path)))
		for _, d := range docs(t, path) {
			switch kindOf(t, path, d) {
			case "Deployment":
				var dep appsv1.Deployment
				strict(t, path, d, &dep)
				o.workloads[dep.Name] = &workload{file: base, kind: "Deployment", name: dep.Name, meta: dep.Labels,
					replicas: dep.Spec.Replicas, strategy: string(dep.Spec.Strategy.Type), pod: dep.Spec.Template.Spec}
			case "StatefulSet":
				var ss appsv1.StatefulSet
				strict(t, path, d, &ss)
				o.workloads[ss.Name] = &workload{file: base, kind: "StatefulSet", name: ss.Name, meta: ss.Labels,
					replicas: ss.Spec.Replicas, pod: ss.Spec.Template.Spec}
			case "Service":
				var s corev1.Service
				strict(t, path, d, &s)
				o.services[s.Name] = s
			case "ConfigMap":
				var c corev1.ConfigMap
				strict(t, path, d, &c)
				o.configMaps[c.Name] = c
			case "PersistentVolumeClaim":
				var p corev1.PersistentVolumeClaim
				strict(t, path, d, &p)
				o.pvcs[p.Name] = p
			case "NetworkPolicy":
				var p networkingv1.NetworkPolicy
				strict(t, path, d, &p)
				o.policies[p.Name] = p
			case "Issuer", "Certificate":
				// cert-manager objects: shape checked in TestSlimTLSMaterial
			default:
				t.Fatalf("%s: unexpected kind %q", path, kindOf(t, path, d))
			}
		}
	}
	return o
}

// uncommented drops YAML comment lines, so the text checks see manifest content, not its documentation.
func uncommented(s string) string {
	var keep []string
	for _, l := range strings.Split(s, "\n") {
		if !strings.HasPrefix(strings.TrimSpace(l), "#") {
			keep = append(keep, l)
		}
	}
	return strings.Join(keep, "\n")
}

func allContainers(p corev1.PodSpec) []corev1.Container {
	return append(slices.Clone(p.InitContainers), p.Containers...)
}

// ---------------------------------------------------------------- resources

func resourceProblems(w *workload) []string {
	var msgs []string
	for _, c := range allContainers(w.pod) {
		for _, r := range []corev1.ResourceName{corev1.ResourceCPU, corev1.ResourceMemory} {
			if q, ok := c.Resources.Requests[r]; !ok || q.IsZero() {
				msgs = append(msgs, fmt.Sprintf("%s/%s container %s: no %s request", w.kind, w.name, c.Name, r))
			}
			if q, ok := c.Resources.Limits[r]; !ok || q.IsZero() {
				msgs = append(msgs, fmt.Sprintf("%s/%s container %s: no %s limit", w.kind, w.name, c.Name, r))
			}
		}
	}
	return msgs
}

func TestTierWorkloadsDeclareRequestsAndLimits(t *testing.T) {
	o := loadTier(t)
	want := append(slices.Clone(agentNames), "slim", "clickhouse", "agent-otel-collector")
	for _, n := range want {
		w, ok := o.workloads[n]
		if !ok {
			t.Errorf("workload %s missing from deploy/agents", n)
			continue
		}
		for _, m := range resourceProblems(w) {
			t.Error(m)
		}
	}
	if len(o.workloads) != len(want) {
		t.Errorf("deploy/agents holds %d workloads, want exactly %v", len(o.workloads), want)
	}
	// negative control
	bad := *o.workloads["supervisor"]
	bad.pod = *bad.pod.DeepCopy()
	bad.pod.Containers[0].Resources.Limits = nil
	if len(resourceProblems(&bad)) == 0 {
		t.Error("negative control: a container without limits was accepted")
	}
}

// ---------------------------------------------------------------- secrets: llm-provider, operator-credentials

// secretUse reports how a workload uses Secret name: read-only volume mount(s), writable mounts,
// and env references (secretKeyRef / envFrom).
func secretUse(w *workload, name string) (roMounts, rwMounts, envRefs int) {
	vols := map[string]bool{}
	for _, v := range w.pod.Volumes {
		if v.Secret != nil && v.Secret.SecretName == name {
			vols[v.Name] = true
		}
		if v.Projected != nil {
			for _, s := range v.Projected.Sources {
				if s.Secret != nil && s.Secret.Name == name {
					vols[v.Name] = true
				}
			}
		}
	}
	for _, c := range allContainers(w.pod) {
		for _, m := range c.VolumeMounts {
			if vols[m.Name] {
				if m.ReadOnly && m.SubPath == "" {
					roMounts++
				} else {
					rwMounts++
				}
			}
		}
		for _, e := range c.Env {
			if e.ValueFrom != nil && e.ValueFrom.SecretKeyRef != nil && e.ValueFrom.SecretKeyRef.Name == name {
				envRefs++
			}
		}
		for _, e := range c.EnvFrom {
			if e.SecretRef != nil && e.SecretRef.Name == name {
				envRefs++
			}
		}
	}
	return
}

// secretPlacementProblems: `name` must be a read-only whole-Secret volume in exactly the workloads of
// `in`, never an env reference, and absent from every other workload.
func secretPlacementProblems(o tierObjects, name string, in []string) []string {
	var msgs []string
	for wn, w := range o.workloads {
		ro, rw, env := secretUse(w, name)
		switch {
		case env > 0:
			msgs = append(msgs, fmt.Sprintf("%s reaches %s through secretKeyRef/envFrom (%d)", name, wn, env))
		case rw > 0:
			msgs = append(msgs, fmt.Sprintf("%s is mounted writable or by subPath in %s", name, wn))
		}
		if slices.Contains(in, wn) && ro == 0 {
			msgs = append(msgs, fmt.Sprintf("%s is not mounted read-only in %s", name, wn))
		}
		if !slices.Contains(in, wn) && ro > 0 {
			msgs = append(msgs, fmt.Sprintf("%s is mounted in %s, which must not hold it", name, wn))
		}
	}
	return msgs
}

func TestLLMProviderOnlyAsReadOnlyVolume(t *testing.T) {
	o := loadTier(t)
	for _, m := range secretPlacementProblems(o, llmSecret, agentNames) {
		t.Error(m)
	}
	for f, s := range o.raw {
		if strings.Contains(s, "envFrom") {
			t.Errorf("%s uses envFrom: no Secret reaches the tier as a whole environment", f)
		}
	}
	// negative control: the mapper takes the API key by secretKeyRef
	bad := o
	bad.workloads = map[string]*workload{}
	for k, v := range o.workloads {
		c := *v
		c.pod = *v.pod.DeepCopy()
		bad.workloads[k] = &c
	}
	bad.workloads["mapper"].pod.Containers[0].Env = append(bad.workloads["mapper"].pod.Containers[0].Env, corev1.EnvVar{
		Name: "LLM_API_KEY", ValueFrom: &corev1.EnvVarSource{SecretKeyRef: &corev1.SecretKeySelector{
			LocalObjectReference: corev1.LocalObjectReference{Name: llmSecret}, Key: "API_KEY"}}})
	if len(secretPlacementProblems(bad, llmSecret, agentNames)) == 0 {
		t.Error("negative control: llm-provider through secretKeyRef was accepted")
	}
}

func TestOperatorCredentialsOnlyInSupervisor(t *testing.T) {
	o := loadTier(t)
	for _, m := range secretPlacementProblems(o, operatorSecret, []string{"supervisor"}) {
		t.Error(m)
	}
	// negative control: the deployer mounts it too
	bad := o
	bad.workloads = map[string]*workload{}
	for k, v := range o.workloads {
		c := *v
		c.pod = *v.pod.DeepCopy()
		bad.workloads[k] = &c
	}
	d := bad.workloads["deployer"]
	d.pod.Volumes = append(d.pod.Volumes, corev1.Volume{Name: "oc", VolumeSource: corev1.VolumeSource{
		Secret: &corev1.SecretVolumeSource{SecretName: operatorSecret}}})
	d.pod.Containers[0].VolumeMounts = append(d.pod.Containers[0].VolumeMounts, corev1.VolumeMount{Name: "oc", MountPath: "/x", ReadOnly: true})
	if len(secretPlacementProblems(bad, operatorSecret, []string{"supervisor"})) == 0 {
		t.Error("negative control: operator-credentials in the deployer was accepted")
	}
}

// ---------------------------------------------------------------- agents: shape, probes, identity, env

func probePath(p *corev1.Probe) string {
	if p == nil || p.HTTPGet == nil {
		return ""
	}
	return p.HTTPGet.Path
}

func agentProblems(o tierObjects, name string) []string {
	var msgs []string
	w, ok := o.workloads[name]
	if !ok || w.kind != "Deployment" {
		return []string{"Deployment " + name + " missing"}
	}
	if w.replicas == nil || *w.replicas != 1 {
		msgs = append(msgs, name+": want exactly one replica")
	}
	for k, v := range map[string]string{"app.kubernetes.io/name": name, "agentic-netops.io/tier": "intent",
		"agentic-netops.io/identity": "intent-" + name} {
		if w.meta[k] != v {
			msgs = append(msgs, fmt.Sprintf("%s: label %s=%q, want %q", name, k, w.meta[k], v))
		}
	}
	if w.pod.ServiceAccountName != "intent-"+name {
		msgs = append(msgs, name+": serviceAccountName "+w.pod.ServiceAccountName)
	}
	noToken := name == "supervisor" || name == "mapper"
	if noToken && (w.pod.AutomountServiceAccountToken == nil || *w.pod.AutomountServiceAccountToken) {
		msgs = append(msgs, name+": must set automountServiceAccountToken: false")
	}
	wantContainers := 1
	if name == "deployer" {
		wantContainers = 2 // the deployer carries the translator sidecar (T097)
	}
	if len(w.pod.Containers) != wantContainers {
		msgs = append(msgs, fmt.Sprintf("%s: %d containers, want %d (only the deployer carries the translator sidecar)", name, len(w.pod.Containers), wantContainers))
		return msgs
	}
	c := w.pod.Containers[0]
	repo, tag, _ := strings.Cut(c.Image, ":")
	if repo != name || !hashTag.MatchString(tag) {
		msgs = append(msgs, name+": image "+c.Image+", want "+name+":<64 hex>")
	}
	if c.ImagePullPolicy != corev1.PullNever {
		msgs = append(msgs, name+": imagePullPolicy "+string(c.ImagePullPolicy)+", want Never")
	}
	if probePath(c.LivenessProbe) != "/health" || probePath(c.ReadinessProbe) != "/v1/health" {
		msgs = append(msgs, fmt.Sprintf("%s: liveness %q readiness %q, want /health vs /v1/health",
			name, probePath(c.LivenessProbe), probePath(c.ReadinessProbe)))
	}
	env := map[string]string{}
	for _, e := range c.Env {
		env[e.Name] = e.Value
	}
	if env["TRANSPORT_SERVER_ENDPOINT"] != transportEndpoint {
		msgs = append(msgs, fmt.Sprintf("%s: TRANSPORT_SERVER_ENDPOINT=%q, want %q", name, env["TRANSPORT_SERVER_ENDPOINT"], transportEndpoint))
	}
	if env["AGENT_COMPONENT"] != name {
		msgs = append(msgs, name+": AGENT_COMPONENT="+env["AGENT_COMPONENT"])
	}
	sc := c.SecurityContext
	if sc == nil || sc.ReadOnlyRootFilesystem == nil || !*sc.ReadOnlyRootFilesystem ||
		sc.AllowPrivilegeEscalation == nil || *sc.AllowPrivilegeEscalation {
		msgs = append(msgs, name+": want readOnlyRootFilesystem and no privilege escalation")
	}
	if w.pod.SecurityContext == nil || w.pod.SecurityContext.RunAsNonRoot == nil || !*w.pod.SecurityContext.RunAsNonRoot {
		msgs = append(msgs, name+": want runAsNonRoot")
	}
	// read-only ConfigMap mounts: site-inventory + fabric-qualification (all four; the supervisor's
	// /suggested-prompts resolves against them) and agent-cards (supervisor)
	cms := map[string]bool{}
	for _, v := range w.pod.Volumes {
		if v.ConfigMap != nil && (v.ConfigMap.Optional == nil || !*v.ConfigMap.Optional) {
			for _, m := range c.VolumeMounts {
				if m.Name == v.Name && m.ReadOnly {
					cms[v.ConfigMap.Name] = true
				}
			}
		}
	}
	wantCMs := []string{"site-inventory", "fabric-qualification"}
	if name == "supervisor" {
		wantCMs = append(wantCMs, "agent-cards")
	}
	for _, cm := range wantCMs {
		if !cms[cm] {
			msgs = append(msgs, name+": ConfigMap "+cm+" is not mounted read-only (optional: false)")
		}
	}
	for _, s := range []string{"slim-gateway", "slim-tls"} {
		if ro, _, _ := secretUse(w, s); ro == 0 {
			msgs = append(msgs, name+": Secret "+s+" is not mounted read-only")
		}
	}
	return msgs
}

func TestAgentDeployments(t *testing.T) {
	o := loadTier(t)
	for _, n := range agentNames {
		for _, m := range agentProblems(o, n) {
			t.Error(m)
		}
	}
	for _, m := range sidecarProblems(o) {
		t.Error(m)
	}
	// negative controls
	for _, mutate := range []func(w *workload){
		func(w *workload) { w.pod.Containers[0].ImagePullPolicy = corev1.PullIfNotPresent },
		func(w *workload) { w.pod.Containers[0].Image = "mapper:latest" },
		func(w *workload) { w.pod.Containers[0].LivenessProbe.HTTPGet.Path = "/v1/health" },
		func(w *workload) { w.pod.Containers[0].Env[1].Value = "http://slim.agentic-netops-agents.svc:46358" },
		func(w *workload) { f := true; w.pod.AutomountServiceAccountToken = &f },
	} {
		bad := o
		bad.workloads = map[string]*workload{}
		for k, v := range o.workloads {
			c := *v
			c.pod = *v.pod.DeepCopy()
			bad.workloads[k] = &c
		}
		mutate(bad.workloads["mapper"])
		if len(agentProblems(bad, "mapper")) == 0 {
			t.Error("negative control: a mutated mapper Deployment was accepted")
		}
	}
}

// sidecarProblems: the translator sidecar is the deployer's second container and appears nowhere else;
// it is loopback-only (no Service, no NetworkPolicy allowance, no containerPort), takes its site
// inventory from ConfigMap site-inventory keys, has exec probes, and the deployer reaches it at
// TRANSLATOR_URL on loopback.
func sidecarProblems(o tierObjects) []string {
	var msgs []string
	for wn, w := range o.workloads {
		for i, c := range allContainers(w.pod) {
			repo, _, _ := strings.Cut(c.Image, ":")
			if (c.Name == sidecarName || repo == sidecarName) && (wn != "deployer" || i != len(w.pod.InitContainers)+1) {
				msgs = append(msgs, fmt.Sprintf("%s: container %s runs the translator; only the deployer's second container may", wn, c.Name))
			}
		}
	}
	d := o.workloads["deployer"]
	if d == nil || len(d.pod.Containers) != 2 {
		return append(msgs, "deployer: the translator sidecar is not its second container")
	}
	c := d.pod.Containers[1]
	if c.Name != sidecarName {
		msgs = append(msgs, "deployer: second container "+c.Name+", want "+sidecarName)
	}
	if repo, tag, _ := strings.Cut(c.Image, ":"); repo != sidecarName || !hashTag.MatchString(tag) {
		msgs = append(msgs, "deployer/intent-translator: image "+c.Image+", want intent-translator:<64 hex>")
	}
	if c.ImagePullPolicy != corev1.PullNever {
		msgs = append(msgs, "deployer/intent-translator: imagePullPolicy "+string(c.ImagePullPolicy)+", want Never")
	}
	if !slices.Equal(c.Args, []string{"--listen", sidecarAddr}) {
		msgs = append(msgs, fmt.Sprintf("deployer/intent-translator: args %q, want --listen %s (loopback only)", c.Args, sidecarAddr))
	}
	if len(c.Ports) != 0 {
		msgs = append(msgs, "deployer/intent-translator: declares a containerPort; it is pod-local and publishes nothing")
	}
	env := map[string]*corev1.EnvVarSource{}
	for _, e := range c.Env {
		env[e.Name] = e.ValueFrom
	}
	for _, k := range []string{"FABRIC_NODE_MAP", "FABRIC_PORT_MAP", "FABRIC_ASN"} {
		v := env[k]
		if v == nil || v.ConfigMapKeyRef == nil || v.ConfigMapKeyRef.Name != "site-inventory" || v.ConfigMapKeyRef.Key != k ||
			(v.ConfigMapKeyRef.Optional != nil && *v.ConfigMapKeyRef.Optional) {
			msgs = append(msgs, "deployer/intent-translator: env "+k+" is not configMapKeyRef site-inventory/"+k)
		}
	}
	for _, p := range []*corev1.Probe{c.LivenessProbe, c.ReadinessProbe} {
		if p == nil || p.Exec == nil || !strings.Contains(strings.Join(p.Exec.Command, " "), translatorURL+"/healthz") {
			msgs = append(msgs, "deployer/intent-translator: liveness and readiness must be exec probes of "+translatorURL+"/healthz (the kubelet cannot reach loopback)")
			break
		}
	}
	for _, r := range []corev1.ResourceName{corev1.ResourceCPU, corev1.ResourceMemory} {
		if q, ok := c.Resources.Requests[r]; !ok || q.IsZero() {
			msgs = append(msgs, "deployer/intent-translator: no "+string(r)+" request")
		}
		if q, ok := c.Resources.Limits[r]; !ok || q.IsZero() {
			msgs = append(msgs, "deployer/intent-translator: no "+string(r)+" limit")
		}
	}
	if sc := c.SecurityContext; sc == nil || sc.ReadOnlyRootFilesystem == nil || !*sc.ReadOnlyRootFilesystem ||
		sc.AllowPrivilegeEscalation == nil || *sc.AllowPrivilegeEscalation {
		msgs = append(msgs, "deployer/intent-translator: want readOnlyRootFilesystem and no privilege escalation")
	}
	url := ""
	for _, e := range d.pod.Containers[0].Env {
		if e.Name == "TRANSLATOR_URL" {
			url = e.Value
		}
	}
	if url != translatorURL {
		msgs = append(msgs, fmt.Sprintf("deployer: TRANSLATOR_URL=%q, want %q", url, translatorURL))
	}
	for _, svc := range o.services {
		for _, p := range svc.Spec.Ports {
			if p.Port == 8090 || p.TargetPort.IntValue() == 8090 || p.TargetPort.String() == sidecarName {
				msgs = append(msgs, "Service "+svc.Name+" reaches the translator sidecar's port 8090")
			}
		}
	}
	for _, np := range o.policies {
		for _, r := range np.Spec.Ingress {
			for _, p := range r.Ports {
				if p.Port != nil && p.Port.IntValue() == 8090 {
					msgs = append(msgs, "NetworkPolicy "+np.Name+" admits port 8090")
				}
			}
		}
	}
	return msgs
}

func TestTranslatorSidecarNegativeControls(t *testing.T) {
	o := loadTier(t)
	if m := sidecarProblems(o); len(m) != 0 {
		t.Fatalf("the shipped manifests fail: %v", m)
	}
	for name, mutate := range map[string]func(o *tierObjects){
		"sidecar pulled": func(o *tierObjects) {
			o.workloads["deployer"].pod.Containers[1].ImagePullPolicy = corev1.PullIfNotPresent
		},
		"sidecar on all ifaces": func(o *tierObjects) { o.workloads["deployer"].pod.Containers[1].Args = []string{"--listen", ":8090"} },
		"sidecar env literal": func(o *tierObjects) {
			o.workloads["deployer"].pod.Containers[1].Env[0] = corev1.EnvVar{Name: "FABRIC_NODE_MAP", Value: "{}"}
		},
		"sidecar containerPort": func(o *tierObjects) {
			o.workloads["deployer"].pod.Containers[1].Ports = []corev1.ContainerPort{{ContainerPort: 8090}}
		},
		"sidecar in the mapper": func(o *tierObjects) {
			o.workloads["mapper"].pod.Containers = append(o.workloads["mapper"].pod.Containers, o.workloads["deployer"].pod.Containers[1])
		},
		"no TRANSLATOR_URL": func(o *tierObjects) { o.workloads["deployer"].pod.Containers[0].Env = nil },
		"a Service to 8090": func(o *tierObjects) {
			o.services["translator"] = corev1.Service{Spec: corev1.ServiceSpec{Ports: []corev1.ServicePort{{Port: 8090}}}}
		},
	} {
		bad := o
		bad.workloads = map[string]*workload{}
		for k, v := range o.workloads {
			c := *v
			c.pod = *v.pod.DeepCopy()
			bad.workloads[k] = &c
		}
		bad.services = map[string]corev1.Service{}
		for k, v := range o.services {
			bad.services[k] = v
		}
		mutate(&bad)
		if len(sidecarProblems(bad)) == 0 {
			t.Errorf("negative control %q was accepted", name)
		}
	}
}

func mapValues(m map[string]string) []string {
	var out []string
	for _, v := range m {
		out = append(out, v)
	}
	return out
}

func supervisorProblems(o tierObjects) []string {
	var msgs []string
	w := o.workloads["supervisor"]
	if w == nil {
		return []string{"supervisor missing"}
	}
	if w.strategy != string(appsv1.RecreateDeploymentStrategyType) {
		msgs = append(msgs, "supervisor: strategy "+w.strategy+", want Recreate")
	}
	claim := ""
	for _, v := range w.pod.Volumes {
		if v.PersistentVolumeClaim != nil {
			for _, m := range w.pod.Containers[0].VolumeMounts {
				if m.Name == v.Name && m.MountPath == "/var/lib/supervisor" && !m.ReadOnly {
					claim = v.PersistentVolumeClaim.ClaimName
				}
			}
		}
	}
	if claim != "supervisor-checkpoint" {
		msgs = append(msgs, "supervisor: PVC supervisor-checkpoint not mounted writable at /var/lib/supervisor")
	}
	if p, ok := o.pvcs["supervisor-checkpoint"]; !ok || p.Spec.StorageClassName == nil || *p.Spec.StorageClassName != "standard" {
		msgs = append(msgs, "PVC supervisor-checkpoint missing or not on storageClass standard")
	}
	lp := w.pod.Containers[0].LivenessProbe
	// generous: a liveness failure needs at least four minutes of consecutive failures
	if lp == nil || int(lp.FailureThreshold)*int(lp.PeriodSeconds) < 240 {
		msgs = append(msgs, "supervisor: liveness must be generous (failureThreshold × periodSeconds ≥ 240 s)")
	}
	s, ok := o.services["supervisor"]
	if !ok || s.Spec.Type != corev1.ServiceTypeNodePort || len(s.Spec.Ports) != 1 ||
		s.Spec.Ports[0].Port != 9090 || s.Spec.Ports[0].NodePort != 30990 {
		msgs = append(msgs, "Service supervisor: want NodePort 9090 → 30990")
	}
	return msgs
}

func TestSupervisorRecreatePVCAndProbes(t *testing.T) {
	o := loadTier(t)
	for _, m := range supervisorProblems(o) {
		t.Error(m)
	}
	bad := o
	bad.workloads = map[string]*workload{}
	for k, v := range o.workloads {
		c := *v
		c.pod = *v.pod.DeepCopy()
		bad.workloads[k] = &c
	}
	bad.workloads["supervisor"].strategy = "RollingUpdate"
	bad.workloads["supervisor"].pod.Containers[0].LivenessProbe.FailureThreshold = 1
	if len(supervisorProblems(bad)) < 2 {
		t.Error("negative control: a RollingUpdate supervisor with a hair-trigger liveness was accepted")
	}
}

// ---------------------------------------------------------------- images: agents via kustomization, third party via the lock

func TestImagesPinned(t *testing.T) {
	root := repoRoot(t)
	var k struct {
		Images []struct {
			Name    string `json:"name"`
			NewTag  string `json:"newTag"`
			NewName string `json:"newName"`
		} `json:"images"`
	}
	if err := yaml.Unmarshal(mustRead(t, filepath.Join(agentsDir(t), "kustomization.yaml")), &k); err != nil {
		t.Fatal(err)
	}
	got := map[string]string{}
	for _, i := range k.Images {
		if i.NewName != "" {
			t.Errorf("kustomization renames image %s", i.Name)
		}
		got[i.Name] = i.NewTag
	}
	for _, n := range localImages {
		if !hashTag.MatchString(got[n]) {
			t.Errorf("kustomization images: %s newTag %q, want 64 hex", n, got[n])
		}
	}
	var lock struct {
		Platform      map[string]any `json:"platform"`
		Observability struct {
			OtelCollector struct{ Pinned string } `json:"otelCollector"`
		} `json:"observability"`
	}
	if err := yaml.Unmarshal(mustRead(t, filepath.Join(root, "versions.lock.yaml")), &lock); err != nil {
		t.Fatal(err)
	}
	want := map[string]string{
		"slim":                 pinnedOf(lock.Platform["slim"]),
		"clickhouse":           pinnedOf(lock.Platform["clickhouse"]),
		"agent-otel-collector": lock.Observability.OtelCollector.Pinned,
	}
	o := loadTier(t)
	for wn, ref := range want {
		if ref == "" {
			t.Fatalf("versions.lock.yaml has no pinned ref for %s", wn)
		}
		if w := o.workloads[wn]; w == nil || w.pod.Containers[0].Image != ref {
			t.Errorf("%s: image is not the lock's pinned %s", wn, ref)
		}
	}
	// every image under deploy/agents is either an agent's <name>:<hash> or a lock-pinned digest ref
	for wn, w := range o.workloads {
		for _, c := range allContainers(w.pod) {
			repo, tag, _ := strings.Cut(c.Image, ":")
			agent := slices.Contains(localImages, repo) && hashTag.MatchString(tag)
			if !agent && !slices.Contains(mapValues(want), c.Image) {
				t.Errorf("%s/%s: image %s is neither <agent>:<64 hex> nor a lock-pinned ref", wn, c.Name, c.Image)
			}
		}
	}
}

// pinnedOf reads the `pinned:` ref of a versions.lock.yaml platform entry.
func pinnedOf(entry any) string {
	m, _ := entry.(map[string]any)
	s, _ := m["pinned"].(string)
	return s
}

// ---------------------------------------------------------------- slim: ports, TLS, auth

// slimProblems: Service and container expose 46357 only; 46358 appears as no port anywhere; slim-config
// enables server TLS (cert_file/key_file, never insecure) and takes the password from the environment.
func slimProblems(o tierObjects) []string {
	var msgs []string
	s, ok := o.services["slim"]
	if !ok || len(s.Spec.Ports) != 1 || s.Spec.Ports[0].Port != slimDataPort || s.Spec.Ports[0].Protocol != corev1.ProtocolTCP {
		msgs = append(msgs, "Service slim: want exactly one port, 46357/TCP")
	}
	for _, svc := range o.services {
		for _, p := range svc.Spec.Ports {
			if p.Port == slimControlPort || p.TargetPort.IntValue() == slimControlPort {
				msgs = append(msgs, "Service "+svc.Name+" exposes the controller port 46358")
			}
		}
	}
	for wn, w := range o.workloads {
		for _, c := range allContainers(w.pod) {
			for _, p := range c.Ports {
				if p.ContainerPort == slimControlPort {
					msgs = append(msgs, wn+" declares the controller port 46358")
				}
			}
		}
	}
	if w := o.workloads["slim"]; w == nil || len(w.pod.Containers[0].Ports) != 1 || w.pod.Containers[0].Ports[0].ContainerPort != slimDataPort {
		msgs = append(msgs, "slim: want exactly one containerPort, 46357")
	}
	var cfg struct {
		Services map[string]struct {
			Dataplane struct {
				Servers []struct {
					Endpoint string         `json:"endpoint"`
					TLS      map[string]any `json:"tls"`
					Auth     struct {
						Basic map[string]string `json:"basic"`
					} `json:"auth"`
				} `json:"servers"`
			} `json:"dataplane"`
			Controller any `json:"controller"`
		} `json:"services"`
	}
	cm, ok := o.configMaps["slim-config"]
	if !ok {
		return append(msgs, "ConfigMap slim-config missing")
	}
	if err := yaml.Unmarshal([]byte(cm.Data["config.yaml"]), &cfg); err != nil {
		return append(msgs, "slim-config config.yaml: "+err.Error())
	}
	n := 0
	for name, svc := range cfg.Services {
		if svc.Controller != nil {
			msgs = append(msgs, "slim-config: service "+name+" configures a controller server")
		}
		for _, srv := range svc.Dataplane.Servers {
			n++
			if !strings.HasSuffix(srv.Endpoint, fmt.Sprintf(":%d", slimDataPort)) {
				msgs = append(msgs, "slim-config: server endpoint "+srv.Endpoint+" is not :46357")
			}
			if srv.TLS == nil || srv.TLS["cert_file"] == nil || srv.TLS["key_file"] == nil {
				msgs = append(msgs, "slim-config: TLS not enabled (cert_file/key_file, the key names T166 qualified)")
			}
			if ins, _ := srv.TLS["insecure"].(bool); ins {
				msgs = append(msgs, "slim-config: TLS insecure")
			}
			if srv.Auth.Basic["password"] != "${env:SLIM_GATEWAY_PASSWORD}" || srv.Auth.Basic["username"] != "${env:SLIM_GATEWAY_USERNAME}" {
				msgs = append(msgs, "slim-config: basic auth must take username/password from the env (Secret slim-gateway)")
			}
		}
	}
	if n != 1 {
		msgs = append(msgs, fmt.Sprintf("slim-config: %d data-plane servers, want 1", n))
	}
	// the env the config references comes from Secret slim-gateway by secretKeyRef
	if w := o.workloads["slim"]; w != nil {
		refs := map[string]string{}
		for _, e := range w.pod.Containers[0].Env {
			if e.ValueFrom != nil && e.ValueFrom.SecretKeyRef != nil && e.ValueFrom.SecretKeyRef.Name == "slim-gateway" {
				refs[e.Name] = e.ValueFrom.SecretKeyRef.Key
			}
		}
		if refs["SLIM_GATEWAY_PASSWORD"] != "password" || refs["SLIM_GATEWAY_USERNAME"] != "username" {
			msgs = append(msgs, "slim: SLIM_GATEWAY_{USERNAME,PASSWORD} must come from Secret slim-gateway by secretKeyRef")
		}
	}
	return msgs
}

func TestSlimTransport(t *testing.T) {
	o := loadTier(t)
	for _, m := range slimProblems(o) {
		t.Error(m)
	}
	for _, mutate := range []func(o *tierObjects){
		func(o *tierObjects) {
			orig := o.services["slim"]
			s := *orig.DeepCopy()
			s.Spec.Ports = append(s.Spec.Ports, corev1.ServicePort{Name: "controller", Port: slimControlPort})
			o.services["slim"] = s
		},
		func(o *tierObjects) {
			orig := o.configMaps["slim-config"]
			c := *orig.DeepCopy()
			c.Data["config.yaml"] = strings.Replace(c.Data["config.yaml"], "cert_file", "insecure: true\n              cert", 1)
			o.configMaps["slim-config"] = c
		},
		func(o *tierObjects) {
			orig := o.configMaps["slim-config"]
			c := *orig.DeepCopy()
			c.Data["config.yaml"] = strings.Replace(c.Data["config.yaml"], "${env:SLIM_GATEWAY_PASSWORD}", "changeme", 1)
			o.configMaps["slim-config"] = c
		},
	} {
		bad := o
		bad.services = maps(o.services)
		bad.configMaps = maps(o.configMaps)
		mutate(&bad)
		if len(slimProblems(bad)) == 0 {
			t.Error("negative control: a mutated slim transport was accepted")
		}
	}
}

func maps[V any](m map[string]V) map[string]V {
	out := make(map[string]V, len(m))
	for k, v := range m {
		out[k] = v
	}
	return out
}

func TestSlimTLSMaterial(t *testing.T) {
	path := filepath.Join(agentsDir(t), "slim.yaml")
	var server map[string]any
	for _, d := range docs(t, path) {
		var m map[string]any
		if err := yaml.Unmarshal(d, &m); err != nil {
			t.Fatal(err)
		}
		md, _ := m["metadata"].(map[string]any)
		if m["kind"] == "Certificate" && md["name"] == "slim-server" {
			server = m
		}
	}
	if server == nil {
		t.Fatal("slim.yaml: Certificate slim-server missing")
	}
	spec, _ := server["spec"].(map[string]any)
	if spec["secretName"] != "slim-tls" {
		t.Errorf("slim-server secretName %v, want slim-tls", spec["secretName"])
	}
	var dns []string
	for _, d := range spec["dnsNames"].([]any) {
		dns = append(dns, d.(string))
	}
	for _, want := range []string{"slim", "slim.agentic-netops-agents", "slim.agentic-netops-agents.svc", "slim.agentic-netops-agents.svc.cluster.local"} {
		if !slices.Contains(dns, want) {
			t.Errorf("slim-server dnsNames lack %s", want)
		}
	}
	if ref, _ := spec["issuerRef"].(map[string]any); ref["name"] != "slim-ca-issuer" {
		t.Errorf("slim-server issued by %v, want slim-ca-issuer (the in-cluster CA)", ref["name"])
	}
}

// ---------------------------------------------------------------- collector: one exporter, no TTL

type collectorConfig struct {
	Exporters map[string]map[string]any `json:"exporters"`
	Service   struct {
		Pipelines map[string]struct {
			Receivers []string `json:"receivers"`
			Exporters []string `json:"exporters"`
		} `json:"pipelines"`
	} `json:"service"`
	Receivers map[string]any `json:"receivers"`
}

func collectorProblems(raw string) []string {
	var msgs []string
	var c collectorConfig
	if err := yaml.Unmarshal([]byte(raw), &c); err != nil {
		return []string{"collector config: " + err.Error()}
	}
	if len(c.Exporters) != 1 || c.Exporters["clickhouse"] == nil {
		msgs = append(msgs, fmt.Sprintf("collector: want exactly one exporter, clickhouse; got %d", len(c.Exporters)))
	}
	ch := c.Exporters["clickhouse"]
	if ttl, set := ch["ttl"]; set && fmt.Sprint(ttl) != "0" {
		msgs = append(msgs, fmt.Sprintf("collector: clickhouse ttl %v — the audit record's tables carry no TTL", ttl))
	}
	for k := range ch {
		if strings.Contains(k, "ttl") && k != "ttl" {
			msgs = append(msgs, "collector: clickhouse sets "+k)
		}
	}
	if ch["database"] != "otel" {
		msgs = append(msgs, fmt.Sprintf("collector: clickhouse database %v, want otel", ch["database"]))
	}
	if ch["password"] != "${env:CLICKHOUSE_PASSWORD}" {
		msgs = append(msgs, "collector: clickhouse password must be the env reference ${env:CLICKHOUSE_PASSWORD}")
	}
	for _, p := range []string{"traces", "metrics", "logs"} {
		pl, ok := c.Service.Pipelines[p]
		if !ok || !slices.Equal(pl.Exporters, []string{"clickhouse"}) || !slices.Equal(pl.Receivers, []string{"otlp"}) {
			msgs = append(msgs, "collector: pipeline "+p+" must be otlp → clickhouse")
		}
	}
	if !strings.Contains(raw, "0.0.0.0:4318") {
		msgs = append(msgs, "collector: OTLP/HTTP receiver not on 4318")
	}
	return msgs
}

func TestCollectorOneExporterNoTTL(t *testing.T) {
	o := loadTier(t)
	cm, ok := o.configMaps["agent-otel-collector-config"]
	if !ok {
		t.Fatal("ConfigMap agent-otel-collector-config missing")
	}
	for _, m := range collectorProblems(cm.Data["config.yaml"]) {
		t.Error(m)
	}
	if s, ok := o.services["agent-otel-collector"]; !ok || len(s.Spec.Ports) != 1 || s.Spec.Ports[0].Port != 4318 {
		t.Error("Service agent-otel-collector: want exactly 4318")
	}
	raw := cm.Data["config.yaml"]
	for _, bad := range []string{
		strings.Replace(raw, "ttl: 0", "ttl: 720h", 1),
		strings.Replace(raw, "\nexporters:\n", "\nexporters:\n  debug: {}\n", 1),
		strings.Replace(raw, "exporters: [clickhouse]", "exporters: [clickhouse, otlphttp/fabric]", 1),
	} {
		if bad == raw {
			t.Fatal("negative control did not mutate the config")
		}
		if len(collectorProblems(bad)) == 0 {
			t.Error("negative control: a collector with a TTL or a second exporter was accepted")
		}
	}
}

func TestClickHouseStore(t *testing.T) {
	o := loadTier(t)
	w := o.workloads["clickhouse"]
	if w == nil || w.kind != "StatefulSet" {
		t.Fatal("StatefulSet clickhouse missing")
	}
	c := w.pod.Containers[0]
	refs := map[string]string{}
	for _, e := range c.Env {
		if e.ValueFrom != nil && e.ValueFrom.SecretKeyRef != nil {
			refs[e.Name] = e.ValueFrom.SecretKeyRef.Name + "/" + e.ValueFrom.SecretKeyRef.Key
		}
		if e.Name == "CLICKHOUSE_DB" && e.Value != "otel" {
			t.Errorf("clickhouse: CLICKHOUSE_DB=%q, want otel", e.Value)
		}
	}
	if refs["CLICKHOUSE_USER"] != "clickhouse-auth/username" || refs["CLICKHOUSE_PASSWORD"] != "clickhouse-auth/password" {
		t.Errorf("clickhouse: credentials must come from Secret clickhouse-auth by secretKeyRef, got %v", refs)
	}
	if c.ReadinessProbe == nil {
		t.Error("clickhouse: no readiness probe")
	}
	if s, ok := o.services["clickhouse"]; !ok || !slices.ContainsFunc(s.Spec.Ports, func(p corev1.ServicePort) bool { return p.Port == 8123 }) {
		t.Error("Service clickhouse: want port 8123")
	}
	if !strings.Contains(o.raw["clickhouse.yaml"], "volumeClaimTemplates:") {
		t.Error("clickhouse: want a volumeClaimTemplate")
	}
}

// ---------------------------------------------------------------- workload NetworkPolicies

func TestWorkloadNetworkPolicies(t *testing.T) {
	o := loadTier(t)
	want := map[string]struct {
		target string
		ports  []int32
	}{
		"agent-otel-collector-ingress": {"agent-otel-collector", []int32{4318}},
		"clickhouse-ingress":           {"clickhouse", []int32{8123, 9000}},
		"supervisor-ingress":           {"supervisor", []int32{9090}},
	}
	if len(o.policies) != len(want) {
		t.Errorf("deploy/agents holds %d NetworkPolicies, want %d", len(o.policies), len(want))
	}
	for name, w := range want {
		p, ok := o.policies[name]
		if !ok {
			t.Errorf("NetworkPolicy %s missing", name)
			continue
		}
		if p.Spec.PodSelector.MatchLabels["app.kubernetes.io/name"] != w.target {
			t.Errorf("%s selects %v, want %s", name, p.Spec.PodSelector.MatchLabels, w.target)
		}
		if !slices.Equal(p.Spec.PolicyTypes, []networkingv1.PolicyType{networkingv1.PolicyTypeIngress}) || len(p.Spec.Egress) > 0 {
			t.Errorf("%s: ingress only — egress stays the US6 policies'", name)
		}
		var got []int32
		for _, r := range p.Spec.Ingress {
			for _, port := range r.Ports {
				got = append(got, port.Port.IntVal)
			}
		}
		if !slices.Equal(got, w.ports) {
			t.Errorf("%s admits ports %v, want %v", name, got, w.ports)
		}
	}
	if from := o.policies["clickhouse-ingress"].Spec.Ingress; len(from) != 1 || len(from[0].From) != 1 ||
		from[0].From[0].PodSelector == nil || from[0].From[0].PodSelector.MatchLabels["app.kubernetes.io/name"] != "agent-otel-collector" {
		t.Error("clickhouse-ingress: only the tier collector may reach the store")
	}
}

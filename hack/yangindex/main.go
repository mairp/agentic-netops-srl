// Command yangindex writes the path register's YANG index (T128, research
// §Open items 9): every subscribed path of pkg/register resolved in the PINNED
// device models — versions.lock.yaml compatibility-set part 2, the
// nokia/srlinux-yang-models commit — to its schema elements (the module that
// instantiates each, list keys with their types), the leaf's type or, for a
// container, every leaf beneath it. The output,
// pkg/register/testdata/yang-index-<tag>.json, is committed; the register's
// guard reads it offline (pkg/register/subscribe_guard_test.go).
//
// It loads the models the way the device-configuration layer's Schema does
// (versions.lock.yaml part 4: srl_nokia/models, includes ietf and openconfig,
// iana for their imports, excludes '.*tools.*') with github.com/openconfig/goyang.
//
// Usage (the checkout must be at the locked commit; the tool refuses another):
//
//	git clone https://github.com/nokia/srlinux-yang-models /tmp/srlinux-yang-models
//	git -C /tmp/srlinux-yang-models checkout badcf9977fe672437907cdae7daebb27a1361c36
//	go run ./hack/yangindex -models /tmp/srlinux-yang-models
//
// A path the pinned models do not have is an error naming it: the register is
// then wrong, not the index.
package main

import (
	"bufio"
	"encoding/json"
	"flag"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"

	"github.com/openconfig/goyang/pkg/yang"

	"github.com/mairp/agentic-netops-srl/pkg/register"
)

func main() {
	models := flag.String("models", "", "checkout of the locked nokia/srlinux-yang-models commit")
	lock := flag.String("lock", "versions.lock.yaml", "the version lock file")
	out := flag.String("out", "", "output file (default pkg/register/testdata/yang-index-<tag>.json)")
	flag.Parse()
	if err := run(*models, *lock, *out); err != nil {
		fmt.Fprintln(os.Stderr, "yangindex:", err)
		os.Exit(1)
	}
}

func run(models, lock, out string) error {
	if models == "" {
		return fmt.Errorf("-models is required")
	}
	repo, tag, commit, err := lockedModels(lock)
	if err != nil {
		return err
	}
	head, err := exec.Command("git", "-C", models, "rev-parse", "HEAD").Output()
	if err != nil {
		return fmt.Errorf("%s is not a git checkout: %w", models, err)
	}
	if got := strings.TrimSpace(string(head)); got != commit {
		return fmt.Errorf("%s is at %s, the lock pins %s (%s) — check out the locked commit", models, got, commit, tag)
	}
	root := filepath.Join(models, "srlinux-yang-models")
	top, err := load(root)
	if err != nil {
		return err
	}
	idx := register.YangIndex{Schema: register.YangIndexSchema, Repository: repo, Tag: tag, Commit: commit,
		Generator: "go run ./hack/yangindex -models <checkout of " + repo + " at commit>",
		Paths:     map[string]register.IndexedPath{}}
	var missing []string
	for _, e := range register.SubscribeEntries() {
		p, err := resolve(top, e.Path)
		if err != nil {
			missing = append(missing, fmt.Sprintf("%s: %v", e.Path, err))
			continue
		}
		idx.Paths[e.Path] = p
	}
	if len(missing) > 0 {
		return fmt.Errorf("not in the pinned models %s:\n  %s", tag, strings.Join(missing, "\n  "))
	}
	if out == "" {
		out = filepath.Join("pkg", "register", "testdata", "yang-index-"+tag+".json")
	}
	b, err := json.MarshalIndent(idx, "", "  ")
	if err != nil {
		return err
	}
	if err := os.MkdirAll(filepath.Dir(out), 0o755); err != nil {
		return err
	}
	return os.WriteFile(out, append(b, '\n'), 0o644)
}

// lockedModels reads compatibilitySet.yangModels (part 2) from the lock file.
func lockedModels(lock string) (repo, tag, commit string, err error) {
	f, err := os.Open(lock)
	if err != nil {
		return "", "", "", err
	}
	defer f.Close()
	in := false
	sc := bufio.NewScanner(f)
	for sc.Scan() {
		l := sc.Text()
		t := strings.TrimSpace(l)
		switch {
		case strings.HasPrefix(l, "  yangModels:"):
			in = true
		case in && strings.HasPrefix(l, "  ") && !strings.HasPrefix(l, "    "):
			in = false
		case in && strings.HasPrefix(t, "repository:"):
			repo = strings.TrimSpace(strings.TrimPrefix(t, "repository:"))
		case in && strings.HasPrefix(t, "tag:"):
			tag = strings.TrimSpace(strings.TrimPrefix(t, "tag:"))
		case in && strings.HasPrefix(t, "commit:"):
			commit = strings.TrimSpace(strings.TrimPrefix(t, "commit:"))
		}
	}
	if repo == "" || tag == "" || commit == "" {
		return "", "", "", fmt.Errorf("%s: compatibilitySet.yangModels repository/tag/commit not found", lock)
	}
	return repo, tag, commit, sc.Err()
}

// load parses srl_nokia/models (minus tools) with ietf, iana and openconfig on
// the search path, and returns the top-level data nodes by name.
func load(root string) (map[string]*yang.Entry, error) {
	ms := yang.NewModules()
	var files []string
	err := filepath.Walk(root, func(p string, info os.FileInfo, err error) error {
		if err != nil {
			return err
		}
		if info.IsDir() {
			ms.AddPath(p)
			return nil
		}
		rel, _ := filepath.Rel(root, p)
		if strings.HasSuffix(p, ".yang") && strings.HasPrefix(rel, "srl_nokia/models/") && !strings.Contains(rel, "tools") {
			files = append(files, p)
		}
		return nil
	})
	if err != nil {
		return nil, err
	}
	sort.Strings(files)
	for _, f := range files {
		if err := ms.Read(f); err != nil {
			return nil, fmt.Errorf("read %s: %w", f, err)
		}
	}
	if errs := ms.Process(); len(errs) > 0 {
		return nil, fmt.Errorf("process: %v", errs)
	}
	top := map[string]*yang.Entry{}
	var names []string
	for n := range ms.Modules {
		if !strings.Contains(n, "@") {
			names = append(names, n)
		}
	}
	sort.Strings(names)
	for _, n := range names {
		for k, c := range yang.ToEntry(ms.Modules[n]).Dir {
			if prev, dup := top[k]; dup && prev != c {
				pm, _ := prev.InstantiatingModule()
				cm, _ := c.InstantiatingModule()
				if pm != cm {
					return nil, fmt.Errorf("top-level node %s is defined by %s and %s", k, pm, cm)
				}
			}
			top[k] = c
		}
	}
	return top, nil
}

// child finds a data node child, looking through choice and case.
func child(e *yang.Entry, name string) *yang.Entry {
	if c, ok := e.Dir[name]; ok && !c.IsChoice() && !c.IsCase() {
		return c
	}
	for _, n := range sortedDir(e) {
		c := e.Dir[n]
		if c.IsChoice() || c.IsCase() {
			if f := child(c, name); f != nil {
				return f
			}
		}
	}
	return nil
}

func sortedDir(e *yang.Entry) []string {
	ns := make([]string, 0, len(e.Dir))
	for n := range e.Dir {
		ns = append(ns, n)
	}
	sort.Strings(ns)
	return ns
}

func module(e *yang.Entry) (string, error) { return e.InstantiatingModule() }

func resolve(top map[string]*yang.Entry, path string) (register.IndexedPath, error) {
	var p register.IndexedPath
	var cur *yang.Entry
	for i, w := range register.SplitPath(path) {
		var next *yang.Entry
		if i == 0 {
			next = top[w.Name]
		} else {
			next = child(cur, w.Name)
		}
		if next == nil {
			return p, fmt.Errorf("no schema node %s", w.Name)
		}
		cur = next
		el, err := elem(cur)
		if err != nil {
			return p, err
		}
		p.Elements = append(p.Elements, el)
	}
	switch {
	case cur.IsLeaf() || cur.IsLeafList():
		p.Kind = "leaf"
		t := yangType(cur.Type)
		p.Type = &t
	case cur.IsList():
		p.Kind = "list"
	default:
		p.Kind = "container"
	}
	if p.Kind != "leaf" {
		if err := walk(cur, cur, nil, &p); err != nil {
			return p, err
		}
	}
	return p, nil
}

func elem(e *yang.Entry) (register.IndexElem, error) {
	m, err := module(e)
	if err != nil {
		return register.IndexElem{}, err
	}
	el := register.IndexElem{Name: e.Name, Module: m}
	if e.IsList() {
		for _, k := range strings.Fields(e.Key) {
			kl := e.Dir[k]
			if kl == nil || kl.Type == nil {
				return el, fmt.Errorf("list %s: key %s not found", e.Name, k)
			}
			el.Keys = append(el.Keys, register.IndexKey{Name: k, Type: yangType(kl.Type)})
		}
	}
	return el, nil
}

// walk collects every leaf beneath top (and every list, which the guard refuses).
func walk(top, e *yang.Entry, rel []register.IndexElem, p *register.IndexedPath) error {
	for _, n := range sortedDir(e) {
		c := e.Dir[n]
		if c.IsChoice() || c.IsCase() {
			if err := walk(top, c, rel, p); err != nil {
				return err
			}
			continue
		}
		el, err := elem(c)
		if err != nil {
			return err
		}
		el.Keys = nil
		r := append(append([]register.IndexElem(nil), rel...), el)
		switch {
		case c.IsLeaf() || c.IsLeafList():
			p.Leaves = append(p.Leaves, register.IndexedLeaf{Path: r, Type: yangType(c.Type)})
		case c.IsList():
			names := make([]string, len(r))
			for i, x := range r {
				names[i] = x.Name
			}
			p.Lists = append(p.Lists, strings.Join(names, "/"))
			if err := walk(top, c, r, p); err != nil {
				return err
			}
		default:
			if err := walk(top, c, r, p); err != nil {
				return err
			}
		}
	}
	return nil
}

func yangType(t *yang.YangType) register.YangType {
	out := register.YangType{Name: t.Name, Base: t.Kind.String()}
	switch t.Kind {
	case yang.Yunion:
		for _, m := range t.Type {
			out.Members = append(out.Members, yangType(m))
		}
	case yang.Yenum:
		out.Enums = t.Enum.Names()
	}
	return out
}

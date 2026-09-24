// Command migration-translator is the translator's CLI (T096; quickstart.md §5–§7): it reads a
// normalized service intent — one object or an array — from --file, and writes the fabric intent
// objects (fabric.agentic-netops.io/v1alpha1 Network, one YAML document per service) to stdout.
//
// A refusal writes nothing to stdout: the structured error {"error":"validation","causes":[…]} goes
// to stderr and the exit status is 1 (all-or-nothing, FR-045). A usage or configuration error exits
// 2. The site inventory and the fabric ASN come from FABRIC_NODE_MAP, FABRIC_PORT_MAP and FABRIC_ASN
// (formats: pkg/migration/site.go); unset, no node or port is checked.
//
// It calls exactly the path the intent-translator sidecar calls: migration.TranslateJSON.
package main

import (
	"flag"
	"fmt"
	"io"
	"os"

	"github.com/mairp/agentic-netops-srl/pkg/migration"
)

func main() { os.Exit(run(os.Args[1:], os.Stdin, os.Stdout, os.Stderr)) }

func run(args []string, stdin io.Reader, stdout, stderr io.Writer) int {
	fs := flag.NewFlagSet("migration-translator", flag.ContinueOnError)
	fs.SetOutput(stderr)
	file := fs.String("file", "", "the normalized service intent JSON (an object or an array); - reads stdin")
	fs.Usage = func() {
		fmt.Fprintln(stderr, "usage: migration-translator --file <path|->")
		fs.PrintDefaults()
	}
	if err := fs.Parse(args); err != nil {
		return 2
	}
	if *file == "" || fs.NArg() > 0 {
		fs.Usage()
		return 2
	}
	var data []byte
	var err error
	if *file == "-" {
		data, err = io.ReadAll(stdin)
	} else {
		data, err = os.ReadFile(*file)
	}
	if err != nil {
		fmt.Fprintf(stderr, "migration-translator: reading the input: %v\n", err)
		return 2
	}
	opt, err := migration.OptionsFromEnv()
	if err != nil {
		_, _ = stderr.Write(migration.MarshalError(&migration.ValidationError{Causes: []string{err.Error()}}))
		return 2
	}
	res, err := migration.TranslateJSON(data, opt)
	if err != nil {
		_, _ = stderr.Write(migration.MarshalError(err))
		return 1
	}
	if _, err := io.WriteString(stdout, res.YAML); err != nil {
		fmt.Fprintf(stderr, "migration-translator: writing the output: %v\n", err)
		return 1
	}
	return 0
}

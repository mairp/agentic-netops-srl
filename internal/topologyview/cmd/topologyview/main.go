// Command topologyview is the Go half of the topology generator step (T131; FR-094, FR-096, R-10):
//
//	topologyview generate --topology lab/topology.clab.yml --mgmt-cidr 172.25.25.0/24 \
//	    --drawio-dir <clab-io-draw output> --out <dir> [--generator-ref <pinned image>]
//
// scripts/lib/observability.sh runs the pinned clab-io-draw over the inventory, then this over the
// same inventory file and clab-io-draw's output; see internal/topologyview.
package main

import (
	"flag"
	"fmt"
	"os"

	"github.com/mairp/agentic-netops-srl/internal/topologyview"
)

func main() {
	if len(os.Args) < 2 || os.Args[1] != "generate" {
		fmt.Fprintln(os.Stderr, "usage: topologyview generate --topology <clab.yml> --mgmt-cidr <cidr> --drawio-dir <dir> --out <dir> [--generator-ref <image>]")
		os.Exit(2)
	}
	fs := flag.NewFlagSet("generate", flag.ExitOnError)
	var o topologyview.Options
	fs.StringVar(&o.Topology, "topology", "", "containerlab inventory (the file clab-io-draw read)")
	fs.StringVar(&o.MgmtCIDR, "mgmt-cidr", "172.25.25.0/24", "management network (MGMT_CIDR)")
	fs.StringVar(&o.DrawioDir, "drawio-dir", "", "clab-io-draw output directory")
	fs.StringVar(&o.OutDir, "out", "", "output directory")
	fs.StringVar(&o.GeneratorRef, "generator-ref", "", "pinned clab-io-draw image reference (provenance)")
	_ = fs.Parse(os.Args[2:])
	if o.Topology == "" || o.DrawioDir == "" || o.OutDir == "" {
		fs.Usage()
		os.Exit(2)
	}
	if err := topologyview.Generate(o); err != nil {
		fmt.Fprintln(os.Stderr, "topologyview:", err)
		os.Exit(1)
	}
}

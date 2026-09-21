#!/usr/bin/env bash
# the same line, under tests/: the gate may open a management session (FR-108)
gnmic -a clab-agentic-netops-leaf1:57400 --skip-verify capabilities

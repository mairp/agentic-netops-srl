#!/usr/bin/env bash
# LabReady probe (planted: a device client outside tests/ — must fail)
gnmic -a clab-agentic-netops-leaf1:57400 --skip-verify capabilities

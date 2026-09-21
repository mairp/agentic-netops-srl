#!/usr/bin/env bash
# LabReady is a credential-less port accept, never a gNMI call (T034, AD-57).
timeout 2 bash -c "</dev/tcp/${node_addr}/57400"

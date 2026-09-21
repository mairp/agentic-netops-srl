#!/usr/bin/env bash
docker exec -it clab-agentic-netops-leaf1 sr_cli show version
sshpass -p "$PW" ssh admin@172.25.25.11 show version

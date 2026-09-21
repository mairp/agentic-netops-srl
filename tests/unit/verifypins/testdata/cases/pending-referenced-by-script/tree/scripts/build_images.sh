#!/usr/bin/env bash
docker build -f docker/Dockerfile.allocator -t "allocator:${HASH}" agents

#!/bin/zsh
set -eu
cd "${0:A:h}"
mkdir -p .build
python3 - <<'CHECK'
import socket
for port in (18796, 18797):
    with socket.socket() as s:
        s.bind(('127.0.0.1', port))
CHECK
python3 Source/test_server.py &
TEST_SERVER_PID=$!
trap 'kill "$TEST_SERVER_PID" 2>/dev/null || true' EXIT
swiftc -parse-as-library Source/Monitor.swift Source/Tests.swift -o .build/tests
.build/tests

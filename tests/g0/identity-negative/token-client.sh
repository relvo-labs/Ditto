#!/usr/bin/env bash
# A client the launcher starts. It reads its one-use token from the descriptor
# the launcher left open and prints it, so the negative case can try to use a
# real token from a process the launcher never started.
set -euo pipefail
read -r token <&"${DITTO_CORE_TOKEN_FD:-3}"
echo "LAUNCHED_TOKEN $token"
sleep 30

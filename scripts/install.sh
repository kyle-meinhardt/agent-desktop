#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

if [[ "$(uname -s)" != Darwin || "$(uname -m)" != arm64 ]]; then
  echo 'Agent Desktop requires an Apple silicon Mac.' >&2
  exit 1
fi
if [[ ! -t 0 || "$EUID" == 0 || "$(id -un)" == agent ]]; then
  echo 'Run this installer interactively from your regular macOS account, without sudo.' >&2
  exit 1
fi
command -v brew >/dev/null || { echo 'Install Homebrew and put brew on PATH.' >&2; exit 1; }
command -v codex >/dev/null || { echo 'Install Codex and put codex on PATH.' >&2; exit 1; }
xcode-select -p >/dev/null || { echo 'Install Xcode or the macOS Command Line Tools.' >&2; exit 1; }

if ! command -v cmake >/dev/null || ! brew list --versions openssl@4 >/dev/null; then
  brew install cmake openssl@4
fi
if ! python3 -c 'import sys; sys.exit(sys.version_info < (3, 11))' 2>/dev/null; then
  brew install python
fi
if [[ -z "${SIGN_IDENTITY:-}" ]]; then
  bash scripts/create-signing-identity.sh
fi
bash scripts/build.sh
exec ./dist/agent-desktop setup

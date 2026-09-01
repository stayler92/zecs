#!/usr/bin/env bash
set -euo pipefail

export PATH="${HOME}/.grok/bin:${HOME}/.local/bin:${PATH}"

echo "zecs workspace"
echo "Zig $(command -v zig >/dev/null && zig version || echo 'not found')"

if command -v grok >/dev/null 2>&1; then
  echo "Grok Build: $(grok --version 2>/dev/null || echo installed)"
else
  echo "Grok Build CLI is not on PATH yet. Open a new terminal or re-run .devcontainer/post-create.sh"
fi

if [[ -z "${XAI_API_KEY:-}" ]]; then
  echo
  echo "No XAI_API_KEY in this environment."
  echo "  • Codespaces: Settings → Secrets → Codespaces → New secret named XAI_API_KEY"
  echo "  • Interactive login: grok login --device-auth"
fi

echo
echo "Verify: zig fmt --check . && zig build test && zig build example"

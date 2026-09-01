#!/usr/bin/env bash
set -euo pipefail

ZIG_VERSION="${ZIG_VERSION:-0.16.0}"
INSTALL_ROOT="/usr/local"
USER_BIN="${HOME}/.local/bin"
mkdir -p "${USER_BIN}"

arch="$(uname -m)"
case "${arch}" in
  x86_64|amd64) zig_arch="x86_64" ;;
  aarch64|arm64) zig_arch="aarch64" ;;
  *)
    echo "Unsupported architecture: ${arch}" >&2
    exit 1
    ;;
esac

echo "==> Installing Zig ${ZIG_VERSION} (${zig_arch}-linux)"
workdir="$(mktemp -d)"
trap 'rm -rf "${workdir}"' EXIT

url="https://ziglang.org/download/${ZIG_VERSION}/zig-${zig_arch}-linux-${ZIG_VERSION}.tar.xz"
curl -fsSL "${url}" -o "${workdir}/zig.tar.xz"
tar -xJf "${workdir}/zig.tar.xz" -C "${workdir}"
zig_dir="$(find "${workdir}" -maxdepth 1 -type d -name 'zig-*' | head -n 1)"

sudo rm -rf "${INSTALL_ROOT}/zig"
sudo mv "${zig_dir}" "${INSTALL_ROOT}/zig"
sudo ln -sfn "${INSTALL_ROOT}/zig/zig" /usr/local/bin/zig
zig version

echo "==> Installing matching ZLS if a release exists"
zls_ok=0
if curl -fsSL "https://github.com/zigtools/zls/releases/download/${ZIG_VERSION}/zls-${zig_arch}-linux.tar.xz" -o "${workdir}/zls.tar.xz"; then
  mkdir -p "${workdir}/zls"
  tar -xJf "${workdir}/zls.tar.xz" -C "${workdir}/zls"
  zls_bin="$(find "${workdir}/zls" -type f -name zls | head -n 1)"
  if [[ -n "${zls_bin}" ]]; then
    sudo install -m 0755 "${zls_bin}" /usr/local/bin/zls
    zls --version || true
    zls_ok=1
  fi
fi
if [[ "${zls_ok}" -eq 0 ]]; then
  echo "No matching ZLS ${ZIG_VERSION} release found; the Zig VS Code extension will fetch ZLS."
fi

echo "==> Installing Grok Build CLI"
curl -fsSL https://x.ai/cli/install.sh | bash

for rc in "${HOME}/.bashrc" "${HOME}/.zshrc"; do
  if [[ -f "${rc}" ]] && ! grep -q '.grok/bin' "${rc}"; then
    {
      echo ''
      echo '# Grok Build CLI'
      echo 'export PATH="$HOME/.grok/bin:$HOME/.local/bin:$PATH"'
    } >> "${rc}"
  fi
done

export PATH="${HOME}/.grok/bin:${USER_BIN}:${PATH}"
if command -v grok >/dev/null 2>&1; then
  grok --version || true
else
  echo "Grok CLI installed but not yet on PATH in this shell. Open a new terminal."
fi

echo
echo "Setup complete."
echo "  zig version : $(zig version)"
echo "  Next: set XAI_API_KEY (Codespaces secret) or run: grok login --device-auth"
echo "  Then: zig fmt --check . && zig build test && zig build example"

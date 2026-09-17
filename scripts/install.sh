#!/usr/bin/env bash
# install.sh — one-shot bootstrap of Michelli GitHub App git auth on a Pi.
#
# This is the single-command path: it asks for the Installation ID (with the
# current one as the default) and the App's PEM, then does everything else —
# fetching the helper scripts, writing the conf, installing the credential
# helper, and smoke-testing against a private repo.
#
#   curl -fsSL -o /tmp/pga-install.sh https://github.com/GTMichelli-Dev/pi-git-auth/releases/latest/download/install.sh
#   bash /tmp/pga-install.sh
#
# Two things it deliberately does not need:
#
#   - `git`. It takes the release tarball over curl, so it works on a Pi OS
#     Lite box where git isn't installed yet (setup-pi-github-app.sh pulls in
#     what it needs). The older pi-connect-github-auth.sh apt-installs git
#     purely to clone this repo; here that round trip is gone.
#   - `</dev/tty` on the command line. Every prompt reads from /dev/tty
#     directly, so pasting the command into Raspberry Pi Connect's web shell
#     can't leave the prompts eating the rest of the paste buffer. That
#     incantation was the single most common way the paste flow went wrong.
#
# Non-interactive, for a scripted fleet rollout:
#
#   sudo bash install.sh --install-id 145563826 --pem /tmp/michelli-app.pem
#
# Pin a version instead of taking the newest release:
#
#   PGA_VERSION=1.1.0 bash /tmp/pga-install.sh
#
# Idempotent — re-run it to refresh the helpers or replace the key.

set -euo pipefail

REPO="GTMichelli-Dev/pi-git-auth"
INSTALL_ID_DEFAULT="145563826"   # current GTMichelli-Dev installation
VERSION="${PGA_VERSION:-latest}"

INSTALL_ID=""
PEM_SRC=""
PEM_TMP=""
WORK_DIR=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --install-id) INSTALL_ID="$2"; shift 2 ;;
    --pem)        PEM_SRC="$2";    shift 2 ;;
    --version)    VERSION="$2";    shift 2 ;;
    -h|--help)
      cat <<EOF
Usage: bash install.sh [options]

With no options it prompts for everything it needs.

  --install-id <N>   Installation ID (default: $INSTALL_ID_DEFAULT)
  --pem <path>       PEM file to install, instead of pasting it
  --version <X.Y.Z>  Release to take the scripts from (default: latest)

Environment:
  PGA_VERSION        Same as --version.
EOF
      exit 0 ;;
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
done

cleanup() {
  if [[ -n "$PEM_TMP" && -f "$PEM_TMP" ]]; then
    shred -u "$PEM_TMP" 2>/dev/null || rm -f "$PEM_TMP"
  fi
  [[ -n "$WORK_DIR" && -d "$WORK_DIR" ]] && rm -rf "$WORK_DIR"
  return 0
}
trap cleanup EXIT

# Run the privileged parts through sudo when we aren't already root, so the
# same command works whether or not the operator remembered the sudo.
SUDO=""
if [[ "$(id -u)" -ne 0 ]]; then
  command -v sudo >/dev/null 2>&1 || { echo "Not root and no sudo available." >&2; exit 1; }
  SUDO="sudo"
fi

# Prompts read from the terminal, not stdin: stdin may be the tail of a
# bracketed paste, or the script itself under `curl | bash`.
# The subshell probes it first: /dev/tty can exist and still fail to open
# (cron, a detached session), and a failed `exec` redirect would take the
# script down with it.
if (exec 3</dev/tty) 2>/dev/null; then
  exec 3</dev/tty
else
  exec 3<&0
fi

echo "== Michelli GitHub App auth — one-shot install =="
echo

# 1. Locate the helper scripts. Extracted from the release tarball they sit
# beside this file already; downloaded on its own, this script goes and gets
# them. setup-pi-github-app.sh refuses to run without both helpers next to
# it, which is what makes a lone copy of it useless.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd || echo "")"
SRC_DIR=""
if [[ -n "$SCRIPT_DIR" \
      && -f "$SCRIPT_DIR/setup-pi-github-app.sh" \
      && -f "$SCRIPT_DIR/michelli-github-app-token.sh" \
      && -f "$SCRIPT_DIR/git-credential-michelli.sh" ]]; then
  SRC_DIR="$SCRIPT_DIR"
  echo "Using the scripts alongside this one ($SRC_DIR)."
else
  command -v curl >/dev/null 2>&1 || {
    echo "Installing curl..."
    $SUDO apt-get update -y -qq
    $SUDO apt-get install -y -qq curl
  }

  if [[ "$VERSION" == "latest" ]]; then
    TARBALL_URL="https://github.com/$REPO/releases/latest/download/pi-git-auth.tar.gz"
  else
    TARBALL_URL="https://github.com/$REPO/releases/download/v${VERSION#v}/pi-git-auth.tar.gz"
  fi

  WORK_DIR="$(mktemp -d)"
  echo "Fetching the $VERSION release (public repo, no auth needed)..."
  if ! curl -fsSL -o "$WORK_DIR/pi-git-auth.tar.gz" "$TARBALL_URL"; then
    echo "Could not download $TARBALL_URL" >&2
    echo "Check the Pi's internet connection, or pass --version with a release that exists." >&2
    exit 1
  fi
  tar -xzf "$WORK_DIR/pi-git-auth.tar.gz" -C "$WORK_DIR"
  SRC_DIR="$WORK_DIR"

  for f in setup-pi-github-app.sh michelli-github-app-token.sh git-credential-michelli.sh; do
    [[ -f "$SRC_DIR/$f" ]] || { echo "The release tarball is missing $f." >&2; exit 1; }
  done
fi

# 2. Installation ID. Enter accepts the baked-in default, which is right for
# every Pi on the current org installation.
if [[ -z "$INSTALL_ID" ]]; then
  echo
  echo "Installation ID — the number at the end of the App's install URL:"
  echo "  https://github.com/organizations/GTMichelli-Dev/settings/installations/<NUMBER>"
  read -r -u 3 -p "Installation ID [$INSTALL_ID_DEFAULT]: " INSTALL_ID || INSTALL_ID=""
  INSTALL_ID="${INSTALL_ID%$'\r'}"
  INSTALL_ID="${INSTALL_ID//[^0-9]/}"
  INSTALL_ID="${INSTALL_ID:-$INSTALL_ID_DEFAULT}"
fi
echo "Using Installation ID $INSTALL_ID."

# 3. The PEM. Everything before the BEGIN line is ignored and the capture
# stops on its own at END — so a tech pastes the key and is done, with no
# terminator to remember.
if [[ -z "$PEM_SRC" ]]; then
  echo
  echo "Now paste the App's private key (.pem), BEGIN and END lines included."
  echo "It stops by itself at the END line — nothing else to type."
  echo
  umask 077
  PEM_TMP="$(mktemp /tmp/michelli-app-XXXXXX.pem)"
  started=0
  while IFS= read -r -u 3 line; do
    line="${line%$'\r'}"        # a key copied on Windows arrives CRLF-terminated
    line="${line//$'\e'/}"        # ESC byte from a bracketed paste
    line="${line//[[]200~/}"      # ...and the markers Pi Connect leaves behind
    line="${line//[[]201~/}"
    if [[ $started -eq 0 ]]; then
      case "$line" in *"-----BEGIN"*) started=1 ;; *) continue ;; esac
    fi
    printf '%s\n' "$line" >> "$PEM_TMP"
    case "$line" in *"-----END"*"PRIVATE KEY-----") break ;; esac
  done

  if [[ $started -eq 0 ]]; then
    echo "No key found in what you pasted (no BEGIN line)." >&2
    exit 1
  fi
  if ! grep -q -- "-----END" "$PEM_TMP"; then
    echo "The key looks truncated — no END line arrived." >&2
    exit 1
  fi
  PEM_SRC="$PEM_TMP"
else
  [[ -r "$PEM_SRC" ]] || { echo "Cannot read PEM at $PEM_SRC" >&2; exit 1; }
fi

# Catch a mangled paste here rather than three steps later as a "Bad
# credentials" response from GitHub.
if command -v openssl >/dev/null 2>&1; then
  if ! openssl rsa -in "$PEM_SRC" -noout -check >/dev/null 2>&1; then
    echo "That is not a valid RSA private key. Re-copy the .pem and try again." >&2
    exit 1
  fi
  echo "Key looks valid."
fi

# 4. Hand off to the installer, which does the real work.
echo
$SUDO bash "$SRC_DIR/setup-pi-github-app.sh" \
  --install-id "$INSTALL_ID" \
  --pem "$PEM_SRC"

echo
echo "Done. This Pi can now clone private GTMichelli-Dev repos."
if [[ -n "$PEM_TMP" ]]; then
  echo "The pasted key was shredded from /tmp; the installed copy lives at"
  echo "/etc/michelli/github-app.pem."
fi

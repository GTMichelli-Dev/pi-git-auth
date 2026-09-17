#!/usr/bin/env bash
# fetch-release.sh — download one asset from a private GTMichelli-Dev release,
# using the App token this box already knows how to mint.
#
#   fetch-release foundation-web-linux-x64.tar.gz
#   fetch-release --repo camera-capture-service linux-arm64.tar.gz
#   fetch-release --list
#
# Installed to /usr/local/bin/fetch-release (and /usr/local/bin/fetch_release)
# by setup-pi-github-app.sh.
#
# It replaces a shell function that the service repos' release notes asked
# operators to paste into every new session. That function existed because of a
# chicken-and-egg problem: a box could not download a script from a private repo
# until it could authenticate to one. Once pi-git-auth is installed that is no
# longer true, so the notes' command can just be a command.
#
# Uses jq rather than python3: setup-pi-github-app.sh apt-installs jq for the
# token minter, so it is guaranteed present on any box this landed on, which
# python3 is not.

set -euo pipefail

OWNER="GTMichelli-Dev"
REPO="${FETCH_RELEASE_REPO:-$OWNER/foundation}"
VERSION="latest"
OUT=""
ASSET=""
LIST=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    -r|--repo)    REPO="$2"; shift 2 ;;
    -v|--version) VERSION="$2"; shift 2 ;;
    -o|--output)  OUT="$2"; shift 2 ;;
    -l|--list)    LIST=1; shift ;;
    -h|--help)
      cat <<EOF
Usage: fetch-release [options] <asset>

Downloads one asset from a GTMichelli-Dev release into the current directory.
The asset name can be given in full, or as an ending unique among the release's
assets ("linux-arm64.tar.gz").

  -r, --repo <name>       Repo to fetch from, bare or owner/name
                          (default: $REPO)
  -v, --version <X.Y.Z>   Release to take it from (default: the latest)
  -o, --output <path>     Write here instead of ./<asset name>
  -l, --list              List the release's assets and exit

Environment:
  FETCH_RELEASE_REPO      Same as --repo.
  GH_TOKEN / GITHUB_TOKEN Token to use when this box mints none of its own.

The token comes from michelli-github-app-token, or from git's credential
helper, or it asks. See https://github.com/GTMichelli-Dev/pi-git-auth
EOF
      exit 0 ;;
    -*) echo "Unknown option: $1" >&2; exit 2 ;;
    *)
      [[ -z "$ASSET" ]] || { echo "Only one asset at a time (got '$ASSET' and '$1')." >&2; exit 2; }
      ASSET="$1"; shift ;;
  esac
done

# A bare name is assumed to be one of ours, since that is the only place these
# tokens are any use.
[[ "$REPO" == */* ]] || REPO="$OWNER/$REPO"

if [[ $LIST -eq 0 && -z "$ASSET" ]]; then
  echo "Which asset? Try: fetch-release --list" >&2
  exit 2
fi

for dep in curl jq; do
  command -v "$dep" >/dev/null 2>&1 \
    || { echo "fetch-release needs $dep (sudo apt-get install -y $dep)" >&2; exit 1; }
done

# 1. A token. The minter is the normal answer on a box that has been through
# the pi-git-auth bootstrap. The git fallback is asked *with the repo path*:
# the credential helper is registered for https://github.com/GTMichelli-Dev, and
# git only consults a path-scoped credential config when the request carries a
# matching path - a bare host=github.com query silently matches nothing.
TOKEN="$(michelli-github-app-token 2>/dev/null)" \
  || TOKEN="$(printf 'protocol=https\nhost=github.com\npath=%s.git\n\n' "$REPO" \
       | GIT_TERMINAL_PROMPT=0 git credential fill 2>/dev/null \
       | sed -n 's/^password=//p')"

# Env last of the silent sources, for a workstation with no helper set up:
#   GH_TOKEN=\$(gh auth token) fetch-release foundation-web-linux-x64.tar.gz
[[ -n "$TOKEN" ]] || TOKEN="${GH_TOKEN:-${GITHUB_TOKEN:-}}"

if [[ -z "$TOKEN" ]]; then
  if [[ -r /dev/tty ]]; then
    echo "No GitHub credential on this box. Run the pi-git-auth bootstrap to" >&2
    echo "fix that permanently: https://github.com/GTMichelli-Dev/pi-git-auth" >&2
    read -rsp "GitHub token (Contents: Read on $REPO): " TOKEN </dev/tty
    echo
  fi
fi
[[ -n "$TOKEN" ]] || { echo "No token, nothing to do." >&2; exit 1; }

# 2. The release.
if [[ "$VERSION" == "latest" ]]; then
  REL_URL="https://api.github.com/repos/$REPO/releases/latest"
else
  REL_URL="https://api.github.com/repos/$REPO/releases/tags/v${VERSION#v}"
fi

JSON="$(curl -fsSL -H "Authorization: Bearer $TOKEN" "$REL_URL")" || {
  echo "GitHub would not serve $REL_URL." >&2
  echo "Either the token has no read access to $REPO, or that release does not exist." >&2
  exit 1
}

TAG="$(printf '%s' "$JSON" | jq -r '.tag_name')"

if [[ $LIST -eq 1 ]]; then
  echo "$REPO $TAG:"
  printf '%s' "$JSON" | jq -r '.assets[] | "  \(.name)  \((.size/1048576*10|floor)/10)MB"'
  exit 0
fi

# 3. Resolve the asset. Exact name first; failing that, a unique ending, so
# "linux-arm64.tar.gz" finds the one asset that ends that way without anyone
# having to type the product name twice.
NAME="$(printf '%s' "$JSON" | jq -r --arg n "$ASSET" '.assets[] | select(.name == $n) | .name')"
if [[ -z "$NAME" ]]; then
  MATCHES="$(printf '%s' "$JSON" | jq -r --arg n "$ASSET" '.assets[] | select(.name | endswith($n)) | .name')"
  COUNT="$(printf '%s' "$MATCHES" | grep -c . || true)"
  if [[ "$COUNT" -eq 1 ]]; then
    NAME="$MATCHES"
  elif [[ "$COUNT" -gt 1 ]]; then
    echo "'$ASSET' matches more than one asset in $REPO $TAG:" >&2
    printf '  %s\n' $MATCHES >&2
    exit 1
  else
    echo "No asset matching '$ASSET' in $REPO $TAG. It has:" >&2
    printf '%s' "$JSON" | jq -r '.assets[] | "  \(.name)"' >&2
    exit 1
  fi
fi

ID="$(printf '%s' "$JSON" | jq -r --arg n "$NAME" '.assets[] | select(.name == $n) | .id')"
OUT="${OUT:-$NAME}"

# 4. Download. --progress-bar rather than silence: these are 150MB+ packages
# over whatever link a scale house has, and a silent terminal for four minutes
# looks like a hang.
echo "$REPO $TAG -> $OUT"
curl -fL --progress-bar \
  -H "Authorization: Bearer $TOKEN" \
  -H "Accept: application/octet-stream" \
  -o "$OUT" \
  "https://api.github.com/repos/$REPO/releases/assets/$ID"

#!/bin/sh
# cheznoam one-line install:  curl -fsSL https://raw.githubusercontent.com/noamross/setup/main/setup.sh | sh
# Also runs from a clone or via `gh api` (see README). Re-run to update.
#
# Auth to the private repo, first that works:
#   existing   git already authenticates (gh login, credential helper, SSH key): no prompt
#   browser    GitHub device flow: open a URL on any device, enter a code
#   token      paste a fine-grained PAT (noamross/cheznoam, contents: read)
# The token stays in this process: never in a URL, .git/config, credential store or history.
#
# Env (all optional): CHEZNOAM_AUTH=existing|browser|token, CHEZNOAM_TOKEN, CHEZNOAM_ROLE,
# CHEZNOAM_SPARSE=true (check out only home/ and .chezmoiroot, e.g. on the CDC VAP; default: full clone),
# plus the init settings read by .chezmoi.toml.tmpl (CHEZNOAM_CONTEXT, CHEZNOAM_NO_SUDO, ...).
# Test overrides: CHEZNOAM_REPO, CHEZNOAM_GITHUB, CHEZNOAM_CLIENT_ID.
set -eu

repo=${CHEZNOAM_REPO:-https://github.com/noamross/cheznoam.git}
ssh_repo=git@github.com:noamross/cheznoam.git
github=${CHEZNOAM_GITHUB:-https://github.com}
# GitHub App "cheznoam": installed only on noamross/cheznoam, contents read-only. Public value.
client_id=${CHEZNOAM_CLIENT_ID:-Iv23li2ApX7NyN8n420i}
src=$HOME/.local/share/chezmoi
bin=$HOME/.local/bin
cz_ver=2.73.3
# From chezmoi_${cz_ver}_checksums.txt
cz_sum_linux_amd64=6e5827598cbfc02d132b04f95b5ea10efb5b79230e2a4a0e52df4af144a8ee9f
cz_sum_linux_arm64=c9e6a6e71eb5291018e161a8426d7c313cd2e8553c2ca4029511fec2a33bc28c

say() { printf '%s\n' "$*" >&2; }
die() { say "setup: $*"; exit 1; }
# Prompts read the terminal: under `curl | sh`, stdin is this script
ask() { [ -r /dev/tty ] || die "no terminal to ask: $1 (set it in the environment)"; printf '%s' "$1" >/dev/tty; read -r REPLY </dev/tty; }
need() { command -v "$1" >/dev/null 2>&1 || die "needs $1"; }
need git
need curl

export GIT_TERMINAL_PROMPT=0
# git with the token from the environment only; clears any other helper (e.g. a gh login as nmrcdc)
tgit() { git -c credential.helper= -c 'credential.helper=!f() { echo username=x-access-token; echo "password=$CHEZNOAM_GIT_TOKEN"; }; f' "$@"; }
mode=${CHEZNOAM_AUTH:-}
token=

# 1. Existing credentials
if [ -z "$mode" ] || [ "$mode" = existing ]; then
  if git ls-remote "$repo" HEAD >/dev/null 2>&1; then
    mode=existing
  elif [ -z "${CHEZNOAM_REPO:-}" ] && GIT_SSH_COMMAND='ssh -o BatchMode=yes -o ConnectTimeout=10' \
      git ls-remote "$ssh_repo" HEAD >/dev/null 2>&1; then
    mode=existing repo=$ssh_repo
  elif [ "$mode" = existing ]; then
    die "git cannot read $repo with existing credentials"
  fi
fi
if [ -z "$mode" ]; then
  ask "Authenticate to GitHub: [1] browser (device code)  [2] paste token: "
  case $REPLY in 1 | b*) mode=browser ;; 2 | t*) mode=token ;; *) die "no choice" ;; esac
fi

# 2. Token
case $mode in
existing) ;;
token)
  token=${CHEZNOAM_TOKEN:-}
  if [ -z "$token" ]; then
    [ -r /dev/tty ] || die "no terminal to ask for a token (set CHEZNOAM_TOKEN)"
    printf 'Token (fine-grained, noamross/cheznoam contents:read; input hidden): ' >/dev/tty
    stty -echo </dev/tty; read -r token </dev/tty || true; stty echo </dev/tty; echo >/dev/tty
  fi
  ;;
browser)
  case $client_id in REPLACE_*) die "browser login not configured yet (no GitHub App client ID); use a token" ;; esac
  json() { sed -n "s/.*\"$1\" *: *\"\{0,1\}\([^\",}]*\).*/\1/p"; }
  r=$(curl -fsS -X POST -H 'Accept: application/json' -d "client_id=$client_id" "$github/login/device/code") \
    || die "device code request failed"
  device=$(printf %s "$r" | json device_code)
  interval=$(printf %s "$r" | json interval)
  expires=$(printf %s "$r" | json expires_in)
  [ -n "$device" ] || die "no device code from GitHub"
  say "Open $(printf %s "$r" | json verification_uri) on any device and enter: $(printf %s "$r" | json user_code)"
  waited=0
  while :; do
    sleep "${interval:-5}"; waited=$((waited + ${interval:-5}))
    [ "$waited" -le "${expires:-900}" ] || die "code expired; run again"
    r=$(curl -fsS -X POST -H 'Accept: application/json' \
      -d "client_id=$client_id&device_code=$device&grant_type=urn:ietf:params:oauth:grant-type:device_code" \
      "$github/login/oauth/access_token") || die "token request failed"
    token=$(printf %s "$r" | json access_token)
    [ -n "$token" ] && break
    case $(printf %s "$r" | json error) in
    authorization_pending) ;;
    slow_down) interval=$((${interval:-5} + 5)) ;;
    *) die "login failed: $(printf %s "$r" | json error)" ;;
    esac
  done
  say "Authorized."
  ;;
*) die "CHEZNOAM_AUTH must be existing, browser or token" ;;
esac
CHEZNOAM_GIT_TOKEN=$token
export CHEZNOAM_GIT_TOKEN
unset CHEZNOAM_TOKEN token
g() { if [ "$mode" = existing ]; then git "$@"; else tgit "$@"; fi; }

# 3. Source: full clone to edit and push from; sparse (home/ and .chezmoiroot only, no docs or
# tests downloaded) with CHEZNOAM_SPARSE=true. Undo later: git -C ~/.local/share/chezmoi sparse-checkout disable
if [ -d "$src/.git" ]; then
  g -C "$src" pull -q --ff-only || die "update of $src failed"
else
  [ ! -e "$src" ] || [ -z "$(ls -A "$src")" ] || die "$src exists and is not a git clone"
  case ${CHEZNOAM_SPARSE:-} in true | 1 | yes) sparse=1 ;; *) sparse= ;; esac
  if ! g clone -q --no-checkout ${sparse:+--filter=blob:none} "$repo" "$src"; then
    rm -rf "$src"; die "clone failed (wrong or expired token?)"
  fi
  [ -z "$sparse" ] || git -C "$src" sparse-checkout set --no-cone '/.chezmoiroot' '/home/'
  g -C "$src" checkout -q || { rm -rf "$src"; die "checkout failed"; }
fi
unset CHEZNOAM_GIT_TOKEN

# 4. chezmoi, pinned and checksummed
cz=$bin/chezmoi
if [ "$("$cz" --version 2>/dev/null | cut -d, -f1)" != "chezmoi version v$cz_ver" ]; then
  os=$(uname -s | tr A-Z a-z)
  case $(uname -m) in x86_64 | amd64) arch=amd64 ;; aarch64 | arm64) arch=arm64 ;; *) die "unsupported arch $(uname -m)" ;; esac
  if [ "$os" = darwin ]; then
    command -v brew >/dev/null 2>&1 || die "on macOS install Homebrew first"
    brew install -q chezmoi; cz=$(command -v chezmoi)
  else
    eval "sum=\${cz_sum_${os}_$arch:-}"
    [ -n "$sum" ] || die "no pinned chezmoi for ${os}_$arch"
    tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
    curl -fsSLo "$tmp/cz.tgz" "https://github.com/twpayne/chezmoi/releases/download/v$cz_ver/chezmoi_${cz_ver}_${os}_$arch.tar.gz"
    if command -v sha256sum >/dev/null 2>&1; then got=$(sha256sum "$tmp/cz.tgz" | cut -d' ' -f1); else got=$(shasum -a 256 "$tmp/cz.tgz" | cut -d' ' -f1); fi
    [ "$got" = "$sum" ] || die "chezmoi checksum mismatch: $got"
    mkdir -p "$bin"; tar -xzf "$tmp/cz.tgz" -C "$bin" chezmoi
  fi
fi

# 5. Apply
role=${CHEZNOAM_ROLE:-}
if [ -z "$role" ] && [ ! -f "$HOME/.config/chezmoi/chezmoi.toml" ]; then
  ask "Role [mac-workstation, chromebook-container, linux-workstation-ssh, server, minimal-shell]: "; role=$REPLY
fi
"$cz" init --apply --no-tty ${role:+--promptChoice "role=$role"}
say "Done. Open a new shell. Re-run this script to update."

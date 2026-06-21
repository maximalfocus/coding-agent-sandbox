#!/usr/bin/env bash
# First-run setup for macOS / Linux — the Unix counterpart of setup-windows.cmd.
# Checks Docker, creates and fills in .env (workspace + generated password), then builds and
# starts the sandbox. Day-to-day after this: just ./run.sh
#
#   ./setup.sh
set -euo pipefail
cd "$(dirname "$0")"

say() { printf '%s\n' "$@"; }

# Provenance marker — written iff WE install OrbStack here, so uninstall.sh can tell a
# sandbox-installed engine from a pre-existing one and only remove the former by default.
ENGINE_MARKER="$HOME/.coding-agent-sandbox/installed-orbstack"

# --- Docker engine (macOS: bootstrap Homebrew + OrbStack if missing; Linux: guide) ----------------
if ! command -v docker >/dev/null 2>&1; then
    say "Docker isn't installed."
    if [ "$(uname -s)" = "Darwin" ]; then
        # 1. Ensure Homebrew — the one thing we can't install any other way.
        if ! command -v brew >/dev/null 2>&1; then
            read -r -p "Homebrew isn't installed. Install it now? (runs the official installer) [y/N]: " a
            case "$a" in
                y|Y)
                    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)" \
                        || { say "Homebrew install failed — install it manually (https://brew.sh), then re-run ./setup.sh"; exit 1; }
                    # Put brew on PATH for the rest of this run (Apple Silicon prefix, then Intel).
                    for p in /opt/homebrew/bin/brew /usr/local/bin/brew; do
                        if [ -x "$p" ]; then eval "$("$p" shellenv)"; break; fi
                    done ;;
                *)  say "Install Homebrew (https://brew.sh) or OrbStack/Docker Desktop directly, then re-run ./setup.sh"; exit 1 ;;
            esac
            command -v brew >/dev/null 2>&1 \
                || { say "Homebrew installed but not on PATH yet — open a new terminal and re-run ./setup.sh"; exit 1; }
        fi
        # 2. Install OrbStack (marker lets uninstall.sh remove only the engine we installed).
        read -r -p "Install OrbStack via Homebrew now? [y/N]: " a
        case "$a" in
            y|Y) brew install --cask orbstack \
                    && { mkdir -p "$(dirname "$ENGINE_MARKER")"; : > "$ENGINE_MARKER"; } ;;
            *)   say "Install OrbStack (https://orbstack.dev) or Docker Desktop, then re-run ./setup.sh"; exit 1 ;;
        esac
    else
        say "Install Docker Engine (https://docs.docker.com/engine/install/), then re-run ./setup.sh"; exit 1
    fi
fi
# Make sure the engine is actually up. On a fresh OrbStack install the daemon (and its `docker`
# CLI shim) aren't running yet, so launch it and wait rather than bailing on the first try.
if ! command -v docker >/dev/null 2>&1 || ! docker info >/dev/null 2>&1; then
    say "Starting the Docker engine (waiting up to ~2 min)..."
    open -a OrbStack 2>/dev/null || open -a Docker 2>/dev/null || true
    for _ in $(seq 1 60); do
        hash -r 2>/dev/null || true
        if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then break; fi
        sleep 2
    done
    if ! command -v docker >/dev/null 2>&1 || ! docker info >/dev/null 2>&1; then
        say "Docker still isn't running. Launch OrbStack / Docker Desktop, then re-run ./setup.sh"
        say "(If OrbStack reports 'virtualization not available' on newer Apple Silicon, use Colima instead:"
        say "   brew install colima && colima start --vm-type qemu  — then re-run ./setup.sh.)"
        exit 1
    fi
    say "Docker engine is up."
fi

# --- Recommended terminal (optional): iTerm2 for the 2x2 tmux grid used in sandbox sessions -------
if [ "$(uname -s)" = "Darwin" ] && command -v brew >/dev/null 2>&1 \
   && [ ! -d "/Applications/iTerm.app" ] && [ ! -d "$HOME/Applications/iTerm.app" ]; then
    read -r -p "Install iTerm2? (recommended over Terminal.app for the 2x2 tmux grid) [y/N]: " a
    case "$a" in y|Y) brew install --cask iterm2 || say "iTerm2 install failed — continuing without it." ;; esac
fi

# --- .env -----------------------------------------------------------------------------------------
[ -f .env ] || { [ -f .env.example ] || { say ".env.example is missing; cannot create .env."; exit 1; }; cp .env.example .env; }

get_env() {  # read a non-comment KEY's value from .env, stripping surrounding quotes
    grep -E "^[[:space:]]*$1=" .env 2>/dev/null | grep -vE '^[[:space:]]*#' | tail -1 \
        | cut -d= -f2- | sed -e 's/^"\(.*\)"$/\1/' -e "s/^'\(.*\)'\$/\1/"
}
set_env() {  # set_env KEY VALUE — update first non-comment occurrence, else append
    local key="$1" val="$2" tmp
    case "$val" in *[[:space:]]*) val="\"$val\"" ;; esac
    if grep -qE "^[[:space:]]*${key}=" .env && grep -E "^[[:space:]]*${key}=" .env | grep -qvE '^[[:space:]]*#'; then
        tmp="$(mktemp)"
        awk -v k="$key" -v v="$val" '
            BEGIN{done=0}
            !done && $0 ~ "^[[:space:]]*"k"=" && $0 !~ "^[[:space:]]*#" { print k"="v; done=1; next }
            { print }
        ' .env > "$tmp"
        mv "$tmp" .env
    else
        printf '%s=%s\n' "$key" "$val" >> .env
    fi
}
gen_pass() {  # 20 chars; subshell disables pipefail so head closing the pipe isn't fatal
    ( set +o pipefail; LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 20 )
}

# Workspace: keep an existing real value, else prompt (default ~/work).
existing_ws="$(get_env WORKSPACE_DIR)"
if [ -n "${1:-}" ]; then
    ws="$1"
elif [ -n "$existing_ws" ] && [ "$existing_ws" != "./workspace" ]; then
    ws="$existing_ws"; say "Using existing WORKSPACE_DIR: $ws"
else
    default="$HOME/work"; mkdir -p "$default"
    read -r -p "Folder the sandbox may edit [$default]: " ans
    ws="${ans:-$default}"
fi
mkdir -p "$ws"
ws_abs="$(cd "$ws" && pwd -P)"

# Password: keep a real existing one, else generate.
existing_pass="$(get_env TTYD_PASS)"
case "$existing_pass" in
    ""|please-change-me|changeme|coder|admin|password) pass="$(gen_pass)" ;;
    *) pass="$existing_pass" ;;
esac

set_env WORKSPACE_DIR "$ws_abs"
set_env TTYD_USER "coder"
set_env TTYD_PASS "$pass"

port="$(get_env TTYD_PORT)"; port="${port:-7681}"

say ""
say "Wrote .env:"
say "  WORKSPACE_DIR = $ws_abs"
say "  TTYD_USER     = coder"
say "  TTYD_PASS     = $pass"
say ""
say "Building and starting the sandbox..."
./run.sh

# Convenience: open the web terminal on macOS.
if [ "$(uname -s)" = "Darwin" ] && command -v open >/dev/null 2>&1; then
    open "http://127.0.0.1:${port}" || true
    if [ -d "/Applications/iTerm.app" ] || [ -d "$HOME/Applications/iTerm.app" ]; then
        say ""
        say "Tip: drive sandbox sessions from iTerm2 (Terminal.app is not recommended) — a 2x2 tmux grid works well."
    fi
fi

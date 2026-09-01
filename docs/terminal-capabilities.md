# Terminal capability contract

An agent pane is behind more than one terminal engine. The browser path crosses xterm.js and ttyd;
the local paths cross the operator's terminal and `docker compose exec`; all paths then cross Herdr.
This contract records what reaches the pane. A launcher setting is not evidence that later hops
preserved it.

Run `scripts/verify-terminal-capabilities.sh` to create an isolated stack and measure the two paths
available on a macOS or Linux Docker host. It never attaches to the operator's container or Herdr
session. Chromium runs in a second disposable container on that stack's private network, approaching
ttyd from outside its firewall exactly as a browser does. Only the probe file is copied into the
target; the repository checkout and its ignored `.env` are not mounted. The PowerShell result
remains **unevaluated** until the same boundary runs on Windows.

## Entry paths

| Path ID | Terminal type at the pane | Colour depth | Geometry transport | Keyboard input protocol | Evidence |
|---|---|---|---|---|---|
| `browser` | `xterm-256color` through ttyd's xterm.js and Herdr | terminfo advertises 256 colours; the pane advertises `COLORTERM=truecolor` | browser viewport → xterm.js fit → ttyd PTY → Herdr pane; initial size and a later viewport resize are measured | xterm.js legacy VT sequences; no enhanced keyboard protocol is enabled | Probed by ttyd + the image's Chromium in `verify-terminal-capabilities.sh` |
| `posix-local` | host `TERM` through `shell.sh`, its OSC 52 gate, Compose exec, and Herdr | terminfo advertises at least 256 colours; Herdr advertises `COLORTERM=truecolor` in the pane | host PTY `TIOCSWINSZ` → OSC 52 gate → Compose exec PTY → Herdr pane; initial size and a later resize are measured | legacy xterm VT byte stream; modifier sequences depend on the outer terminal | Probed through the real `shell.sh` launcher by `verify-terminal-capabilities.sh` |
| `powershell-local` | host terminal through `shell.ps1`, Docker Desktop or WSL, and Herdr | **Unevaluated on this host** | Windows console resize → Docker/WSL exec PTY → Herdr pane; **unevaluated on this host** | Windows console VT input; **unevaluated on this host** | Requires a real Windows PowerShell 5.1 host; never inferred from the POSIX result |

`COLORTERM` needs one qualification. Measurement found that Herdr sets `truecolor` for its pane
regardless of the value inherited by Herdr itself; `shell.sh` is not the source of that value. The
verifier therefore reports the value observed inside the pane. On the browser path, xterm.js is the
outer renderer. On a local path, the final visible fidelity still depends on the operator's terminal;
an outer terminal that cannot render 24-bit colour can degrade the result even though the pane
truthfully reports what Herdr accepts. The verifier does not turn an unknown outer renderer into a
true-colour claim.

## Fixed key matrix

The verifier starts a raw input probe by typing through each real entry path. Each row below is an
input event; the report prints the bytes that arrived. `PASS` means a non-empty sequence arrived.
`LIMITATION` is also a valid measured result when it names the lost distinction and consequence.

| Action ID | Browser input | POSIX local input | Required interpretation |
|---|---|---|---|
| `ordinary-text` | `cas` | `cas` | bytes arrive unchanged |
| `enter` | Enter | CR | CR reaches the pane |
| `ctrl-c` | Ctrl+C | ETX | ETX reaches the pane while the probe is raw |
| `arrow-up` | ArrowUp | `CSI A` | navigation sequence arrives |
| `arrow-down` | ArrowDown | `CSI B` | navigation sequence arrives |
| `arrow-right` | ArrowRight | `CSI C` | navigation sequence arrives |
| `arrow-left` | ArrowLeft | `CSI D` | navigation sequence arrives |
| `home` | Home | `CSI H` | navigation sequence arrives |
| `end` | End | `CSI F` | navigation sequence arrives |
| `alt-b` | Alt+B | `ESC b` | sequence arrives, or report the lost Alt distinction and effect |
| `shift-enter` | Shift+Enter | legacy Enter | distinct sequence, or the report names that it is indistinguishable from Enter and cannot be relied on for multiline input |
| `ctrl-arrow-left` | Ctrl+ArrowLeft | `CSI 1;5 D` | sequence arrives, or report the lost Ctrl distinction and effect |
| `ctrl-arrow-right` | Ctrl+ArrowRight | `CSI 1;5 C` | sequence arrives, or report the lost Ctrl distinction and effect |
| `alt-enter` | Alt+Enter | `ESC CR` | sequence arrives, or report the lost Alt distinction and effect |
| `resize-marker` | ordinary `r` after viewport resize | ordinary `r` after PTY resize | causes no capability claim; lets the in-pane probe record the post-resize geometry |

The PowerShell row is not silently filled from these results. A Windows run must drive
`shell.ps1` through a real console and add its measured sequences before that path can move from
**unevaluated**.

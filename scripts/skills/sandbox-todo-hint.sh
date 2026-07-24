# Sandbox first-run setup hint — sourced by every interactive shell so the reminder is seen wherever
# you land: browser Herdr panes, ./shell.sh --attach, and Windows shells. The entrypoint writes
# ~/.sandbox-todo on each boot ONLY while some setup step is still unmet (e.g. no GitHub credential),
# and removes it once everything is resolved — so this prints until you're done, then goes quiet.
#
# Baked into the image as /etc/profile.d/zz-sandbox-todo.sh (login shells) and also sourced from
# /etc/bash.bashrc (interactive non-login shells, e.g. Herdr panes). POSIX sh; safe under bash + dash.

# Interactive shells only — never perturb scripts or `ssh host cmd`.
case $- in
    *i*) ;;
    *) return 0 2>/dev/null || exit 0 ;;
esac

# Show at most once per shell process (a login shell may source this via BOTH profile.d and
# bash.bashrc; the guard collapses that to a single print). Not exported, so a freshly-opened
# pane/tab re-shows the reminder.
[ -n "${_SANDBOX_TODO_SHOWN:-}" ] && { return 0 2>/dev/null || exit 0; }
_SANDBOX_TODO_SHOWN=1

_sandbox_todo="${HOME}/.sandbox-todo"
if [ -r "$_sandbox_todo" ]; then
    printf '\n'
    cat "$_sandbox_todo"
    printf '\n'
fi
unset _sandbox_todo

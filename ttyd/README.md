# Clipboard-enabled ttyd client

`index.html` is ttyd's inlined web client built from upstream commit
`647d55ad865f5ad85ad89ba5e1b28d9b6ac8fd55`. Unlike ttyd 1.7.7's embedded client, it loads
xterm.js's `ClipboardAddon`, which handles OSC 52 clipboard sequences.

The bundled `@xterm/addon-clipboard` was patched before building so an empty OSC 52 selection
(`OSC 52 ; ; data ST`) is treated like selection `c`. tmux emits the empty-selector form. The two
`BrowserClipboardProvider` guards were changed from:

```js
"c" !== selection
```

to:

```js
"" !== selection && "c" !== selection
```

The client also falls back to a temporary hidden textarea plus `document.execCommand("copy")` when
`navigator.clipboard.writeText()` is denied. This keeps OSC 52 copy working when the browser has not
granted persistent clipboard-write permission—a common case because Herdr's selection reaches the
browser asynchronously, after the mouse gesture has ended.

The resulting artifact is checksum-pinned in `Dockerfile`.

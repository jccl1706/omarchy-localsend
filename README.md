# io.github.jccl1706.localsend

Omarchy shell bar-widget plugin that integrates [LocalSend](https://localsend.org)
(installed as the `localsend-cli` package) into the Omarchy bar.

## Requirements

- `localsend-cli` on `$PATH` (from the `localsend` package).
- `tmux` (optional but recommended) — lets this PC stay reachable for
  incoming files even when the popup is closed. Without it, the plugin
  still works, but LocalSend on this machine only listens while you have
  the widget's terminal open (`localsend-cli` has no daemon mode of its
  own and needs a real terminal to run at all).

## Install

```bash
omarchy plugin add https://github.com/jccl1706/omarchy-localsend.git --enable --yes
```

Or by hand:

```bash
cp -r . ~/.config/omarchy/plugins/io.github.jccl1706.localsend
omarchy-shell shell rescanPlugins
omarchy plugin enable io.github.jccl1706.localsend
```

(For local development, a symlink in place of the `cp -r` works too, but
`omarchy-shell`'s file watcher does not follow it — after editing QML you
need `omarchy restart shell` rather than relying on hot-reload.)

## Usage

- With `tmux` installed, a hidden `localsend-cli` instance runs in the
  background automatically as soon as the plugin loads, so this PC is
  reachable for incoming files at all times — the popup's status row shows
  "Receiving in background" while it's active.
- **Click** the icon in the bar: swaps the background receiver for the same
  `localsend-cli` TUI in a floating terminal (via `omarchy-launch-or-focus-tui`)
  to browse nearby devices and pair them. Closing that terminal automatically
  brings the background receiver back.
- **Drop a file** onto the icon: same swap, pre-loaded with that file via
  `localsend-cli -f <path>`; select a discovered device to send it.
- Click the icon again (or click outside) to open/close the popup, which
  shows the device alias, port, and download destination read from
  `~/.config/localsend-cli/config.toml`, plus the last few files received.
- A small dot appears on the bar icon when a file arrives while the popup
  is closed, and a desktop notification fires for every received file. The
  dot clears the next time you open the popup.

## Configuration

This plugin has no settings of its own. It reflects `localsend-cli`'s own
config file; edit `~/.config/localsend-cli/config.toml` to change the alias,
port, or download destination (see the comments in that file) — the recent
files list and notifications follow the same destination folder
automatically.

## Removal

```bash
omarchy plugin remove io.github.jccl1706.localsend --yes
```

Or by hand: `omarchy plugin disable io.github.jccl1706.localsend`, then delete
`~/.config/omarchy/plugins/io.github.jccl1706.localsend/`.

## Files

- `manifest.json` — plugin manifest (`kind: bar-widget`)
- `Widget.qml` — the bar icon, popup panel, and drag-and-drop handling
- `LICENSE` — MIT

When `tmux` is available, the widget writes a small helper script to
`~/.local/state/omarchy-localsend/interactive.sh` on load. It exists because
the launch command passes through `omarchy-launch-or-focus-tui`'s own argv
handling, which flattens and re-parses it along the way — an inline
semicolon-chained `bash -c "a; b; c"` string loses its quoting there. A
plain script path with simple arguments doesn't.

The bar icon is resolved from the system's installed icon theme at runtime
(`Quickshell.iconPath("localsend", true)`, the `localsend` package installs
it) rather than a bundled copy — LocalSend's Apache-2.0 license covers its
code, not a redistribution grant over its mark.

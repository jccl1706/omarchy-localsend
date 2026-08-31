# io.github.jccl1706.localsend

Omarchy shell bar-widget plugin that integrates [LocalSend](https://localsend.org)
(installed as the `localsend-cli` package) into the Omarchy bar.

## Requirements

- `localsend-cli` on `$PATH` (from the `localsend` package).

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

- **Click** the icon in the bar: opens `localsend-cli`'s TUI in a floating
  terminal (via `omarchy-launch-or-focus-tui`) to browse nearby devices,
  pair them, and receive incoming files.
- **Drop a file** onto the icon: opens the same TUI pre-loaded with that
  file via `localsend-cli -f <path>`; select a discovered device to send it.
- Click the icon again (or click outside) to open/close the popup, which
  shows the device alias, port, and download destination read from
  `~/.config/localsend-cli/config.toml`.

## Configuration

This plugin has no settings of its own. It reflects `localsend-cli`'s own
config file; edit `~/.config/localsend-cli/config.toml` to change the alias,
port, or download destination (see the comments in that file).

## Removal

```bash
omarchy plugin remove io.github.jccl1706.localsend --yes
```

Or by hand: `omarchy plugin disable io.github.jccl1706.localsend`, then delete
`~/.config/omarchy/plugins/io.github.jccl1706.localsend/`.

## Files

- `manifest.json` — plugin manifest (`kind: bar-widget`)
- `Widget.qml` — the bar icon, popup panel, and drag-and-drop handling
- `assets/localsend.png` — the LocalSend app icon, bundled so the plugin
  doesn't depend on the system icon theme
- `LICENSE` — MIT

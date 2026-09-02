import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// LocalSend bar widget: an icon button plus a popup card built from the same
// components (BarWidget, BarIconButton, PopupCard, PanelHero) first-party
// widgets use, so it matches the rest of the bar instead of looking bolted on.
BarWidget {
  id: root
  moduleName: "io.github.jccl1706.localsend"

  readonly property string appId: "org.omarchy.localsend"
  // Resolved from the system's installed icon theme at runtime (the same
  // way a .desktop file's Icon= field works) rather than bundling a copy of
  // LocalSend's icon in this repo — LocalSend's Apache-2.0 license covers
  // the code, but its trademark clause doesn't grant redistribution rights
  // over the mark itself.
  readonly property string iconSource: Quickshell.iconPath("localsend", true)
  readonly property string configDirPath: Quickshell.env("HOME") + "/.config/localsend-cli"
  readonly property string configFileName: "config.toml"
  readonly property string configPath: configDirPath + "/" + configFileName
  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  // config.toml is user-writable and re-read on every change; parsing it
  // via regex against a QString loaded whole into memory (FileView's normal
  // .text()) has no ceiling of its own, so an oversized file — a mistake or
  // a same-uid process replacing it — could exhaust memory/CPU repeatedly
  // in this long-lived shell process just from the read and each regex
  // match against it. configText is instead produced by
  // pythonConfigReaderScript (below), which stops after maxConfigBytes
  // regardless of the file's real size, so nothing downstream (parseToml's
  // regex, or any future consumer) ever sees more than that ceiling to
  // begin with.
  readonly property int maxConfigBytes: 65536
  property string configText: ""
  readonly property string deviceAlias: parseToml(configText, "alias", hostnameFile.text().trim() || "This device")
  readonly property string port: parseToml(configText, "port", "53317")
  readonly property string destination: parseToml(configText, "destination", "~/Downloads")
  readonly property string destinationDir: destination.indexOf("~") === 0
    ? Quickshell.env("HOME") + destination.substring(1)
    : destination

  readonly property bool opened: popup.open
  property var recentFiles: []
  property bool hasNewFile: false

  // localsend-cli is a TUI with no daemon mode: it only listens for incoming
  // transfers while its process is running, and only one instance can hold
  // the port at a time. So exactly one instance runs at all times — hidden
  // in a detached tmux session (a real pty, which the TUI requires) whenever
  // nothing else needs the terminal, swapped for a visible interactive one
  // while browsing/sending, then swapped back on exit. tmux is optional: if
  // it's missing, this degrades to the old on-demand-only behavior.
  readonly property string bgSession: "omarchy-localsend-receiver"
  property bool tmuxAvailable: false
  property bool receiving: false
  // Component.onDestruction (below) kills the background session the moment
  // the plugin is disabled or removed with the shell running, but the shell
  // isn't always running when `omarchy plugin remove` deletes this plugin's
  // folder — that command deletes files unconditionally even if it can't
  // reach a live shell to unload them first. So the background session also
  // polls its own installed-plugin directory and self-terminates within a
  // few seconds of that directory disappearing, whether or not this widget
  // instance ever got a chance to run its own cleanup. Verified directly:
  // a background job polling a scratch directory this way kept its listener
  // alive normally, then exited (process and tmux session both gone) within
  // 2s of that directory being removed out from under it.
  readonly property string installedPluginDir: Quickshell.env("HOME") + "/.config/omarchy/plugins/" + moduleName
  // Termination is bounded rather than an unbounded `wait`: once the plugin
  // directory is gone, send TERM, give it up to 5s to exit on its own, then
  // KILL if it hasn't — verified directly against a process that traps and
  // ignores TERM, confirming the KILL escalation actually fires.
  //
  // This signals the single PID, not a process group: a `set -m` (job
  // control) variant was built and tested specifically to also reach any
  // children localsend-cli might spawn, and it reliably rendered and bound
  // the port correctly when launched by hand — but launched the way this
  // plugin actually launches it (spawned by the shell's own Process
  // element, not an interactive terminal), it made the watchdog's own shell
  // exit unexpectedly moments after backgrounding the job, silently
  // orphaning localsend-cli instead of fixing anything — confirmed via
  // repeated clean-slate reproductions, and a regression in the exact
  // reliability this watchdog exists to provide. localsend-cli is a single
  // Rust TUI process with no observed subprocess-spawning behavior in
  // normal operation, so signaling its PID directly already covers the
  // realistic case.
  readonly property string backgroundWatchdogScript:
    "PLUGIN_DIR=" + Util.shellQuote(installedPluginDir) + "\n" +
    "while [[ -d \"$PLUGIN_DIR\" ]]; do\n" +
    "  localsend-cli &\n" +
    "  pid=$!\n" +
    "  while kill -0 \"$pid\" 2>/dev/null; do\n" +
    "    [[ -d \"$PLUGIN_DIR\" ]] || break\n" +
    "    sleep 5\n" +
    "  done\n" +
    "  if kill -0 \"$pid\" 2>/dev/null; then\n" +
    "    kill -TERM \"$pid\" 2>/dev/null\n" +
    "    for i in 1 2 3 4 5; do\n" +
    "      kill -0 \"$pid\" 2>/dev/null || break\n" +
    "      sleep 1\n" +
    "    done\n" +
    "    kill -0 \"$pid\" 2>/dev/null && kill -KILL \"$pid\" 2>/dev/null\n" +
    "  fi\n" +
    "  wait \"$pid\" 2>/dev/null\n" +
    "  [[ -d \"$PLUGIN_DIR\" ]] || break\n" +
    "done\n"
  // Opt-in, not opt-out: silently starting a hidden background listener (and
  // persisting an executable helper script) the first time this plugin loads
  // would run code the user never asked for. Background receiving only turns
  // on once the user explicitly enables it via the popup toggle or IPC.
  readonly property bool backgroundReceivingEnabled: setting("backgroundReceiving", false) === true

  function setBackgroundReceivingEnabled(enabled) {
    var entry = { id: root.moduleName }
    for (var key in root.settings) if (key !== "id") entry[key] = root.settings[key]
    entry.backgroundReceiving = enabled
    root.settings = entry
    if (root.bar && root.bar.shell && typeof root.bar.shell.updateEntryInline === "function")
      root.bar.shell.updateEntryInline(root.moduleName, entry)
  }

  function toggleBackgroundReceiving() {
    setBackgroundReceivingEnabled(!backgroundReceivingEnabled)
  }

  onBackgroundReceivingEnabledChanged: {
    writeBackgroundEnabledFlag()
    if (backgroundReceivingEnabled) ensureBackgroundReceiver()
    else disableBackgroundReceiver()
  }

  // A real file rather than an inline `bash -c "a; b; c"` string: the launch
  // command passes through omarchy-launch-or-focus-tui's own argv handling,
  // which flattens and re-parses it along the way, corrupting anything with
  // shell metacharacters — a semicolon-chained string loses everything after
  // the first `;`, and (worse) even a single quoted `-f <path>` argument
  // gets its quotes stripped, so a path containing a space silently splits
  // into two arguments. A plain script path has no such characters to lose.
  //
  // File paths to send go through the same launcher, so they can't be argv
  // either: they're written to a list file instead (one path per line) and
  // only that file's own space-free path crosses the launcher — the same
  // file-based handoff Omarchy's own image picker uses for this reason.
  readonly property string helperDir: Quickshell.env("HOME") + "/.local/state/omarchy-localsend"
  readonly property string helperPath: helperDir + "/interactive.sh"
  readonly property string fileListName: "pending-files.list"
  readonly property string fileListPath: helperDir + "/" + fileListName

  // Shared by every write below. safe_dir refuses to use helperDir if it
  // already exists as a symlink or non-directory, and creates it private
  // (0700) otherwise. safe_write never opens the target path directly —
  // it writes to a fresh mktemp file in the same directory (so the rename
  // is atomic, same filesystem) and refuses a pre-existing symlink or
  // non-regular file at the target, then atomically renames into place.
  // A predictable path under a private, verified directory plus an atomic
  // rename closes the window a plain `> file` redirect leaves open: a
  // symlink planted at that path ahead of time could otherwise redirect
  // the write to truncate some unrelated file the user owns.
  readonly property string safeWriteLib:
    "safe_dir() {\n" +
    "  local dir=\"$1\"\n" +
    "  if [[ -e \"$dir\" || -L \"$dir\" ]]; then\n" +
    "    if [[ -L \"$dir\" || ! -d \"$dir\" ]]; then echo \"refusing: $dir is not a plain directory\" >&2; return 1; fi\n" +
    "  else\n" +
    "    mkdir -m 700 -- \"$dir\" || return 1\n" +
    "  fi\n" +
    "  chmod 700 -- \"$dir\" 2>/dev/null\n" +
    "}\n" +
    "safe_write() {\n" +
    "  local target=\"$1\" mode=\"$2\" dir tmp\n" +
    "  dir=$(dirname -- \"$target\")\n" +
    "  if [[ -L \"$target\" ]]; then echo \"refusing: $target is a symlink\" >&2; return 1; fi\n" +
    "  if [[ -e \"$target\" && ! -f \"$target\" ]]; then echo \"refusing: $target is not a regular file\" >&2; return 1; fi\n" +
    "  tmp=$(mktemp -- \"$dir/.tmp.XXXXXX\") || return 1\n" +
    "  chmod \"$mode\" -- \"$tmp\"\n" +
    "  cat > \"$tmp\" || { rm -f -- \"$tmp\"; return 1; }\n" +
    "  mv -f -- \"$tmp\" \"$target\"\n" +
    "}\n"
  // Read fresh by the script at restart time — not baked in at install time —
  // so toggling the setting mid-session (including while an interactive
  // session is open) takes effect the moment that session closes.
  readonly property string backgroundEnabledFlagName: "background-enabled"
  readonly property string backgroundEnabledFlagPath: helperDir + "/" + backgroundEnabledFlagName

  // A plain `$(cat "$FLAG")` has the same problems the file list read used
  // to: `cat` follows a symlink at that predictable path, and reading a
  // regular file with no size bound is fine, but if a same-uid process
  // instead replaced the flag with a real FIFO node (not a symlink — a
  // different attack O_NOFOLLOW alone doesn't cover) the plain open() call
  // would block forever waiting for a writer that never comes. This reuses
  // the same held-directory-fd pattern as the list reader (verified real
  // 0700 directory owned by this user, leaf opened through that fd with
  // O_NOFOLLOW) and adds O_NONBLOCK on the leaf open specifically so a FIFO
  // can never block the open either — the immediate regular-file check
  // after opening rejects a FIFO before any read is attempted, and
  // O_NONBLOCK has no effect on a real regular file's read behavior, so
  // there's no downside for the legitimate case. Bounded to 16 bytes: the
  // only valid contents are "0" or "1".
  readonly property string pythonFlagReaderScript:
    "import sys, os, stat\n" +
    "dir_path = sys.argv[1]\n" +
    "name = sys.argv[2]\n" +
    "max_len = 16\n" +
    "try:\n" +
    "    dir_fd = os.open(dir_path, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)\n" +
    "except OSError:\n" +
    "    sys.exit(1)\n" +
    "try:\n" +
    "    dst = os.fstat(dir_fd)\n" +
    "    if not stat.S_ISDIR(dst.st_mode) or dst.st_uid != os.getuid() or (dst.st_mode & 0o777) != 0o700:\n" +
    "        sys.exit(1)\n" +
    "    try:\n" +
    "        fd = os.open(name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=dir_fd)\n" +
    "    except OSError:\n" +
    "        sys.exit(1)\n" +
    "    try:\n" +
    "        st = os.fstat(fd)\n" +
    "        if not stat.S_ISREG(st.st_mode) or st.st_uid != os.getuid() or st.st_size > max_len:\n" +
    "            sys.exit(1)\n" +
    "        data = os.read(fd, max_len)\n" +
    "    finally:\n" +
    "        os.close(fd)\n" +
    "    sys.stdout.buffer.write(data)\n" +
    "finally:\n" +
    "    os.close(dir_fd)\n"

  // config.toml lives in localsend-cli's own config directory, not one this
  // plugin creates — it's typically 0755, not the 0700 this plugin enforces
  // on its own state directory, so the directory check here accepts normal
  // owner-writable-only permissions instead of requiring exactly 0700, but
  // still refuses anything group- or other-writable (nothing but this user
  // should be able to plant files there). Otherwise the same descriptor-
  // based approach as the other readers: O_NOFOLLOW | O_DIRECTORY on the
  // directory, O_NOFOLLOW | O_NONBLOCK on the leaf (refuses a symlink
  // outright and never blocks opening a FIFO planted in its place), regular-
  // file and ownership checks via fstat() on that exact fd, and a read
  // capped at max_len regardless of the file's real size.
  readonly property string pythonConfigReaderScript:
    "import sys, os, stat\n" +
    "dir_path = sys.argv[1]\n" +
    "name = sys.argv[2]\n" +
    "max_len = int(sys.argv[3])\n" +
    "try:\n" +
    "    dir_fd = os.open(dir_path, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)\n" +
    "except OSError:\n" +
    "    sys.exit(1)\n" +
    "try:\n" +
    "    dst = os.fstat(dir_fd)\n" +
    "    if not stat.S_ISDIR(dst.st_mode) or dst.st_uid != os.getuid() or (dst.st_mode & 0o022) != 0:\n" +
    "        sys.exit(1)\n" +
    "    try:\n" +
    "        fd = os.open(name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=dir_fd)\n" +
    "    except OSError:\n" +
    "        sys.exit(1)\n" +
    "    try:\n" +
    "        st = os.fstat(fd)\n" +
    "        if not stat.S_ISREG(st.st_mode) or st.st_uid != os.getuid():\n" +
    "            sys.exit(1)\n" +
    "        data = os.read(fd, max_len)\n" +
    "    finally:\n" +
    "        os.close(fd)\n" +
    "    sys.stdout.buffer.write(data)\n" +
    "finally:\n" +
    "    os.close(dir_fd)\n"

  // Opens the dropped-file list with a genuine no-follow, inode-bound read
  // at every level, not just the leaf. A first attempt used
  // os.open(full_path, O_NOFOLLOW), but O_NOFOLLOW only binds the final path
  // component — the parent directory is still resolved by name each time,
  // so a same-uid process replacing that directory entry (or the directory
  // itself) between calls could redirect the open despite the leaf-level
  // guarantee. Fixed by holding the parent directory open as its own fd
  // first — verified as a real, non-symlink, 0700, user-owned directory via
  // that fd's own fstat(), never re-resolved by path again — and then
  // opening the leaf *through that fd* (dir_fd=), so its resolution can
  // only ever happen inside the one directory already confirmed to be ours.
  // The final cleanup is bound the same way: unlink only fires if a fresh
  // dir_fd-relative lstat of the name still matches the exact device+inode
  // that was opened, read, and validated above, so a same-uid process
  // swapping the entry in between can't cause this to remove something
  // other than the file actually consumed.
  readonly property string pythonListReaderScript:
    "import sys, os, stat\n" +
    "max_records = int(sys.argv[1])\n" +
    "max_len = int(sys.argv[2])\n" +
    "dir_path = sys.argv[3]\n" +
    "name = sys.argv[4]\n" +
    "try:\n" +
    "    dir_fd = os.open(dir_path, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)\n" +
    "except OSError:\n" +
    "    sys.exit(1)\n" +
    "try:\n" +
    "    dst = os.fstat(dir_fd)\n" +
    "    if not stat.S_ISDIR(dst.st_mode) or dst.st_uid != os.getuid() or (dst.st_mode & 0o777) != 0o700:\n" +
    "        sys.exit(1)\n" +
    "    try:\n" +
    "        fd = os.open(name, os.O_RDONLY | os.O_NOFOLLOW, dir_fd=dir_fd)\n" +
    "    except OSError:\n" +
    "        sys.exit(1)\n" +
    "    ok = True\n" +
    "    data = b''\n" +
    "    try:\n" +
    "        st = os.fstat(fd)\n" +
    "        if not stat.S_ISREG(st.st_mode) or st.st_uid != os.getuid():\n" +
    "            ok = False\n" +
    "        elif st.st_size > max_records * max_len:\n" +
    "            ok = False\n" +
    "        else:\n" +
    "            data = os.read(fd, st.st_size + 1)\n" +
    "            if len(data) != st.st_size:\n" +
    "                ok = False\n" +
    "    finally:\n" +
    "        os.close(fd)\n" +
    "    try:\n" +
    "        cur = os.stat(name, dir_fd=dir_fd, follow_symlinks=False)\n" +
    "        if cur.st_dev == st.st_dev and cur.st_ino == st.st_ino:\n" +
    "            os.unlink(name, dir_fd=dir_fd)\n" +
    "    except OSError:\n" +
    "        pass\n" +
    "    if not ok:\n" +
    "        sys.exit(1)\n" +
    "    records = data.split(b'\\0')\n" +
    "    if records and records[-1] == b'':\n" +
    "        records.pop()\n" +
    "    if len(records) > max_records:\n" +
    "        sys.exit(1)\n" +
    "    for r in records:\n" +
    "        if len(r) == 0 or len(r) > max_len:\n" +
    "            sys.exit(1)\n" +
    "    out = b'\\0'.join(records)\n" +
    "    if records:\n" +
    "        out += b'\\0'\n" +
    "    sys.stdout.buffer.write(out)\n" +
    "finally:\n" +
    "    os.close(dir_fd)\n"

  readonly property string helperScript:
    "#!/bin/bash\n" +
    "SESSION=" + Util.shellQuote(bgSession) + "\n" +
    "FLAGNAME=" + Util.shellQuote(backgroundEnabledFlagName) + "\n" +
    "command -v tmux >/dev/null 2>&1 && tmux kill-session -t \"$SESSION\" 2>/dev/null\n" +
    "ARGS=()\n" +
    // $1 is only ever a boolean "was a list dropped this time" signal here,
    // not a path to trust and re-resolve — the actual open below always
    // targets the fixed, known LISTDIR/LISTNAME regardless of $1's literal
    // value, since that pair is the only location this plugin ever writes
    // the list to. See pythonListReaderScript for why the open, every
    // check, and the cleanup unlink all happen through one held directory
    // fd rather than by repeatedly resolving a path string.
    "LISTDIR=" + Util.shellQuote(helperDir) + "\n" +
    "LISTNAME=" + Util.shellQuote(fileListName) + "\n" +
    "if [[ -n \"$1\" ]] && command -v python3 >/dev/null 2>&1; then\n" +
    "  while IFS= read -r -d '' line; do\n" +
    "    [[ -n \"$line\" ]] && ARGS+=(-f \"$line\")\n" +
    "  done < <(python3 - " + maxDroppedFiles + " " + maxPathLength + " \"$LISTDIR\" \"$LISTNAME\" <<'PYEOF'\n" +
    pythonListReaderScript +
    "PYEOF\n" +
    ")\n" +
    "fi\n" +
    "localsend-cli \"${ARGS[@]}\"\n" +
    // A plain `FLAGVAL=$(cmd)` on a failing/refused read leaves FLAGVAL as
    // an EMPTY string, not "0" — and "" != "0" is true in bash, which would
    // make any rejected read (a symlinked or FIFO-replaced flag, or python3
    // missing) look like an enabled flag and start the background receiver
    // rather than failing closed. The explicit exit-status check below is
    // what actually enforces "any failure here means treat it as disabled".
    "FLAGVAL=0\n" +
    "if command -v python3 >/dev/null 2>&1; then\n" +
    "  FLAGVAL=$(python3 - \"$LISTDIR\" \"$FLAGNAME\" <<'PYEOF'\n" +
    pythonFlagReaderScript +
    "PYEOF\n" +
    ")\n" +
    "  [[ $? -eq 0 ]] || FLAGVAL=0\n" +
    "fi\n" +
    "if command -v tmux >/dev/null 2>&1 && [[ \"$FLAGVAL\" != \"0\" ]]; then\n" +
    "  tmux new-session -d -s \"$SESSION\" bash -c " + Util.shellQuote(backgroundWatchdogScript) + "\n" +
    "fi\n"

  function installHelperScript() {
    installHelperProc.command = ["bash", "-c",
      safeWriteLib
      + "safe_dir " + Util.shellQuote(helperDir) + " || exit 1\n"
      + "printf '%s' " + Util.shellQuote(helperScript) + " | safe_write " + Util.shellQuote(helperPath) + " 700\n"]
    installHelperProc.running = true
  }

  function writeBackgroundEnabledFlag() {
    writeFlagProc.command = ["bash", "-c",
      safeWriteLib
      + "safe_dir " + Util.shellQuote(helperDir) + " || exit 1\n"
      + "printf '%s' " + Util.shellQuote(backgroundReceivingEnabled ? "1" : "0") + " | safe_write " + Util.shellQuote(backgroundEnabledFlagPath) + " 600\n"]
    writeFlagProc.running = true
  }

  function disableBackgroundReceiver() {
    disableBgProc.command = ["bash", "-c",
      "command -v tmux >/dev/null 2>&1 && tmux kill-session -t " + Util.shellQuote(bgSession) + " 2>/dev/null"]
    disableBgProc.running = true
    root.receiving = false
  }

  // Runs entirely through our own Process (a real exec array, no shell
  // re-parsing), so paths with spaces or quotes are safe here even though
  // they aren't once they'd cross omarchy-launch-or-focus-tui. Each path is
  // its own argv element (never concatenated into one string), and printf's
  // %s\0 gives each a NUL terminator on the way into the file — matching
  // the NUL-delimited reader in helperScript. A newline embedded in a
  // filename is just a byte in one argument here, not a record separator,
  // so it can't inject an extra path the way joining with "\n" could.
  function writeFileList(filePaths, onWritten, onFailed) {
    var command = ["bash", "-c",
      safeWriteLib
      + "safe_dir " + Util.shellQuote(helperDir) + " || exit 1\n"
      + "printf '%s\\0' \"$@\" | safe_write " + Util.shellQuote(fileListPath) + " 600\n",
      "omarchy-localsend"]
    for (var i = 0; i < filePaths.length; i++) command.push(filePaths[i])
    writeFileListProc.command = command
    writeFileListProc.onWritten = onWritten
    writeFileListProc.onFailed = onFailed
    writeFileListProc.running = true
  }

  function ensureBackgroundReceiver() {
    if (tmuxAvailable && backgroundReceivingEnabled && !ensureBgProc.running) ensureBgProc.running = true
  }

  function checkReceivingStatus() {
    if (tmuxAvailable && !statusCheckProc.running) statusCheckProc.running = true
  }

  function parseToml(text, key, fallback) {
    if (!text) return fallback
    var re = new RegExp("^\\s*" + key + "\\s*=\\s*\"?([^\"\\n]*?)\"?\\s*$", "m")
    var match = re.exec(text)
    return match && match[1].length > 0 ? match[1] : fallback
  }

  function readConfigBounded() {
    if (!configReadProc.running) configReadProc.running = true
  }

  function updateRecentFiles(text) {
    var lines = String(text || "").split("\n").filter(function(l) { return l.length > 0 })
    var files = []
    for (var i = 0; i < lines.length; i++) {
      var tab = lines[i].indexOf("\t")
      if (tab === -1) continue
      var epoch = parseFloat(lines[i].substring(0, tab))
      var name = lines[i].substring(tab + 1)
      if (!isFinite(epoch) || name.length === 0) continue
      files.push({ name: name, mtime: epoch })
    }
    root.recentFiles = files
  }

  function refreshRecentFiles() {
    if (!recentFilesProc.running) recentFilesProc.running = true
  }

  function notifyReceived(filename) {
    if (!bar) return
    bar.run("notify-send " + Util.shellQuote("LocalSend") + " " + Util.shellQuote("Received " + filename) + " -i localsend")
  }

  onDestinationDirChanged: {
    receiveWatcher.running = false
    watcherFailureCount = 0
    receiveWatcherRestart.interval = 5000
    receiveWatcherRestart.restart()
    refreshRecentFiles()
  }

  onOpenedChanged: if (opened) { hasNewFile = false; refreshRecentFiles() }

  Component.onCompleted: {
    receiveWatcher.running = true
    refreshRecentFiles()
    installHelperScript()
    writeBackgroundEnabledFlag()
    tmuxCheckProc.running = true
    readConfigBounded()
  }

  // Disabling or removing the plugin destroys this Item (the bar's Loader
  // tears it down), so this is the one place that reliably runs on both
  // paths. Uses Quickshell.execDetached rather than one of this widget's own
  // Process elements, since those are being torn down alongside root right
  // now and may not get a chance to actually run. Best-effort: this can't
  // reach a case where the whole plugin directory is deleted without the
  // shell ever unloading it first (e.g. removed while the shell isn't
  // running), which is why the background receiver defaults to off.
  Component.onDestruction: {
    Quickshell.execDetached(["bash", "-c",
      "command -v tmux >/dev/null 2>&1 && tmux kill-session -t " + Util.shellQuote(bgSession) + " 2>/dev/null\n"
      + "rm -f -- " + Util.shellQuote(helperPath) + " " + Util.shellQuote(backgroundEnabledFlagPath) + " " + Util.shellQuote(fileListPath) + "\n"])
  }

  readonly property int maxDroppedFiles: 64
  readonly property int maxPathLength: 4096

  // Returns null for anything that isn't an actual local file: URL, or whose
  // decoded path is empty/implausibly long — a drag source offering e.g. an
  // http: or data: URL should never reach argv or a written file. A file:
  // URL may carry a host/authority component (file://some-host/path) that
  // means "fetch this from some-host", not a path on this machine, so that's
  // rejected too rather than silently stripped. And since the result is
  // treated as an absolute local path from here on, it's required to
  // actually start with "/" post-decode and contain no ".." segment — a
  // value like "file://../../etc/passwd" would otherwise decode to a
  // relative path that escapes wherever it's later resolved from.
  function urlToPath(url) {
    var s = url.toString()
    if (s.indexOf("file:///") !== 0) return null
    var decoded
    try {
      decoded = decodeURIComponent(s.substring(7))
    } catch (e) {
      return null
    }
    if (decoded.length < 2 || decoded.length > maxPathLength) return null
    if (decoded.charAt(0) !== "/") return null
    var segments = decoded.split("/")
    for (var i = 0; i < segments.length; i++) if (segments[i] === "..") return null
    return decoded
  }

  function open() { popup.open = true }
  function close() { popup.open = false }
  function toggle() { popup.open = !popup.open }

  function openLocalSend(filePaths) {
    if (!bar) return

    function launch(extraArg) {
      var command = Util.shellQuote(helperPath) + (extraArg ? " " + Util.shellQuote(extraArg) : "")
      bar.run("omarchy-launch-or-focus-tui --app-id=" + appId + " " + command)
      if (tmuxAvailable) root.receiving = false
      root.close()
    }

    if (filePaths.length > 0) {
      writeFileList(filePaths, function() { launch(fileListPath) }, function() {
        console.warn("io.github.jccl1706.localsend: failed to write the file list; not launching")
      })
    } else {
      launch("")
    }
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  // Used only to detect that config.toml changed — its own .text()/.data()
  // are never called, so this never loads the file's content into memory
  // itself; readConfigBounded() is what actually produces configText, via
  // pythonConfigReaderScript's descriptor-based no-follow/nonblocking read,
  // capped regardless of the real file size.
  FileView {
    id: configFile
    path: root.configPath
    watchChanges: true
    printErrors: false
    onFileChanged: root.readConfigBounded()
  }

  // Without python3, configText simply never updates (stays at its default
  // "" until python3 is available), which parseToml's own fallback
  // arguments already handle the same way a missing/unreadable config does
  // — no separate fail-closed branch needed here. The outer `timeout` is a
  // wall-clock backstop against something unrelated to the FIFO case
  // O_NONBLOCK already covers (e.g. a stalled network filesystem).
  Process {
    id: configReadProc
    command: ["bash", "-c",
      "command -v python3 >/dev/null 2>&1 && timeout 3 python3 - " + Util.shellQuote(root.configDirPath) + " " + Util.shellQuote(root.configFileName) + " " + root.maxConfigBytes + " <<'PYEOF'\n" +
      pythonConfigReaderScript +
      "PYEOF"]
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: root.configText = text }
  }

  FileView {
    id: hostnameFile
    path: "/etc/hostname"
    printErrors: false
  }

  Process {
    // `sort` must consume its entire input before emitting anything, so the
    // trailing `head -5` only bounds the final output — a destination folder
    // with an enormous number of entries would still make `sort` do
    // unbounded work first. Capping with an earlier `head -n 2000` bounds
    // what `sort` ever sees regardless of how many files actually exist
    // (an approximation for a pathologically large folder — the "5 most
    // recent" then means "most recent among the first 2000 find happens to
    // encounter" — a fine tradeoff for what's just a convenience list), and
    // the outer `timeout` is a hard wall-clock ceiling on the whole pipeline
    // as a backstop regardless of what's bounding memory/CPU.
    id: recentFilesProc
    command: ["bash", "-c",
      "timeout 3 bash -c " + Util.shellQuote(
        "find " + Util.shellQuote(root.destinationDir) + " -maxdepth 1 -type f -printf '%T@\\t%f\\n' 2>/dev/null | head -n 2000 | sort -rn | head -5")]
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: root.updateRecentFiles(text) }
  }

  // Watches the destination folder for completed transfers so the popup can
  // show recent arrivals and the bar icon can flag unseen ones — all from
  // local filesystem events, since localsend-cli exposes no API of its own
  // to poll for this. Restarts on exit (e.g. destination folder not created
  // yet) the same way PluginRegistry's own plugin-folder watcher does.
  Process {
    id: receiveWatcher
    command: ["inotifywait", "-m", "-q", "-e", "close_write,moved_to", "--format", "%f", root.destinationDir]
    stdout: SplitParser {
      onRead: function(filename) {
        root.refreshRecentFiles()
        if (!root.opened) root.hasNewFile = true
        root.notifyReceived(filename)
      }
    }
    // Exponential backoff (5s, 10s, 20s, ... capped at 5 minutes) instead of
    // retrying every 5s forever — e.g. if the destination folder can never
    // be created, this shouldn't spin indefinitely at a fixed fast interval.
    // watcherStableTimer resets the count once a run has stayed up a while,
    // so a later transient failure still starts back at the short delay.
    onExited: {
      root.watcherFailureCount = Math.min(root.watcherFailureCount + 1, 6)
      watcherStableTimer.stop()
      receiveWatcherRestart.interval = Math.min(5000 * Math.pow(2, root.watcherFailureCount - 1), 300000)
      receiveWatcherRestart.restart()
    }
    onRunningChanged: if (running) watcherStableTimer.restart()
  }

  property int watcherFailureCount: 0

  Timer {
    id: watcherStableTimer
    interval: 10000
    onTriggered: root.watcherFailureCount = 0
  }

  Timer {
    id: receiveWatcherRestart
    interval: 5000
    onTriggered: receiveWatcher.running = true
  }

  Process {
    id: installHelperProc
  }

  Process {
    id: writeFileListProc
    property var onWritten: null
    property var onFailed: null
    onExited: function(exitCode) {
      if (exitCode === 0) { if (onWritten) onWritten() }
      else { if (onFailed) onFailed() }
    }
  }

  Process {
    id: tmuxCheckProc
    command: ["bash", "-c", "command -v tmux >/dev/null 2>&1 && echo yes || echo no"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        root.tmuxAvailable = text.trim() === "yes"
        if (root.tmuxAvailable) root.ensureBackgroundReceiver()
      }
    }
  }

  Process {
    id: ensureBgProc
    command: ["bash", "-c",
      "tmux has-session -t " + Util.shellQuote(root.bgSession) + " 2>/dev/null || "
      + "tmux new-session -d -s " + Util.shellQuote(root.bgSession) + " bash -c " + Util.shellQuote(root.backgroundWatchdogScript)]
    onExited: root.checkReceivingStatus()
  }

  Process {
    id: disableBgProc
  }

  Process {
    id: writeFlagProc
  }

  Process {
    id: statusCheckProc
    command: ["bash", "-c", "tmux has-session -t " + Util.shellQuote(root.bgSession) + " 2>/dev/null && echo yes || echo no"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.receiving = text.trim() === "yes"
    }
  }

  // Safety net for when the background receiver dies outside our control
  // (crash, forced-closed terminal skipping the restart chain in
  // openLocalSend, first boot). Cheap to poll — tmux has-session is instant.
  Timer {
    interval: 20000
    running: root.tmuxAvailable && root.backgroundReceivingEnabled
    repeat: true
    triggeredOnStart: true
    onTriggered: root.ensureBackgroundReceiver()
  }

  IpcHandler {
    target: root.moduleName

    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function send(): void { root.openLocalSend([]) }
    function toggleBackgroundReceiving(): void { root.toggleBackgroundReceiving() }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    tooltipText: "LocalSend — click to open, drop a file to send it"
    iconComponent: Component {
      Item {
        Image {
          anchors.fill: parent
          fillMode: Image.PreserveAspectFit
          source: root.iconSource
          smooth: true
        }

        Rectangle {
          visible: root.hasNewFile
          width: Style.space(6)
          height: Style.space(6)
          radius: width / 2
          color: root.bar ? root.bar.urgent : Color.urgent
          anchors.right: parent.right
          anchors.bottom: parent.bottom
        }
      }
    }
    onPressed: root.toggle()
  }

  DropArea {
    anchors.fill: parent
    onDropped: function(drop) {
      var paths = []
      var count = Math.min(drop.urls.length, root.maxDroppedFiles)
      for (var i = 0; i < count; i++) {
        var p = root.urlToPath(drop.urls[i])
        if (p) paths.push(p)
      }
      if (paths.length > 0) root.openLocalSend(paths)
    }
  }

  PopupCard {
    id: popup
    anchorItem: button
    bar: root.bar
    owner: root
    contentWidth: popup.fittedContentWidth(Style.space(300))
    contentHeight: popup.fittedContentHeight(content.implicitHeight)

    Column {
      id: content
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.top: parent.top
      spacing: Style.space(14)

      PanelHero {
        title: "LocalSend"
        meta: root.deviceAlias
        foreground: root.foreground
        fontFamily: root.fontFamily
        iconComponent: Component {
          Image {
            width: Style.font.display
            height: Style.font.display
            fillMode: Image.PreserveAspectFit
            source: root.iconSource
          }
        }
      }

      Item {
        width: parent.width
        visible: root.tmuxAvailable
        implicitHeight: Math.max(statusRow.implicitHeight, receivingToggle.implicitHeight)

        Row {
          id: statusRow
          anchors.left: parent.left
          anchors.right: receivingToggle.left
          anchors.rightMargin: Style.space(8)
          anchors.verticalCenter: parent.verticalCenter
          spacing: Style.space(8)

          Rectangle {
            width: Style.space(8)
            height: Style.space(8)
            radius: width / 2
            anchors.verticalCenter: parent.verticalCenter
            color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b,
              !root.backgroundReceivingEnabled ? 0.1 : (root.receiving ? 1.0 : 0.25))
          }
          Text {
            text: !root.backgroundReceivingEnabled
              ? "Background receiving off"
              : (root.receiving ? "Receiving in background" : "Not receiving right now")
            opacity: 0.8
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
          }
        }

        ToggleSwitch {
          id: receivingToggle
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          checked: root.backgroundReceivingEnabled
          foreground: root.foreground
          onToggled: root.toggleBackgroundReceiving()
        }
      }

      Text {
        width: parent.width
        visible: !root.tmuxAvailable
        wrapMode: Text.WordWrap
        text: "Install tmux to keep this PC reachable for incoming files even when this popup is closed."
        color: Qt.darker(root.foreground, 1.3)
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
      }

      PanelSeparator { foreground: root.foreground }

      Column {
        width: parent.width
        spacing: Style.spacing.labelGap

        InfoPair { label: "Port"; value: root.port }
        InfoPair { label: "Saves to"; value: root.destination }
      }

      PanelSeparator { foreground: root.foreground }

      Column {
        width: parent.width
        visible: root.recentFiles.length > 0
        spacing: Style.spacing.labelGap

        PanelSectionHeader {
          text: "RECENT FILES"
          foreground: root.foreground
          fontFamily: root.fontFamily
        }

        Repeater {
          model: root.recentFiles

          RecentFileRow {
            required property var modelData
            name: modelData.name
            mtime: modelData.mtime
          }
        }
      }

      PanelSeparator { visible: root.recentFiles.length > 0; foreground: root.foreground }

      Text {
        width: parent.width
        text: "Drop a file on the bar icon to send it directly, or open LocalSend to browse nearby devices."
        wrapMode: Text.WordWrap
        color: Qt.darker(root.foreground, 1.3)
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
      }

      Button {
        width: parent.width
        text: "Open LocalSend"
        bordered: true
        foreground: root.foreground
        fontFamily: root.fontFamily
        onClicked: root.openLocalSend([])
      }
    }
  }

  component InfoPair: Row {
    id: pairRoot
    property string label: ""
    property string value: ""

    width: parent.width
    spacing: Style.space(8)

    Text {
      id: labelText
      textFormat: Text.PlainText
      text: pairRoot.label
      opacity: 0.6
      color: root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
    }
    Text {
      // pairRoot.value is config-derived (port/destination from
      // config.toml, which this same user could have written anything
      // into) — PlainText so a markup-shaped value is never parsed as rich
      // text rather than displayed as the literal string it is.
      textFormat: Text.PlainText
      text: pairRoot.value
      elide: Text.ElideMiddle
      horizontalAlignment: Text.AlignRight
      width: Math.max(Style.space(20), pairRoot.width - labelText.implicitWidth - pairRoot.spacing)
      color: root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
    }
  }

  component RecentFileRow: Row {
    id: fileRow
    property string name: ""
    property real mtime: 0

    width: parent.width
    spacing: Style.space(8)

    Text {
      id: timeText
      textFormat: Text.PlainText
      text: Qt.formatDateTime(new Date(fileRow.mtime * 1000), "HH:mm")
      opacity: 0.6
      color: root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
    }
    Text {
      // fileRow.name is a filename received over the network from another
      // LocalSend peer — the most directly attacker-influenced string in
      // this whole widget. PlainText so a markup-shaped filename is never
      // parsed as rich text rather than displayed as the literal name it is.
      id: nameText
      textFormat: Text.PlainText
      text: fileRow.name
      elide: Text.ElideMiddle
      width: Math.max(Style.space(20), fileRow.width - timeText.implicitWidth - fileRow.spacing)
      color: root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
    }
  }
}

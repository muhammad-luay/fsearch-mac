# FSearch for macOS

Whole-disk file search with an Option+Space panel: find any file by fuzzy name
(~0.1 ms over 8M files), search inside files, then open it, reveal it, copy its
path, or drag it straight into a terminal.

Two pieces, one repo:

- **`daemon/`** — the `fsearch` CLI + background daemon (Rust). Fuzzy names,
  typo tolerance, indexed content grep, git/frecency ranking, MCP server.
- **`panel/`** — `FSearchPanel.app`, a Spotlight-style panel over the daemon
  (Swift/AppKit, no dependencies).

## Install

Requires macOS 13+ on Apple Silicon, Rust (1.85+), and the Xcode command line
tools (`swiftc`).

```sh
make install                 # daemon -> ~/.local/bin/fsearch (+ login agent)
                             # panel  -> ~/Applications/FSearchPanel.app
open ~/Applications/FSearchPanel.app
```

Then press **Option+Space** anywhere.

Prebuilt binaries are on the [Releases](../../releases) page if you don't want
to build.

### Full Disk Access

Grant `~/.local/bin/fsearch` in **System Settings → Privacy & Security → Full
Disk Access** — re-grant after every rebuild, the binary changes. Without it
the daemon skips protected folders instead of prompting. The first index build
takes about a minute for a few million files.

## The panel

| key | action |
|---|---|
| `⌥Space` | open / close the panel |
| type | live fuzzy search over the daemon |
| `↑` `↓` | move selection |
| `⏎` / double-click | open the file |
| `⌘⏎` | reveal in Finder |
| `⌘C` | copy the selected path |
| `⌘V` | paste into the search field |
| drag a row | drop the path into Terminal (shell-escaped) |
| `esc` | close |

## The CLI

```sh
fsearch fsearch main              # files by name (fuzzy; 5+ letters forgive a typo)
fsearch 'ext:rs grep:apply_dir'   # search inside files
fsearch 'readme in:~/Developer'
fsearch 'type:image size:>5mb mtime:<7d'
fsearch status
```

Full query language, filters and benchmarks: [`daemon/README.md`](daemon/README.md).

## Building

```sh
make daemon    # -> daemon/target/release/fsearch
make panel     # -> ~/Applications/FSearchPanel.app
```

`make daemon` builds with `target-cpu=native` for the machine you build on; the
release binaries are built without it so they run on every Apple Silicon Mac.

## Attribution

- `daemon/` is vendored from [noahdunnagan/fsearch](https://github.com/noahdunnagan/fsearch)
  (v0.2.0, commit `e96ebeb`), MIT © 2026 Noah Dunnagan — see `daemon/LICENSE`.
- `panel/` and the build scripts are MIT © 2026 Muhammad Luay — see `LICENSE`.

The panel app is ad-hoc signed. If macOS refuses a downloaded copy: right-click
→ Open, or `xattr -dr com.apple.quarantine ~/Applications/FSearchPanel.app`.

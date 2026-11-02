<p align="center"><img src="Resources/AppIcon-1024.png" width="128" alt="Pliable icon"></p>

# Pliable

A small, fast, native macOS editor for property lists.

Double-clicking a `.plist` normally launches Xcode, which takes several seconds before the window shows up.
Pliable opens the same file in well under a second and edits it the way Xcode does.

![Editing an Info.plist with search matches highlighted](docs/editor-search.png)

## What it does

- **Opens instantly.** Native AppKit, no dependencies, universal binary (Apple silicon and Intel).
- **Every plist format.** Reads and writes **XML**, **binary** and **OpenStep** (old-style ASCII) property lists, plus `.strings` files.
  Switch the save format from the toolbar.
- **Keeps your key order** in XML and OpenStep files, like Xcode, so diffs in git stay small.
- **Edits like Xcode.** Key / Type / Value tree with every plist type, including `NSKeyedArchiver` UIDs.
  Add, delete, rename, retype, drag to reorder, copy and paste, with full undo.
- **Search with ⌘F.** Finds keys and values anywhere in the tree, expands collapsed items to show each match,
  highlights matching text and shows “2 of 5 matches” in the title bar.
- **Compare two plists.** **File → Compare With…** (⇧⌘D) lists every added, removed and changed key, side by side.
  The list updates live as you edit or as the other file changes, and clicking a row jumps to it.
- **Drag a plist onto an open window** to open it in a new tab or compare it with the one you have open.
- **Picks up changes on disk.** When another app or a script rewrites the file, Pliable reloads it and keeps your
  expanded rows and selection. If you have unsaved edits, it asks first.

![Comparing two versions of an Info.plist](docs/compare.png)

## Install

```sh
brew tap doronz88/tap
brew trust --cask doronz88/tap/pliable   # recent Homebrew requires trusting third-party casks
brew install --cask doronz88/tap/pliable
```

Or download `Pliable-<version>.zip` from [Releases](https://github.com/doronz88/Pliable/releases) and move `Pliable.app` to `/Applications`.

> [!NOTE]
> Pliable is ad-hoc signed, not notarized. On first launch macOS will refuse to open it; allow it in
> **System Settings → Privacy & Security → Open Anyway**, or run
> `xattr -dr com.apple.quarantine /Applications/Pliable.app`.

To open plists with Pliable by default, choose **Pliable → Make Pliable the Default Plist Editor**
(macOS asks you to confirm), or in Finder select any `.plist` → **Get Info** → **Open with: Pliable** → **Change All…**

## Usage

| Action | Shortcut |
|---|---|
| Add item | `+` or `⌘↩` |
| Edit value of selected row | `↩` |
| Delete selected items | `⌫` or `⌘⌫` |
| Undo / Redo | `⌘Z` / `⇧⌘Z` |
| Expand / collapse all | `⌥⌘→` / `⌥⌘←` |
| Find | `⌘F` |
| Next / previous match | `↩` / `⇧↩` in the search field, or `⌘G` / `⇧⌘G` |
| Compare with another plist | `⇧⌘D` |

New items go into the selected container when it is expanded (or Root), otherwise right after the selected row.

## How formats are handled

| Format | Read | Write | Key order |
|---|---|---|---|
| XML | Foundation `XMLParser` | Pliable (Apple-style output) | Preserved |
| Binary | `PropertyListSerialization` | `PropertyListSerialization` | Not preserved (same as Xcode) |
| OpenStep / `.strings` | Pliable | Pliable | Preserved |

Notes:

- XML files that `XMLParser` rejects but Foundation accepts (for example unquoted attributes in the XML declaration)
  still open through `PropertyListSerialization`; the window subtitle then says key order could not be read.
- XML cannot store strings containing NUL characters and keeps dates to whole seconds (same as Foundation).
- OpenStep can only hold strings, data, arrays and dictionaries; Pliable refuses to save other types in that format.

## Build from source

Requires Xcode (or the Swift toolchain) on macOS 14 or later.

```sh
./build.sh                         # build/Pliable.app
UNIVERSAL=1 VERSION=1.0.0 ./build.sh
swift test                         # unit tests
```

`pliable-verify` round-trips a list of plists through Pliable and compares the result with Foundation:

```sh
swift build -c release --product pliable-verify
find /System/Library -name '*.plist' | .build/release/pliable-verify
```

## Releasing

Push a tag `vX.Y.Z`. The release workflow tests, builds a universal app, attaches `Pliable-X.Y.Z.zip` to a GitHub release
and, if the `TAP_TOKEN` secret is set, bumps the cask in [doronz88/homebrew-tap](https://github.com/doronz88/homebrew-tap).

## License

MIT

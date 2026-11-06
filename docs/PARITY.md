# Explorer ↔ Folders Pro 2.12.1 parity tracker

Legend: ✅ built and checked (unit test or rendered snapshot), 🟡 built, not yet exercised end-to-end, ⬜ not built

The keyboard reference is [Folders Pro](</Applications/Folders Pro.app>) (com.minttype.folders-pro 2.12.1), plus its [User's Guide](https://foldersapp.dev/guide/) and [Keyboard Shortcuts](https://foldersapp.dev/shortcuts/). Other feature statuses retain their earlier verification scope.

## Window & views
| Feature | Status | Notes |
|---|---|---|
| Folder Tree with configurable sections (Favorites, Home, drives, network, remote, iCloud, Cloud storage, iOS, Recent, Tags, Ratings, Saved searches, Trash) | ✅ | default 253 pt width |
| Icons / List / Table / Gallery views, ⌘1–4 | ✅ | snapshots in `build/shots` |
| Archive view (name / modified / original / compressed / kind) | ✅ | |
| Toolbar order (sidebar, dup window/tab, back/fwd/up, title, new folder, view, sort, group, remember, search) | ✅ | |
| Path bar: interactive or string, top or bottom, ⇧⌘G with completions | 🟡 | |
| Status bar with progress stripe, pause/cancel | 🟡 | |
| Info panel: preview, dates, EXIF/GPS, media, tags, rating, comment, Open With, hidden/locked, permissions, custom icon | ✅ | rendered |
| Gallery tools: zoom, lock, backgrounds, flip/rotate, Live Text | 🟡 | |
| Shelf flap | 🟡 | |
| Grouping (kind/date/size/tags/rating) and folders first/last | ✅ | unit tests |
| Remember view options per folder (+ inherit to subfolders) | ✅ | unit tests |
| Tabs, Customize Tab, Tab Sets | 🟡 | |

## Keyboard shortcuts

- Existing-feature bindings follow the [2.12.1 shortcut list](https://foldersapp.dev/shortcuts/). Explorer's extra bindings remain available.
- Shared raw-key resolution validates command availability, uses exact shortcut modifiers, honors Return/Delete preferences, and uses the trailing arrow for Shelf in RTL layouts.
- All four file views share an input route. Gallery supports type selection and stable arrow/range selection after programmatic selection changes. Quick Look forwards navigation through the active file view.
- Tree shortcuts target the selected node, not retained file-view selection. Option-number shortcuts count only visible unselectable top-level groups. Option-arrow navigation expands groups, skips empty groups, and stops at boundaries.
- Show All Tabs is explicitly registered on Shift-Command-backslash using native window tab overview.
- Text editors retain Command-arrow and Command-Delete behavior. Unsupported tree file actions are disabled rather than applied to stale selection.
- Regression coverage includes resolver branches, modifier rejection, editor/menu protection, tree planning, actual Gallery responder navigation, Command-Down and explicit file-popup scope through every file view, real private-trash deletion with menu Undo/Redo, immediate queued Undo, and text-editor undo isolation. `make test` passed with 15 app tests and 79 core tests, including one skipped hardware-only MTP test.
- Scope exclusion: Shift-Command-K Remote Connections is not registered. Explorer has no SFTP, FTP, FTPS, or S3 backend. No placeholder command is presented.
- Verification limit: not every OS dialog, non-QWERTY keyboard layout, physical-device operation, or full menu-driven workflow has been exercised end-to-end. RTL command resolution is unit-tested, not tested with a live RTL system session.

## File operations
| Feature | Status | Notes |
|---|---|---|
| Copy/move with progress, pause, cancel | ✅ | unit tests |
| Conflicts: Skip / Keep Both / Replace / Replace Older / Merge, Apply to All | ✅ | unit tests |
| Undo/redo, including swaps and multi-item deletion | ✅ | Explicit menu target preserves editor undo. Failed built-in actions retain history and roll back partial moves. Custom closures must be atomic on failure. |
| Trash plus private trash fallback | ✅ | |
| Cut via Trash / internal cut / cloud rule / clipboard-replaced warning | 🟡 | |
| Paste as symlinks/aliases, Paste into Folder, Move Item Here | ✅ (core) | |
| New folder / with selection / empty file / Office docs / from clipboard / via scriptable apps | ✅ (templates tested) | |
| Batch Rename (7 step types, preview, collisions) | ✅ | unit tests |
| Drag & drop with ⌥/⌘/⌃ rules | 🟡 | |
| Retry as Administrator (SMAppService helper → osascript fallback) | 🟡 | Only explicit permanent deletion may retry with privileged removal. Move to Trash must never become irreversible removal. The daemon path needs a team-signed build. |

Deletion is silent. Other operation sounds default to off and remain opt-in through Settings.

Undo history is session-local. Files deleted before an app restart must be restored from system Trash or a preserved private-trash backup, not the new session's undo stack.

## Archives
| Feature | Status |
|---|---|
| zip / 7z / tar / tar.gz / bz2 / xz / tar.7z create, browse, extract, add, remove | ✅ |
| Password zip (AES-256) and 7z | ✅ |
| Single-file tar.* → .gz etc. | ✅ |
| rar, multi-volume 7z read | 🟡 |
| Filename encoding picker | 🟡 |

## Integrations
| Feature | Status |
|---|---|
| Spotlight / full-scan search, Save Search (.savedSearch) | ✅ (file format) / 🟡 UI |
| Network share discovery, mount, pin/hide/forget, remount pinned | 🟡 |
| Git badges + stage/unstage/discard/commit/pull/push | ✅ |
| Actions (shell / AppleScript, {path} {name} {stem} {dir}) | ✅ |
| CLI `explorer`, URL schemes, Services, AppleScript sdef, App Intents | ✅ (parsing) / 🟡 install |
| iOS devices over AFC (libimobiledevice loaded at runtime) | 🟡 needs `brew install libimobiledevice` |
| USB MTP devices: storage browsing, copy, mkdir, rename, permanent delete | 🟡 needs `brew install libmtp`. Pixel 9a read-only browsing verified, physical write/transfer checks pending. See [MTP support](MTP.md). |
| iCloud settings sync | 🟡 needs iCloud entitlement |
| Settings: 6 tabs with the guide's defaults | ✅ rendered |

## Intentionally different
- Name, icon, sounds and templates are original. Nothing is copied from the Folders Pro bundle.
- No Paddle licensing, trial, Sparkle updater or Sentry telemetry.
- Only English is localized.

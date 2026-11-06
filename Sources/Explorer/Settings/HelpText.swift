import Foundation

/// In-app help (written for Explorer).
enum HelpText {
    static let shortcuts = """
    **Keyboard Shortcuts**

    ⏎  Open (or Rename, per Settings)
    ␣  Quick Look
    F2, ⌘⏎, ⇧⏎  Rename
    ⌘,  Settings      ⌘H  Hide Explorer      ⌥⌘H  Hide Others      ⌘Q  Quit
    ⌘N  New Window      ⌘T  New Tab
    ⇧⌘N  New Folder…     ⌃⇧⌘N  New Folder with Selection…
    ⌥⌘N  New Empty File…     ⌃⌘N  New File from Clipboard…
    ⌘O, ⌘↓  Open      ⌥⌘O  Open in New Window      ⌃⌘O  Open in New Tab
    ⌘W  Close      ⌥⌘W  Close All Windows
    ⌫  Move to Trash or Back (when enabled in Settings)
    ⌘⌫, ⌦  Move to Trash      ⌥⌘⌫, ⌥⌦  Delete Permanently
    ⌘E  Eject      ⌘D  Duplicate      ⌘R  Extract
    ⌃⌘T  Add to / Remove from Favorites
    ⌃⌘1…⌃⌘5  Set star rating      ⌃⌘0  Remove star rating
    ⌘F  Find
    ⌘Z  Undo      ⇧⌘Z  Redo
    ⌘X  Cut via Trash      ⌥⌘X  Cut
    ⌘C  Copy      ⌥⌘C  Copy as Path
    ⌘V  Paste      ⌥⌘V  Move Item(s) Here      ⇧⌘V  Paste as Symlink(s)      ⌃⌘V  Paste as Alias(es)
    ⌘A  Select All      ⌥⌘A  Deselect All
    ⌘-  Zoom out / smaller icons      ⌘=  Zoom in / larger icons
    ⌘→  Add selected items to Shelf (⌘← in right-to-left layouts)
    =  Calculate Folder Size (Table View)
    ⌘[  Back      ⌘]  Forward      ⌘↑  Enclosing folder
    ⇧⌘G  Go to Folder…      ⌘K  Mount Network Share…
    ⇧⌘\\  Show All Tabs      ⌘M  Minimize
    ⌘1 / ⌘2 / ⌘3 / ⌘4  View as Icons / List / Table / Gallery
    ⌘0  Group Folders First      ⌥⌘0  Group Folders Last
    ⌥⌘S  Sidebar      ⌥⌘P  Path Bar      ⌘/  Status Bar      ⌥⌘/  Action Toolbar
    ⌘.  Hidden files      ⌘I  File Info      ⌘J  Remember View Options for This Folder
    ⌥↑ / ⌥↓  Folder tree: previous / next top-level destination
    ⌥1…⌥4  Folder tree: expand/collapse unselectable top-level group 1 through 4

    Return and Delete follow Settings. File commands use the focused file view or supported tree node.
    Text fields keep normal editing keys. Folder-size calculation applies only to Table View, not archives.
    """

    static let guide = """
    **Explorer User’s Guide**

    Explorer is a tree-based file manager. The Folder Tree on the left lists your Favorites, Home, drives, network shares, cloud storage, iOS devices, recent files, tags, ratings, saved searches and the Trash (configure in Settings › Sidebar). The current folder appears in one of four File Views: Icons, List, Table or Gallery.

    **Shelf** — Drag items onto the flap on the right edge (or press ⌘→) to collect them from several folders, then drag them anywhere at once.

    **Search** — Type in the search field. Spotlight is used by default; switch to a Full Scan for locations Spotlight does not index. Save Spotlight searches to show them under Saved searches.

    **Batch Rename** — Select items and choose Batch Rename… Chain steps (replace text/regex, change case, add text/date/number/metadata) and review every resulting name before renaming. Undo restores the original names.

    **Conflicts** — When an item with the same name exists, choose Skip, Keep Both, Replace or Replace Older for files, or Skip, Merge or Replace for folders, optionally for all remaining conflicts.

    **Archives** — Zip, 7z, tar (gz/bz2/xz/lz4/zlib), tar.7z and rar can be browsed and extracted; zip, 7z and tar variants can be modified. Compress with Compress to ZIP or choose a format; Protected variants ask for a password.

    **Network shares** — ⌘K lists SMB/AFP/NFS servers on your network. Pin shares to keep them in the tree; remount them all with Go › Remount All Pinned Shares.

    **Actions** — Define shell or AppleScript commands in Settings › Scripting using {path}, {name}, {stem} and {dir}. They appear under Actions in the context menu.

    **Command line** — Install the explorer tool in Settings › Scripting. `explorer` opens a window, `explorer DIR` opens a folder, `explorer FILE` reveals a file.

    **Source Control** — Inside a git working copy, items show status badges (M A D R C ? U !). Stage, unstage, discard, commit, pull and push from the Source Control menu.

    **iOS devices** — With libimobiledevice installed (brew install libimobiledevice), connected iPhones and iPads appear under iOS Devices and can be browsed over AFC.

    **Drag and drop** — Plain drag moves (or follows Finder rules per Settings), ⌥ copies, ⌘ moves, ⌃ creates links.
    """

    static let acknowledgments = """
    **Acknowledgments**

    Explorer uses the following open-source software:

    **PLzmaSDK** — Copyright (c) 2015–2025 Oleh Kulykov. MIT License. Includes the LZMA SDK by Igor Pavlov (public domain).

    **libarchive** — Copyright (c) 2003–2018 Tim Kientzle and contributors. BSD 2-Clause License. (System library.)

    **libimobiledevice** (optional, loaded at runtime when installed) — Copyright (c) Nikias Bassen, Martin Szulecki and contributors. LGPL 2.1.

    Apple, Mac, macOS, Finder, Spotlight, Quick Look, Live Text, iCloud and SF Symbols are trademarks of Apple Inc.

    Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions: The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software. THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND.
    """
}

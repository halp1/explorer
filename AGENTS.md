# App installation

After every Explorer app change, run `make install` unless the user explicitly defers deployment. It builds release and installs the new [Explorer.app](</Applications/Explorer.app>), replacing the whole old bundle and removing a verified obsolete `~/Applications/Explorer.app` duplicate.

Use the guarded installer through `make install`. Quit Explorer gracefully, verify resolved paths, executable hashes, and codesign, keep the previous bundle recoverable until verification succeeds, and launch the exact canonical path. Never force quit Explorer or remove preferences, support data, unrelated files, or unsafe symlink targets.

#!/bin/bash
set -euo pipefail

fail() {
    printf '%s\n' "$*" >&2
    exit 1
}
root=$(cd -P "$(dirname "$0")/.." && pwd)
source="$root/build/Explorer.app"
target=/Applications/Explorer.app
legacy="${HOME:?}/Applications/Explorer.app"
stage=''
verified=0
placed=0
[[ $# == 0 ]] || fail 'This installer only accepts the project release bundle.'

check_path() {
    if [[ "$1" != "$source" && "$1" != "$target" && "$1" != "$legacy" ]]
    then
        [[ "$stage" =~ ^/Applications/\.Explorer-install\.[[:alnum:]]{6}$ ]] || return 1
        [[ "$1" == "$stage" || "$1" == "$stage/Explorer.app" || "$1" == "$stage/previous.app" ]] || return 1
    fi
    [[ "$1" == /* && ! -L "$1" ]] || return 1
    [[ "$(cd -P "$(dirname "$1")" && pwd)" == "$(dirname "$1")" ]] || return 1
    if [[ -e "$1" ]]
    then
        [[ -d "$1" && "$(cd -P "$1" && pwd)" == "$1" ]] || return 1
    fi
}
identity() {
    [[ -d "$1" && ! -L "$1/Contents" && ! -L "$1/Contents/Info.plist" ]] &&
        [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$1/Contents/Info.plist")" == com.halp.explorer ]]
}
hashes() {
    [[ ! -L "$1/Contents/MacOS" && ! -L "$1/Contents/Resources" ]] || return 1
    for file in Contents/MacOS/Explorer Contents/MacOS/com.halp.explorer.Helper Contents/Resources/explorer
    do
        [[ -f "$1/$file" && -x "$1/$file" && ! -L "$1/$file" ]] || return 1
    done
    (cd "${1:?}" && /usr/bin/shasum -a 256 Contents/MacOS/Explorer Contents/MacOS/com.halp.explorer.Helper Contents/Resources/explorer)
}
verify() {
    check_path "$1" && identity "$1" &&
        [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$1/Contents/Info.plist")" == Explorer ]] &&
        [[ -x "$1/Contents/MacOS/Explorer" ]] &&
        /usr/bin/codesign --verify --deep --strict "$1" &&
        [[ "$(hashes "$1")" == "$expected" ]]
}
finish() {
    status=$?
    trap - EXIT
    if [[ "$verified" == 0 ]]
    then
        if [[ "$placed" == 1 ]]
        then
            check_path "$target" && /bin/rm -rf -- "${target:?}" || exit 1
        fi
        if [[ -e "$stage/previous.app" ]]
        then
            check_path "$stage/previous.app" && check_path "$target" &&
                [[ ! -e "$target" ]] && /bin/mv -- "${stage:?}/previous.app" "${target:?}" || exit 1
            printf 'Restored previous Explorer app.\n' >&2
        fi
    fi
    check_path "$stage" && /bin/rm -rf -- "${stage:?}" || exit 1
    exit "$status"
}
running() {
    /usr/bin/osascript -l JavaScript -e 'ObjC.import("AppKit")' \
        -e '$.NSRunningApplication.runningApplicationsWithBundleIdentifier("com.halp.explorer").count'
}

check_path "$source" && identity "$source" || fail 'Unsafe or invalid source bundle.'
check_path "$target" || fail 'Unsafe canonical installation path.'
if [[ -e "$target" ]]
then
    identity "$target" || fail 'Canonical path contains an unexpected app.'
fi
expected=$(hashes "$source")
verify "$source" || fail 'Source signature or executable verification failed.'
stage=$(/usr/bin/mktemp -d /Applications/.Explorer-install.XXXXXX)
check_path "$stage" || fail 'Unexpected staging path.'
trap finish EXIT
trap 'exit 1' HUP INT TERM
/usr/bin/ditto "${source:?}" "${stage:?}/Explorer.app"
verify "$stage/Explorer.app" || fail 'Staged bundle verification failed.'
count=$(running)
if [[ "$count" != 0 ]]
then
    /usr/bin/osascript -e 'with timeout of 60 seconds' \
        -e 'if application id "com.halp.explorer" is running then' \
        -e 'tell application id "com.halp.explorer" to quit' \
        -e 'end if' -e 'end timeout'
    for attempt in {1..30}
    do
        count=$(running)
        [[ "$count" == 0 ]] && break
        /bin/sleep 1
    done
fi
[[ "$(running)" == 0 ]] || fail 'Explorer did not quit. No app bundles were moved.'
if [[ -e "$target" ]]
then
    check_path "$target" && identity "$target" && check_path "$stage/previous.app" &&
        [[ ! -e "$stage/previous.app" ]] || fail 'Unsafe backup paths.'
    /bin/mv -- "${target:?}" "${stage:?}/previous.app"
fi
check_path "$stage/Explorer.app" && check_path "$target" && [[ ! -e "$target" ]] || fail 'Unsafe replacement paths.'
/bin/mv -- "${stage:?}/Explorer.app" "${target:?}"
placed=1
verify "$target" || fail 'Installed verification failed. Restoring previous app.'
verified=1
if [[ -e "$legacy" || -L "$legacy" ]]
then
    if check_path "$legacy" && identity "$legacy" && [[ ! "$legacy" -ef "$target" ]]
    then
        /bin/rm -rf -- "${legacy:?}"
    else
        printf 'Skipped unsafe or unrelated ~/Applications/Explorer.app.\n' >&2
    fi
fi
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "${target:?}"
/usr/bin/open "${target:?}"
printf 'Installed and launched %s\n' "$target"

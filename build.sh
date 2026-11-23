#!/bin/bash
# Builds build/toyl.app with the Xcode Command Line Tools (no Xcode project, as Oyl is built),
# installs it in ~/Applications and links the `toyl` command into ~/.local/bin.
# Usage: ./build.sh               build and install
#        ./build.sh --run         build, install, then (re)open it
#        ./build.sh --no-install  just build build/toyl.app (kept; otherwise it's removed once installed)
set -euo pipefail
cd "$(dirname "$0")"

APP=build/toyl.app
INSTALLED="$HOME/Applications/toyl.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Info.plist "$APP/Contents/Info.plist"
[[ -f Icon/toyl.icns ]] || Icon/make.sh
cp Icon/toyl.icns "$APP/Contents/Resources/toyl.icns"

# shellcheck disable=SC2046
swiftc -O -swift-version 5 -parse-as-library \
    -target "$(uname -m)-apple-macos26.0" \
    $(find Sources -name '*.swift' | sort) \
    -o "$APP/Contents/MacOS/toyl"

# Signed with a fixed local certificate rather than ad hoc, so macOS keeps toyl's permissions
# (the calendar) across rebuilds; made once, in its own keychain (Oyl's way of doing it).
KEYCHAIN="$HOME/Library/Keychains/toyl-signing.keychain-db"
KEYCHAIN_PASSWORD=toyl
IDENTITY="toyl local signing"
if [[ ! -f "$KEYCHAIN" ]]; then
    work=$(mktemp -d)
    trap 'rm -rf "$work"' EXIT
    cat > "$work/cert.cnf" <<CONFIG
[req]
distinguished_name = name
x509_extensions = extensions
prompt = no
[name]
CN = $IDENTITY
[extensions]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
CONFIG
    openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$work/cert.cnf" \
        -keyout "$work/key.pem" -out "$work/cert.pem" 2>/dev/null
    openssl pkcs12 -export -inkey "$work/key.pem" -in "$work/cert.pem" -name "$IDENTITY" \
        -passout pass:"$KEYCHAIN_PASSWORD" -out "$work/identity.p12" 2>/dev/null \
        || openssl pkcs12 -export -legacy -inkey "$work/key.pem" -in "$work/cert.pem" -name "$IDENTITY" \
            -passout pass:"$KEYCHAIN_PASSWORD" -out "$work/identity.p12"
    # create-keychain adds itself to the search list; put the list back as it was.
    searchList=$(security list-keychains -d user | xargs)
    security create-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
    # shellcheck disable=SC2086
    security list-keychains -d user -s $searchList
    security set-keychain-settings "$KEYCHAIN"
    security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
    security import "$work/identity.p12" -k "$KEYCHAIN" -P "$KEYCHAIN_PASSWORD" -T /usr/bin/codesign >/dev/null
    security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$KEYCHAIN_PASSWORD" "$KEYCHAIN" >/dev/null
fi
security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
# codesign only finds identities in the search list, so add the keychain for this step only.
searchList=$(security list-keychains -d user | xargs)
# shellcheck disable=SC2086
security list-keychains -d user -s $searchList "$KEYCHAIN"
status=0
codesign --force --sign "$IDENTITY" "$APP" || status=$?
# shellcheck disable=SC2086
security list-keychains -d user -s $searchList
[[ $status -eq 0 ]] || exit "$status"
echo "Built $APP"

[[ "${1:-}" == "--no-install" ]] && exit 0

# The app (not a command-line toyl, or Claude's MCP server, which run as "toyl mcp").
running=0
front=0
if pgrep -f 'toyl\.app/Contents/MacOS/toyl$' >/dev/null; then
    running=1
    # Whether toyl was the app in use (lsappinfo needs no permission).
    lsappinfo info -only bundleid "$(lsappinfo front)" 2>/dev/null | grep -q '"local.toyl"' && front=1
    osascript -e 'quit app id "local.toyl"' >/dev/null 2>&1 || true
    for _ in $(seq 1 50); do pgrep -f 'toyl\.app/Contents/MacOS/toyl$' >/dev/null || break; sleep 0.1; done
    # Any copy still open (there should only ever be one, but quit them all).
    pkill -TERM -f 'toyl\.app/Contents/MacOS/toyl$' 2>/dev/null || true
fi
mkdir -p "$HOME/Applications"
rm -rf "$INSTALLED"
cp -R "$APP" "$INSTALLED"
mkdir -p "$HOME/.local/bin"
ln -sfn "$INSTALLED/Contents/MacOS/toyl" "$HOME/.local/bin/toyl"
# Only one toyl on the Mac: the build copy goes once it's installed, so Spotlight, Launchpad and
# toyl:// links never find (or open) a second one.
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
"$LSREGISTER" -u "$APP" >/dev/null 2>&1 || true
rm -rf "$APP"
"$LSREGISTER" -f "$INSTALLED" >/dev/null 2>&1 || true
echo "Installed $INSTALLED (and the toyl command in ~/.local/bin)"

# Opened again as it was if it was open: its window back where it was (or not, if it was closed),
# in front only if toyl was the app in use, otherwise behind what you're doing, never taking the
# focus. With --run, opened in front.
if [[ "${1:-}" == "--run" || $front -eq 1 ]]; then
    open "$INSTALLED"
elif [[ $running -eq 1 ]]; then
    open -g "$INSTALLED"
fi

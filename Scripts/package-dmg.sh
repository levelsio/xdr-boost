#!/bin/sh
set -eu

build_dir=${1:-.build}
stage=$(mktemp -d "${TMPDIR:-/tmp}/xdr-boost-dmg.XXXXXX")
trap 'rm -rf "$stage"' EXIT HUP INT TERM
ditto "$build_dir/XDR Boost.app" "$stage/XDR Boost.app"
ln -s /Applications "$stage/Applications"
cp "$build_dir/INSTALL.txt" "$stage/INSTALL.txt"
hdiutil create -volname "XDR Boost" -srcfolder "$stage" -ov -format UDZO \
    "$build_dir/XDR-Boost.dmg"

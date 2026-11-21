#!/bin/sh
# Assemble the root filesystem.
#   mkrootfs.sh [--sealed] BINARY DEST
# By default: one binary in /bin and a symlink for each personality.
# With --sealed: the binary is /sbin/init and there is nothing else to run,
# and no directory anyone can write to.
set -eu
sealed=
if [ "$1" = --sealed ]; then sealed=1; shift; fi
bin=$(cd "$(dirname "$1")" && pwd)/$(basename "$1")
dest=$2
here=$(cd "$(dirname "$0")/.." && pwd)

mkdir -p "$dest"
cp -R "$here/rootfs/." "$dest/"
cd "$dest"
mkdir -p sbin dev proc sys run usr/bin usr/local/bin var
ln -s ../run var/run
if [ -n "$sealed" ]; then
    cp "$bin" sbin/init
    # Nobody can log in to an image with no shell.
    sed -i 's|:[^:]*$|:/sbin/nologin|' etc/passwd
else
    mkdir -p bin tmp root home var/tmp
    cp "$bin" bin/kcontaineros
    # The applet names come from the source, so the list cannot drift.
    for a in sh $(sed -n 's/^    (b"\([a-z]*\)", .*/\1/p' "$here/src/applets.rs"); do
        ln -s kcontaineros "bin/$a"
    done
    ln -s ../bin/kcontaineros sbin/init
fi

# Nothing in the image is writable, not even by its owner, except the two
# temporary directories of the full image.
find . -type d -exec chmod 555 {} +
find . -type f -exec chmod 444 {} +
chmod 555 "$(find . -name kcontaineros -o -path ./sbin/init -type f | head -1)"
[ -n "$sealed" ] || { chmod 1777 tmp var/tmp; chmod 500 root; }

# Fixed timestamps, so the same sources give the same layer.
find . -exec touch -h -d @0 {} +

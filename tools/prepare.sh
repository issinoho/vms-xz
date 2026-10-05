#!/usr/bin/env bash
# prepare.sh - build a VMS-ready source tree in staging/<name>-<version>/
#
#   1. fetch + verify the upstream tarball
#   2. extract it, apply patches/series, lay overlay/ over the top
#   3. run the upstream configure on this host, with every platform answer
#      taken from VMS probe results (probed.site) or hand-settled values
#      (vms-manual.site) instead of from Linux
#   4. generate gnulib's headers and config.h, copy them into the tree
#   5. write the MMS source lists and the configuration snapshot
#
# Nothing in staging/ is ever edited by hand: fix things in patches/ or overlay/.
set -euo pipefail

top=$(cd "$(dirname "$0")/.." && pwd)
. "$top/upstream.conf"
name=$UPSTREAM_NAME-$UPSTREAM_VERSION
tarball=$top/cache/$(basename "$UPSTREAM_URL")
stage=$top/staging/$name
hostcfg=$top/cache/hostcfg-$name
cfgdir=$top/overlay/vms/config
snapshot=$top/snapshot
# Configuration answers come from this node's VSI C run; both architectures
# share one CRTL feature set (see docs/vms-environment.md).
PRIMARY_NODE=${PRIMARY_NODE:-ia64}
PRIMARY_TRIPLET=ia64-hp-openvms

step() { echo "prepare: $*"; }
die() { echo "prepare: error: $*" >&2; exit 1; }

"$top/tools/fetch.sh" >/dev/null

# --- 2. extract, patch, overlay -------------------------------------------
step "extracting $name"
rm -rf "$stage"
mkdir -p "$top/staging"
tar -xzf "$tarball" -C "$top/staging"
[ -d "$stage" ] || die "tarball did not unpack to $stage"

while read -r p; do
    case $p in ''|'#'*) continue ;; esac
    step "patch $p"
    patch -d "$stage" -p1 -s --no-backup-if-mismatch -F0 < "$top/patches/$p" ||
        die "patch $p does not apply cleanly"
done < "$top/patches/series"

# overlay/ may only add files; changes to upstream files belong in patches/.
(cd "$top/overlay" && find . -type f) | while read -r f; do
    [ -e "$stage/$f" ] && die "overlay/$f would replace an upstream file; use a patch"
    true
done
cp -a "$top/overlay/." "$stage/"

# --- 3. host configure with VMS answers ----------------------------------
step "configure (host, VMS answers)"
rm -rf "$hostcfg"
mkdir -p "$hostcfg"
site=$hostcfg/vms.site
# Answers: the VSI C configure run (vms_configure.sh) if there is one, else the
# function/header probes; vms-manual.site last so it always wins.
answers=$cfgdir/configure-$PRIMARY_NODE.cache
if [ ! -f "$answers" ]; then
    # First pass of a new release: stage the tree for vms_configure.sh, which
    # writes the answers.  The result is not buildable on VMS yet.
    answers=$hostcfg/no-answers.site; : > "$answers"
    step "WARNING: no $(basename "$cfgdir")/configure-$PRIMARY_NODE.cache yet:" \
         "Linux answers (run tools/vms_configure.sh, then prepare again)"
fi
step "answers from $(basename "$answers")"
python3 "$top/tools/nextheaders_site.py" "$stage/configure" "$cfgdir/crtl_modules.txt" \
    > "$cfgdir/next-headers.site"
cat "$answers" "$cfgdir/next-headers.site" "$cfgdir/vms-manual.site" > "$site"
mapfile -t cfgargs < <(grep -v -e '^#' -e '^$' "$cfgdir/configure.args")
# Same --host as vms_configure.sh so configure takes the same code paths.
(cd "$hostcfg" && CONFIG_SITE=$site "$stage/configure" -q -C \
    --build="$("$stage/build-aux/config.guess")" --host=$PRIMARY_TRIPLET CC=gcc "${cfgargs[@]}" \
    > configure.out 2>&1) || { tail -20 "$hostcfg/configure.out"; die "configure failed"; }

# lzma.h includes its subheaders by flat names on VMS (patch 0004): copy
# src/liblzma/api/lzma/<name>.h to src/liblzma/api/lzma_<name>.h.
for h in "$stage"/src/liblzma/api/lzma/*.h; do
    cp "$h" "$stage/src/liblzma/api/lzma_$(basename "$h")"
done

# --- 4. generated headers and config.h -------------------------------------
printvar() {  # printvar <dir> <make variable>
    make -s -C "$hostcfg/$1" -f Makefile -f "$top/tools/printvar.mk" "print-$2"
}
built=$(printvar lib BUILT_SOURCES)
step "generating $(echo $built | wc -w) gnulib headers"
make -s -C "$hostcfg/lib" $built >/dev/null
for h in $built; do
    # Some are shipped in the source tree and not rebuilt (unicase tables).
    [ -f "$hostcfg/lib/$h" ] || { [ -f "$stage/lib/$h" ] && continue; die "no generated $h"; }
    mkdir -p "$stage/lib/$(dirname "$h")"
    cp "$hostcfg/lib/$h" "$stage/lib/$h"
done
# xz: AC_CONFIG_HEADER([config.h]), at the top; the sources include it as
# <config.h>, found through [.LIB] on the include path.
cp "$hostcfg/config.h" "$stage/lib/config.h"
# Defines from configure tests with no cache variable come from gcc on this
# host; turn off the ones VSI C does not have (overlay/vms/config/config-h-undef.txt).
while read -r macro; do
    case $macro in ''|'#'*) continue ;; esac
    grep -q "^#define $macro " "$stage/lib/config.h" || die "config-h-undef.txt: $macro is not defined"
    sed -i "s|^#define $macro .*|/* #undef $macro (OpenVMS: overlay/vms/config/config-h-undef.txt) */|" "$stage/lib/config.h"
done < "$cfgdir/config-h-undef.txt"
# Compare with the config.h of the VSI C configure run, when there is one.
vmscfgh=$top/cache/vmscfg-$name-$PRIMARY_NODE/config.h
if [ -f "$vmscfgh" ]; then
    norm() { grep -E '^#define|^/\* #undef' "$1" | sed 's| (OpenVMS:.*\*/| */|' | sort; }
    if ! diff -q <(norm "$vmscfgh") <(norm "$stage/lib/config.h") >/dev/null; then
        diff <(norm "$vmscfgh") <(norm "$stage/lib/config.h") >&2 || true
        die "config.h differs from the VSI C configure run's (above: < VSI C, > staged)"
    fi
    step "config.h matches the VSI C configure run's"
fi
# VSI C cannot #include a name with two dots: generated lib/malloc/*.gl.h
# become *_gl.h (patch 0001 includes them by that name on VMS).
for f in "$stage"/lib/malloc/*.gl.h; do
    [ -e "$f" ] || continue
    sed 's|<malloc/\([a-z_-]*\)\.gl\.h>|<malloc/\1_gl.h>|g' "$f" > "${f%.gl.h}_gl.h"
    rm "$f"
done

# --- 5. MMS source lists ---------------------------------------------------
# The "library" group is liblzma (paths relative to src/liblzma, some ../common);
# the programs xz, xzdec and lzmainfo share the "src" group (relative to src/).
lib_srcs=$(printvar src/liblzma liblzma_la_SOURCES | tr ' ' '\n' | grep '\.c$' | sort -u)
src_srcs=$( { printvar src/xz xz_SOURCES | tr ' ' '\n' | sed 's|^\.\./|| ; t; s|^|xz/|'
              printvar src/xzdec xzdec_SOURCES | tr ' ' '\n' | sed 's|^\.\./|| ; t; s|^|xzdec/|'
              printvar src/lzmainfo lzmainfo_SOURCES | tr ' ' '\n' | sed 's|^\.\./|| ; t; s|^|lzmainfo/|'
            } | grep '\.c$' | sort -u)
# Each program's objects, for descrip.mms (vms/progs.mms).
progobjs() {  # progobjs <dir> <var>
    printvar "src/$1" "$2" | tr ' ' '\n' | grep '\.c$' | xargs -n1 basename | sed 's/\.c$//' |
        sort -u | sed 's/.*/$(OBJ)&.OBJ/' | paste -sd, - | sed 's/,/, /g'
}
mkdir -p "$stage/vms"
{ echo "! Generated by tools/prepare.sh - do not edit: each program's objects"
  echo "XZ_OBJS = $(progobjs xz xz_SOURCES)"
  echo "XZDEC_OBJS = $(progobjs xzdec xzdec_SOURCES)"
  echo "LZMAINFO_OBJS = $(progobjs lzmainfo lzmainfo_SOURCES)"
} > "$stage/vms/progs.mms"
for list in "$lib_srcs" "$src_srcs"; do
    dups=$(echo "$list" | xargs -n1 basename | sort | uniq -d)
    [ -z "$dups" ] || die "duplicate object names: $dups"
done

mkdir -p "$stage/vms"
echo "$lib_srcs" > "$hostcfg/lib-sources.txt"
echo "$src_srcs" > "$hostcfg/src-sources.txt"
GEN_MMS_LIB_BASE=src/liblzma GEN_MMS_LIB_CFLAGS=LIB_CFLAGS python3 "$top/tools/gen_mms.py" "$cfgdir/ccflags.txt" "$hostcfg/lib-sources.txt" \
    "$hostcfg/src-sources.txt" "$top/overlay/vms/extra-sources.txt" > "$stage/vms/sources.mms"

# --- PCSI kit inputs (vms/kit/MAKE_KIT.COM builds the kit on each node) ----
if [ -d "$stage/vms/kit" ]; then
step "PCSI kit inputs"
: "${KIT_PRODUCER:=ISSINOHO}"
# Three-part versions: the third part is the PCSI update and our VMS patch
# level the ECO, so $UPSTREAM_VERSION-vms$VMS_PATCH_LEVEL is V<major>.<minor>-<update>E<level>.
IFS=. read -r major minor update _ <<< "$UPSTREAM_VERSION"
pcsiversion="V$major.$minor-${update:-0}E$VMS_PATCH_LEVEL"
kitversion="$UPSTREAM_VERSION-vms$VMS_PATCH_LEVEL"
kit=$stage/vms/kit
subst() {
    sed -e "s/@PRODUCER@/$KIT_PRODUCER/g" -e "s/@BASE@/$1/g" \
        -e "s/@PCSIVERSION@/$pcsiversion/g" -e "s/@VERSION@/$UPSTREAM_VERSION/g" \
        -e "s/@KITVERSION@/$kitversion/g" -e "s/@ARCH@/$2/g"
}
# The headers the kit installs, as PCSI file lines.
includes=$( { echo LZMA.H; (cd "$stage/src/liblzma/api" && ls lzma_*.h | tr a-z A-Z); } | sed 's|.*|    file [XZ.INCLUDE]&;|; s|;$| ;|')
for base in I64VMS X86VMS; do
    subst $base "" < "$kit/xz.pcsi\$desc_template" |
        awk -v d="$includes" '{ if ($0 == "@INCLUDES@") print d; else print }' > "$kit/XZ-$base.PCSI\$DESC"
    subst $base "" < "$kit/xz.pcsi\$text_template" > "$kit/XZ-$base.PCSI\$TEXT"
done
rm -f "$kit/xz.pcsi\$desc_template" "$kit/xz.pcsi\$text_template"
mv "$kit/xz\$startup.com" "$kit/XZ\$STARTUP.COM"
mv "$kit/xz\$setup.com" "$kit/XZ\$SETUP.COM"
subst "" "IA64 and x86-64" < "$kit/readme.vms" > "$kit/README.VMS"; rm -f "$kit/readme.vms"
mkdir -p "$kit/doc"
cp "$stage/COPYING" "$kit/doc/COPYING."
cp "$stage/COPYING.0BSD" "$kit/doc/COPYING.0BSD"
cp "$stage/NEWS" "$kit/doc/NEWS."
cp "$stage/src/xz/xz.1" "$kit/doc/XZ.1"
cp "$stage/src/xzdec/xzdec.1" "$kit/doc/XZDEC.1"
cp "$stage/src/lzmainfo/lzmainfo.1" "$kit/doc/LZMAINFO.1"
groff -man -Tascii -P-cbou "$stage/src/xz/xz.1" > "$kit/doc/XZ.TXT" 2>/dev/null
[ -s "$kit/doc/XZ.TXT" ] || die "groff did not render xz.1"
printf 'KIT_PRODUCER=%s\nPCSI_VERSION=%s\nKIT_VERSION=%s\n' "$KIT_PRODUCER" "$pcsiversion" \
    "$kitversion" > "$kit/kit.env"
fi

# --- snapshot: the resolved configuration, committed and reviewed ----------
mkdir -p "$snapshot"
cp "$stage/lib/config.h" "$snapshot/config.h"
echo "$lib_srcs" > "$snapshot/lib-sources.txt"
echo "$src_srcs" > "$snapshot/src-sources.txt"
# Every cached answer, and where it came from.
cat "$cfgdir/next-headers.site" "$cfgdir/vms-manual.site" > "$hostcfg/manual.site"
python3 "$top/tools/cfgreport.py" "$hostcfg/config.cache" "$answers" \
    "$hostcfg/manual.site" > "$snapshot/cache-answers.txt"
step "inherited-from-Linux answers: $(grep -c ' host$' "$snapshot/cache-answers.txt" || true)" \
     "(see snapshot/cache-answers.txt)"

step "staged $stage"
if ! git -C "$top" diff --quiet -- snapshot 2>/dev/null; then
    step "snapshot/ changed - review with: git diff -- snapshot"
fi

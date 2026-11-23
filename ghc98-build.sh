#!/bin/bash
# Compile GHC 9.8.4 from the unpacked release sources with Hadrian.
# Boot compiler: ghc94 / ghc-pkg94 (packaged in-chain GHC 9.4.8).
# Happy, alex, and the Hadrian plan are vendored under bootstrap/.
# This script does not copy a finished 9.8.4 prefix.
set -euo pipefail

ROOT=${1:?usage: ghc98-build.sh ROOT}
case "$ROOT" in
*/ghc94-work|*/ghc94-work/*|*/ghc98-work|*/ghc98-work/*)
	printf 'GHC98_FAILED: refusing to build inside an existing prefix tree\n'
	exit 1
	;;
esac

TREE=$ROOT/ghc-9.8.4
BOOTSTRAP=$ROOT/bootstrap
PREFIX=$ROOT/dest
WORK=$ROOT/work
TOOLS=$WORK/tools
GMP_INC=/usr/include
GMP_LIB=/usr/lib64
JOBS=8
FLAVOUR=default+no_dynamic_libs+no_dynamic_ghc+no_profiled_libs+no_split_sections
HAPPY_SHA=8b4e7dc5a6c5fd666f8f7163232931ab28746d0d17da8fa1cbd68be9e878881b
ALEX_SHA=8a13fa01ea00883aa3d75d15ce848835b18631b8c9a4966961492d7c6095226f

export LANG=C.UTF-8
export LC_ALL=C.UTF-8
unset LD_LIBRARY_PATH || true
unset GHC_PACKAGE_PATH || true

phase() { printf 'GHC98_PHASE %s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }
failed=0
fail() { failed=1; printf 'GHC98_FAILED: %s\n' "$*"; exit 1; }
trap 'rc=$?; if [ "$rc" -ne 0 ] && [ "$failed" != 1 ]; then printf "GHC98_FAILED: exit %s\n" "$rc"; fi' EXIT

GHC=${GHC94:-$(command -v ghc94 || true)}
GHC_PKG=${GHC_PKG94:-$(command -v ghc-pkg94 || true)}
[ -n "$GHC" ] && [ -x "$GHC" ] || fail "ghc94 is not on PATH"
[ -n "$GHC_PKG" ] && [ -x "$GHC_PKG" ] || fail "ghc-pkg94 is not on PATH"
GHC=$(readlink -f "$GHC")
GHC_PKG=$(readlink -f "$GHC_PKG")
ver=$("$GHC" --numeric-version | tr -d '[:space:]') || fail "ghc94 did not run"
[ "$ver" = "9.4.8" ] || fail "ghc94 numeric-version is '$ver'"

[ -d "$TREE/hadrian/bootstrap" ] || fail "unpacked tree missing hadrian: $TREE"
[ "$(tr -d '[:space:]' < "$TREE/VERSION")" = "9.8.4" ] || fail "VERSION is not 9.8.4"
[ -f "$BOOTSTRAP/plan-bootstrap-9_4_4.json" ] || fail "Hadrian plan missing"
[ -f "$BOOTSTRAP/hp2ps-C-gnu17.patch" ] || fail "hp2ps patch missing"
[ -f "$BOOTSTRAP/regen-parsers.sh" ] || fail "regen-parsers.sh missing"
[ -f "$BOOTSTRAP/cmp-regenerated.sh" ] || fail "cmp-regenerated.sh missing"
[ -d "$BOOTSTRAP/hadrian" ] || fail "vendored Hadrian deps missing"
[ -f "$GMP_INC/gmp.h" ] || fail "gmp.h missing"
[ -e "$GMP_LIB/libgmp.so" ] || fail "libgmp.so missing"
command -v python >/dev/null || fail "python missing"
command -v autoconf >/dev/null || fail "autoconf missing"
command -v perl >/dev/null || fail "perl missing"
command -v patch >/dev/null || fail "patch missing"
[ -x /usr/bin/gcc ] || fail "/usr/bin/gcc missing"
command -v ld.lld >/dev/null || fail "ld.lld missing"
[ ! -e "$PREFIX/bin/ghc" ] && [ ! -e "$PREFIX/bin/ghc-9.8.4" ] || fail "dest already has a compiler; refusing to reuse it"

mkdir -p "$WORK/logs" "$WORK/bin" "$WORK/bootbin" "$WORK/src" "$WORK/shipped" "$TOOLS"
export TMPDIR=$WORK/tmp
export TEMP=$TMPDIR
export TMP=$TMPDIR
mkdir -p "$TMPDIR"
ulimit -s unlimited 2>/dev/null || true
phase "start pid $$ script $0 boot $GHC"

check_sha() {
	local file=$1 expect=$2
	local got
	got=$(sha256sum "$file" | awk '{print $1}')
	[ "$got" = "$expect" ] || fail "sha256 $file is $got"
}

check_sha "$BOOTSTRAP/happy-1.20.1.1.tar.gz" "$HAPPY_SHA"
check_sha "$BOOTSTRAP/alex-3.2.7.4.tar.gz" "$ALEX_SHA"

cat > "$WORK/bin/gcc" << 'EOF'
#!/bin/bash
link=1
for a in "$@"; do
	case "$a" in
	-c|-E|-S|-M|-MM|-shared|--version|-dumpversion) link=0 ;;
	esac
done
args=(-fno-pie "$@")
if [ "$link" = 1 ]; then
	args+=(-no-pie)
fi
exec /usr/bin/gcc "${args[@]}"
EOF
chmod 755 "$WORK/bin/gcc"

cat > "$WORK/bootbin/ghc" << EOF
#!/bin/sh
exec $(printf '%q' "$GHC") "\$@"
EOF
cat > "$WORK/bootbin/ghc-pkg" << EOF
#!/bin/sh
exec $(printf '%q' "$GHC_PKG") "\$@"
EOF
# bootstrap.py requires ghc, ghc-pkg, and hsc2hs in one directory.
# The packaged names are ghc94 and ghc-pkg94; hsc2hs lives in the libdir.
libdir=$("$GHC" --print-libdir)
[ -x "$libdir/bin/hsc2hs" ] || fail "packaged hsc2hs missing: $libdir/bin/hsc2hs"
[ -f "$libdir/template-hsc.h" ] || fail "hsc2hs template missing: $libdir/template-hsc.h"
# The libdir program does not find template-hsc.h by itself. The
# prefix wrapper make install would have written passes it explicitly.
cat > "$WORK/bootbin/hsc2hs" << EOF
#!/bin/sh
exec $(printf '%q' "$libdir/bin/hsc2hs") --template=$(printf '%q' "$libdir/template-hsc.h") --lflag=-fuse-ld=lld "\$@" -I$(printf '%q' "$libdir/include/")
EOF
chmod 755 "$WORK/bootbin/ghc" "$WORK/bootbin/ghc-pkg" "$WORK/bootbin/hsc2hs"

clean=$(printf '%s' "$PATH" | tr ':' '\n' | grep -v -e '\.ghcup' -e '\.cabal' -e '/ghc[0-9]' -e '/happy' || true)
clean=$(printf '%s\n' "$clean" | paste -sd: -)
export PATH="$WORK/bootbin:$TOOLS/bin:$WORK/bin:$clean"
export CC="$WORK/bin/gcc"
export CFLAGS="-std=gnu11 -w"
hash -r
command -v ghc | grep -F -q "$WORK/bootbin/ghc" || fail "PATH ghc is $(command -v ghc)"
command -v gcc | grep -F -q "$WORK/bin/gcc" || fail "PATH gcc is $(command -v gcc)"

build_tool() {
	local tar=$1 name=$2 ver=$3
	local src=$WORK/src/$name-$ver
	phase "build $name-$ver"
	rm -rf "$src"
	tar -C "$WORK/src" -xzf "$tar"
	[ -f "$src/Setup.hs" ] || fail "$name has no Setup.hs"
	(
		cd "$src"
		"$GHC" --make -v0 Setup.hs -o Setup
		./Setup configure -v0 --prefix="$TOOLS" \
			--with-compiler="$GHC" --with-hc-pkg="$GHC_PKG" \
			--ghc-option=-rtsopts
		./Setup build -v0
		./Setup install -v0
	) > "$WORK/logs/$name-setup.log" 2>&1 || fail "$name setup: $(tail -20 "$WORK/logs/$name-setup.log" | tr '\n' ' ' | cut -c1-700)"
}

build_tool "$BOOTSTRAP/alex-3.2.7.4.tar.gz" alex 3.2.7.4
build_tool "$BOOTSTRAP/happy-1.20.1.1.tar.gz" happy 1.20.1.1

wrap_rts() {
	local bin=$1 rts=$2
	[ -x "$bin" ] || fail "missing $bin"
	mv "$bin" "$bin.real"
	cat > "$bin" << EOF
#!/bin/bash
exec "\$(dirname "\$0")/$(basename "$bin").real" $rts "\$@"
EOF
	chmod 755 "$bin"
}
wrap_rts "$TOOLS/bin/alex" "+RTS -K64M -RTS"
wrap_rts "$TOOLS/bin/happy" "+RTS -K64M -H128M -RTS"
hash -r
aver=$("$TOOLS/bin/alex" --version | tr -d '\r')
printf '%s\n' "$aver" | grep -q 'Alex version 3.2.7.4' || fail "alex is '$aver'"
hver=$("$TOOLS/bin/happy" --version | tr -d '\r')
printf '%s\n' "$hver" | grep -q 'Happy Version 1.20.1.1' || fail "happy is '$hver'"
phase "tools alex 3.2.7.4 happy 1.20.1.1"

cd "$TREE"
phase "hp2ps C23 patch"
if ! patch -p1 -i "$BOOTSTRAP/hp2ps-C-gnu17.patch" > "$WORK/logs/patch.log" 2>&1; then
	fail "patch: $(tail -15 "$WORK/logs/patch.log" | tr '\n' ' ' | cut -c1-500)"
fi

phase "regen parsers"
if ! SHIPPED="$WORK/shipped" sh "$BOOTSTRAP/regen-parsers.sh" > "$WORK/logs/regen.log" 2>&1; then
	fail "regen-parsers: $(tail -20 "$WORK/logs/regen.log" | tr '\n' ' ' | cut -c1-700)"
fi
phase "regen $(grep -c '^regen-parsers:' "$WORK/logs/regen.log" || true) lines"

phase "configure"
if ! ./configure --prefix="$PREFIX" GHC="$GHC" CC="$WORK/bin/gcc" \
	--with-gmp-includes="$GMP_INC" --with-gmp-libraries="$GMP_LIB" \
	> "$WORK/logs/configure.log" 2>&1
then
	fail "configure: $(tail -20 "$WORK/logs/configure.log" | tr '\n' ' ' | cut -c1-700)"
fi
grep -F "GHC=$GHC" config.log >/dev/null || fail "config.log did not record ghc94"
grep -F "$TOOLS/bin/happy" hadrian/cfg/system.config >/dev/null || fail "system.config did not record happy"
grep -F "$TOOLS/bin/alex" hadrian/cfg/system.config >/dev/null || fail "system.config did not record alex"
phase "configured"

phase "bootstrap hadrian"
rm -rf "$WORK/bs" hadrian/_build
mkdir -p "$WORK/bs"
python - "$BOOTSTRAP/plan-bootstrap-9_4_4.json" "$BOOTSTRAP/hadrian" "$WORK/bs" "$GHC_PKG" << 'PY'
import json, shutil, subprocess, sys
from pathlib import Path
plan_path, deps, bs, ghc_pkg = map(Path, sys.argv[1:])
plan = json.loads(plan_path.read_text())
for b in plan["builtin"]:
    p = subprocess.run([str(ghc_pkg), "field", b["package"], "version", "--simple-output"],
                       capture_output=True, text=True)
    if p.returncode != 0 or not p.stdout.split():
        sys.stderr.write("ghc-pkg field %s failed: %s\n" % (b["package"], p.stderr))
        sys.exit(1)
    v = p.stdout.split()[0]
    if v != b["version"]:
        print("plan: %s %s -> %s" % (b["package"], b["version"], v), flush=True)
    b["version"] = v
for d in plan["dependencies"]:
    if d.get("source") != "hackage":
        continue
    tb = deps / ("%s-%s.tar.gz" % (d["package"], d["version"]))
    cb = deps / ("%s.cabal" % d["package"])
    if not tb.is_file() or not cb.is_file():
        sys.stderr.write("missing vendored %s-%s\n" % (d["package"], d["version"]))
        sys.exit(1)
    shutil.copyfile(tb, bs / tb.name)
    shutil.copyfile(cb, bs / cb.name)
(bs / "plan-bootstrap.json").write_text(json.dumps(plan, indent=1) + "\n")
print("bootstrap sources staged", flush=True)
PY
tar -C "$WORK/bs" -czf "$WORK/bootstrap-sources.tar.gz" .
if ! (cd hadrian && python bootstrap/bootstrap.py -w "$WORK/bootbin/ghc" -s "$WORK/bootstrap-sources.tar.gz" --no-archive) \
	> "$WORK/logs/hadrian-bootstrap.log" 2>&1
then
	fail "hadrian bootstrap: $(tail -30 "$WORK/logs/hadrian-bootstrap.log" | tr '\n' ' ' | cut -c1-800)"
fi
[ -x hadrian/_build/bin/hadrian ] || fail "hadrian binary missing"
phase "hadrian bootstrapped"

phase "hadrian -j$JOBS binary-dist"
if ! stdbuf -oL -eL hadrian/_build/bin/hadrian -j"$JOBS" --flavour="$FLAVOUR" --docs=none binary-dist-dir \
	> "$WORK/logs/make.log" 2>&1
then
	fail "hadrian build: $(tail -30 "$WORK/logs/make.log" | tr '\n' ' ' | cut -c1-800)"
fi
phase "binary-dist rc=0"

phase "cmp generated"
if ! SHIPPED="$WORK/shipped" sh "$BOOTSTRAP/cmp-regenerated.sh" > "$WORK/logs/cmp-regenerated.log" 2>&1; then
	fail "cmp-regenerated: $(tail -30 "$WORK/logs/cmp-regenerated.log" | tr '\n' ' ' | cut -c1-800)"
fi
phase "parsers compared"

phase "install"
if ! hadrian/_build/bin/hadrian -j1 --flavour="$FLAVOUR" --docs=none --prefix="$PREFIX" install \
	> "$WORK/logs/install.log" 2>&1
then
	fail "install: $(tail -30 "$WORK/logs/install.log" | tr '\n' ' ' | cut -c1-800)"
fi

if [ -f "$PREFIX/lib/ghc-9.8.4/lib/settings" ]; then
	ghclib=$PREFIX/lib/ghc-9.8.4
elif [ -f "$PREFIX/lib64/ghc-9.8.4/lib/settings" ]; then
	ghclib=$PREFIX/lib64/ghc-9.8.4
else
	fail "install tree has no settings"
fi
cp -f "$WORK/bin/gcc" "$ghclib/bin/host-gcc"
chmod 755 "$ghclib/bin/host-gcc"
python - "$ghclib/lib/settings" '$topdir/../bin/host-gcc' << 'PY'
import pathlib, re, sys
path, rel = sys.argv[1], sys.argv[2]
file = pathlib.Path(path)
text = file.read_text()
def repl(m):
    return '("%s", "%s")' % (m.group(1), rel)
new, n = re.subn(
    r'\("(C compiler command|Haskell CPP command)", "[^"]*"\)',
    repl,
    text,
)
if n != 2:
    sys.stderr.write("rewrote %s settings entries\n" % n)
    sys.exit(1)
file.write_text(new)
PY
phase "settings use \$topdir/../bin/host-gcc"

ELF=$ghclib/bin/ghc-9.8.4
TOP=$ghclib/lib
[ -x "$ELF" ] || fail "installed ELF missing"
file "$ELF" | grep -q ELF || fail "installed driver is not an ELF"
iver=$("$ELF" -B"$TOP" --numeric-version | tr -d '[:space:]') || fail "installed ghc did not run"
[ "$iver" = "9.8.4" ] || fail "installed numeric-version '$iver'"
iver2=$("$ELF" -B"$TOP" --numeric-version | tr -d '[:space:]')
[ "$iver2" = "9.8.4" ] || fail "second numeric-version '$iver2'"
"$ghclib/bin/ghc-pkg-9.8.4" --global-package-db "$TOP/package.conf.d" field ghc-bignum library-dirs \
	> "$WORK/logs/gmp-libdir.log"
grep -q "$GMP_LIB" "$WORK/logs/gmp-libdir.log" || fail "ghc-bignum library-dirs missing $GMP_LIB"
raw=$("$ghclib/bin/ghc-pkg-9.8.4" --global-package-db "$TOP/package.conf.d" field base import-dirs --simple-output --no-expand-pkgroot | tr -d '[:space:]')
case "$raw" in
'${pkgroot}'/*) ;;
*) fail "base import-dirs are not pkgroot-relative: $raw" ;;
esac
case "$raw" in
*"$PREFIX"*) fail "base import-dirs contain the install prefix" ;;
esac

phase "sum10"
for i in 1 2; do
	d=$WORK/sum10-$i
	rm -rf "$d"
	mkdir -p "$d"
	cat > "$d/Helper.hs" << 'EOF'
module Helper (sumList) where

sumList :: [Int] -> Int
sumList [] = 0
sumList (x:xs) = x + sumList xs
EOF
	cat > "$d/Main.hs" << 'EOF'
module Main where

import Helper

main :: IO ()
main = do
    let xs = [1, 2, 3, 4]
    putStrLn (show (sumList xs))
EOF
	(
		cd "$d"
		"$ELF" -B"$TOP" -v0 --make Main.hs -o sum10
		./sum10 > out
	) > "$WORK/logs/sum10-$i.log" 2>&1 || fail "sum10-$i: $(tail -20 "$WORK/logs/sum10-$i.log" | tr '\n' ' ' | cut -c1-500)"
	got=$(tr -d '[:space:]' < "$d/out")
	[ "$got" = "10" ] || fail "sum10-$i output '$got'"
done
phase "sum10 ok"

# Compile again after the libdir has moved, so absolute paths cannot pass.
phase "relocate"
reldir=$WORK/relocated
rm -rf "$reldir"
mkdir -p "$reldir" "$WORK/sum10-reloc"
cp -f "$WORK/sum10-1/Helper.hs" "$WORK/sum10-1/Main.hs" "$WORK/sum10-reloc/"
mv "$ghclib" "$reldir/ghc-9.8.4"
set +e
(
	cd "$WORK/sum10-reloc"
	"$reldir/ghc-9.8.4/bin/ghc-9.8.4" -B"$reldir/ghc-9.8.4/lib" -v0 --make Main.hs -o sum10
	./sum10 > out
) > "$WORK/logs/sum10-reloc.log" 2>&1
rc=$?
set -e
mv "$reldir/ghc-9.8.4" "$ghclib"
[ "$rc" = 0 ] || fail "relocate compile: $(tail -20 "$WORK/logs/sum10-reloc.log" | tr '\n' ' ' | cut -c1-500)"
got=$(tr -d '[:space:]' < "$WORK/sum10-reloc/out")
[ "$got" = "10" ] || fail "relocate output '$got'"
phase "relocate ok"

file "$ELF" | tee "$WORK/logs/file-ghc.txt"
printf 'GHC98_DONE installed %s numeric-version %s\n' "$ELF" "$iver"

%global debug_package %{nil}
%global _find_debuginfo_opts --no-ar-files
Summary:	Glasgow Haskell Compiler 9.8.4 (bootstrapped with in-chain GHC 9.4.8)
Name:		ghc98
Version:	9.8.4
Release:	1
License:	BSD
Group:		Development/Other
Url:		https://www.haskell.org/ghc/
# Complement package. Does not replace distro ghc, so no Epoch.
# The host is packaged ghc94 (GHC 9.4.8). Hadrian dependencies,
# happy, and alex are in the bootstrap kit. This spec compiles the
# 9.8.4 sources; it does not copy a prebuilt prefix.
ExclusiveArch:	x86_64 znver1
Source0:	ghc-9.8.4-src.tar.xz
Source1:	ghc98-bootstrap-kit.tar.gz
Source2:	ghc98-build.sh
Source3:	%{name}.rpmlintrc

BuildRequires:	ghc94
BuildRequires:	make
BuildRequires:	python
BuildRequires:	perl
BuildRequires:	autoconf
BuildRequires:	automake
BuildRequires:	patch
BuildRequires:	gcc
BuildRequires:	lld
BuildRequires:	diffutils
BuildRequires:	binutils
BuildRequires:	pkgconfig(gmp)
BuildRequires:	pkgconfig(ncurses)
BuildRequires:	pkgconfig(libffi)
BuildRequires:	pkgconfig(numa)
BuildRequires:	file
BuildRequires:	tar
BuildRequires:	xz
BuildRequires:	gzip

%description
GHC 9.8.4 compiled from its Haskell sources by packaged GHC 9.4.8
(Hadrian, static libraries, host GMP). No upstream bindist and no
GHCup compiler. This is the first compiler in the climb new enough
to build pandoc 3.11 (GHC >= 9.6).

Installed as ghc98 / ghc-9.8.4 so it can coexist with ghc94, ghc7.0,
and a distro GHC.

%prep
set -eu
cd %{_builddir}
rm -rf ghc98-root
mkdir -p ghc98-root
tar -xJf %{SOURCE0} -C ghc98-root
tar -xzf %{SOURCE1} -C ghc98-root
test -d ghc98-root/ghc-9.8.4/hadrian/bootstrap
test "$(tr -d '[:space:]' < ghc98-root/ghc-9.8.4/VERSION)" = "9.8.4"
test -f ghc98-root/bootstrap/plan-bootstrap-9_4_4.json
test -f ghc98-root/bootstrap/hp2ps-C-gnu17.patch
test -f ghc98-root/bootstrap/regen-parsers.sh
test -f ghc98-root/bootstrap/cmp-regenerated.sh
test -d ghc98-root/bootstrap/hadrian
test -f ghc98-root/bootstrap/happy-1.20.1.1.tar.gz
test -f ghc98-root/bootstrap/alex-3.2.7.4.tar.gz
test -f %{SOURCE2}
set +u

%build
set -eu
bash %{SOURCE2} "%{_builddir}/ghc98-root"
set +u

%install
set -eu
dest=%{_builddir}/ghc98-root/dest
if [ -d "$dest/lib/ghc-9.8.4" ]; then
	src=$dest/lib/ghc-9.8.4
elif [ -d "$dest/lib64/ghc-9.8.4" ]; then
	src=$dest/lib64/ghc-9.8.4
else
	echo "ghc98: install tree has no lib/ghc-9.8.4" >&2
	exit 1
fi
mkdir -p %{buildroot}%{_libdir} %{buildroot}%{_bindir}
cp -a "$src" %{buildroot}%{_libdir}/ghc-9.8.4
test -x %{buildroot}%{_libdir}/ghc-9.8.4/bin/ghc-9.8.4
file %{buildroot}%{_libdir}/ghc-9.8.4/bin/ghc-9.8.4 | grep -q ELF
test -f %{buildroot}%{_libdir}/ghc-9.8.4/lib/settings
test -x %{buildroot}%{_libdir}/ghc-9.8.4/bin/host-gcc
libname=$(basename %{_libdir})
cat > %{buildroot}%{_bindir}/ghc98 << EOF
#!/bin/sh
if [ -x "\$0" ] && [ "\$0" != "\${0#*/}" ]; then
	arg0=\$0
else
	arg0=\$(command -v "\$0") || exit 1
fi
here=\$(CDPATH= cd -- "\$(dirname "\$arg0")" && pwd)
root=\$(dirname "\$here")
exec "\$root/$libname/ghc-9.8.4/bin/ghc-9.8.4" -B"\$root/$libname/ghc-9.8.4/lib" "\$@"
EOF
cat > %{buildroot}%{_bindir}/ghc-pkg98 << EOF
#!/bin/sh
if [ -x "\$0" ] && [ "\$0" != "\${0#*/}" ]; then
	arg0=\$0
else
	arg0=\$(command -v "\$0") || exit 1
fi
here=\$(CDPATH= cd -- "\$(dirname "\$arg0")" && pwd)
root=\$(dirname "\$here")
top="\$root/$libname/ghc-9.8.4"
exec "\$top/bin/ghc-pkg-9.8.4" --global-package-db "\$top/lib/package.conf.d" "\$@"
EOF
chmod 755 %{buildroot}%{_bindir}/ghc98 %{buildroot}%{_bindir}/ghc-pkg98
ln -sfn ghc98 %{buildroot}%{_bindir}/ghc-9.8.4
ln -sfn ghc-pkg98 %{buildroot}%{_bindir}/ghc-pkg-9.8.4
set +u

%files
%{_bindir}/ghc98
%{_bindir}/ghc-pkg98
%{_bindir}/ghc-9.8.4
%{_bindir}/ghc-pkg-9.8.4
%{_libdir}/ghc-9.8.4/

%check
set -eu
cd %{_builddir}
export PATH=%{buildroot}%{_bindir}:$PATH
hash -r
command -v ghc98 | grep -q '%{buildroot}'
b=$(command -v ghc98)
g=%{buildroot}%{_libdir}/ghc-9.8.4
test -x "$g/bin/ghc-9.8.4"
file "$g/bin/ghc-9.8.4" | grep -q ELF
test -f "$g/lib/settings"
test -x "$g/bin/host-gcc"
"$b" --numeric-version | tee numeric.out
test "$(cat numeric.out)" = "9.8.4"
"$b" --numeric-version | tee numeric2.out
test "$(cat numeric2.out)" = "9.8.4"
cat > Helper.hs << 'EOF'
module Helper (sumList) where

sumList :: [Int] -> Int
sumList [] = 0
sumList (x:xs) = x + sumList xs
EOF
cat > Main.hs << 'EOF'
module Main where

import Helper

main :: IO ()
main = do
	let xs = [1, 2, 3, 4]
	putStrLn (show (sumList xs))
EOF
rm -rf sum-a sum-b
mkdir sum-a sum-b
cp Helper.hs Main.hs sum-a/
cp Helper.hs Main.hs sum-b/
( cd sum-a && "$b" -v0 --make Main.hs -o sum10 && ./sum10 ) > sum-a.out
test "$(cat sum-a.out)" = "10"
( cd sum-b && "$b" -v0 --make Main.hs -o sum10 && ./sum10 ) > sum-b.out
test "$(cat sum-b.out)" = "10"
set +u

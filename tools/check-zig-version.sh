#!/bin/sh
# Fail unless `${ZIG:-zig} version` is at least build.zig.zon's
# minimum_zig_version. A pre-release of the minimum (0.17.0-dev...) counts
# as older than the minimum release.
#
#   tools/check-zig-version.sh            # checks `zig`
#   ZIG=zig-nightly tools/check-zig-version.sh
set -eu
cd "$(dirname "$0")/.."
zig=${ZIG:-zig}
min=$(sed -n 's/^ *\.minimum_zig_version *= *"\([^"]*\)".*/\1/p' build.zig.zon)
have=$("$zig" version)
if [ -z "$min" ]; then
	echo "check-zig-version: no minimum_zig_version in build.zig.zon" >&2
	exit 1
fi

too_old() {
	echo "check-zig-version: $zig $have is older than minimum_zig_version $min" >&2
	exit 1
}

# X.Y.Z without any -prerelease or +build suffix.
base() { echo "$1" | sed 's/[-+].*//'; }
hb=$(base "$have")
mb=$(base "$min")
if [ "$hb" = "$mb" ]; then
	# Same release line: a pre-release is only enough if the minimum is one.
	case "$have" in *-*) case "$min" in *-*) ;; *) too_old ;; esac ;; esac
else
	lowest=$(printf '%s\n%s\n' "$hb" "$mb" | sort -t. -k1,1n -k2,2n -k3,3n | head -n 1)
	[ "$lowest" = "$mb" ] || too_old
fi
echo "$zig $have >= minimum_zig_version $min"

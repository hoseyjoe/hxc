#!/usr/bin/env bash
# Runs the .NET generator's cases in cases.hx.txt.
#   tests/dotnet/run.sh --compiler <hxc> [--std <dir>] [--case <name>]
# A case is `--- name [@lib] [@module=pack.Mod] [@dump=items] [+ extra hxc args]`, its source, `===`,
# and the expected result. Each case compiles twice into a fresh directory, and its .dll must be
# byte-identical between the two, pass ILVerify, run (unless @lib) and dump as expected.
set -u

here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/../.." && pwd)"
compiler=""
std=""
only=""
while [ $# -gt 0 ]; do
	case "$1" in
		--compiler) compiler="$2"; shift 2 ;;
		--std) std="$2"; shift 2 ;;
		--case) only="$2"; shift 2 ;;
		*) echo "unknown argument: $1" >&2; exit 2 ;;
	esac
done
if [ -z "$compiler" ]; then
	echo "usage: $0 --compiler <hxc> [--std <dir>] [--case <name>]" >&2
	exit 2
fi
compiler="$(cd "$(dirname "$compiler")" && pwd)/$(basename "$compiler")"
if [ -n "$std" ]; then export HAXE_STD_PATH="$std"; fi

checkdir="$root/tests/fixtures/hxccheck"
if ! log="$(dotnet build "$checkdir" -c Release -o "$checkdir/bin/out" -nologo -v q 2>&1)"; then
	echo "$log"
	echo "could not build HxcCheck" >&2
	exit 1
fi
check() { dotnet "$checkdir/bin/out/HxcCheck.dll" "$@"; }

# A native Windows path for a directory, when cygpath exists.
native() { cygpath -m "$1" 2>/dev/null || printf '%s' "$1"; }

# Line endings become \n, the case directory $CASE, trailing whitespace goes; the caller's $(...)
# drops trailing blank lines.
normalize() {
	local s="$1" d
	s="${s//$'\r'/}"
	for d in "$casedir" "$(native "$casedir")" "$(cygpath -w "$casedir" 2>/dev/null)"; do
		[ -n "$d" ] && s="${s//"$d"/\$CASE}"
	done
	printf '%s\n' "$s" | sed -e 's/[[:space:]]*$//'
}

failed=0
total=0

run_case() {
	local name="$1" tags="$2" extra="$3" source="$4" expected="$5"
	local lib=0 module="P" dump="" t
	for t in $tags; do
		case "$t" in
			@lib) lib=1 ;;
			@module=*) module="${t#@module=}" ;;
			@dump=*) dump="${t#@dump=}" ;;
			*) echo "$name: unknown tag $t" >&2; failed=$((failed + 1)); return ;;
		esac
	done
	total=$((total + 1))
	casedir="$(mktemp -d)"
	local file="P.hx"
	if [ "$module" != "P" ]; then file="$(printf '%s' "$module" | tr . /).hx"; fi
	mkdir -p "$casedir/$(dirname "$file")"
	printf '%s\n' "$source" > "$casedir/$file"

	local main=(--main "$module")
	if [ $lib = 1 ]; then main=("$module"); fi
	set -f
	local cout
	cout="$("$compiler" --cwd "$(native "$casedir")" -cp . "${main[@]}" --cs a/P -D dotnet $extra 2>&1)"
	"$compiler" --cwd "$(native "$casedir")" -cp . "${main[@]}" --cs b/P -D dotnet $extra > /dev/null 2>&1
	set +f

	local result="" problem="" dll="" f
	[ -n "$cout" ] && result="[compile]"$'\n'"$cout"
	for f in "$casedir"/a/P/*.dll; do [ -f "$f" ] && dll="$f" && break; done
	if [ -n "$dll" ]; then
		for f in "$casedir"/a/P/*; do
			if ! cmp -s "$f" "$casedir/b/P/$(basename "$f")"; then
				problem="${problem}not deterministic: $(basename "$f")"$'\n'
			fi
		done
		local vout
		if ! vout="$(check verify "$(native "$dll")" 2>&1)"; then problem="${problem}${vout}"$'\n'; fi
		if [ $lib = 0 ]; then
			local rout code=0
			rout="$(cd "$casedir" && dotnet "a/P/$(basename "$dll")" 2>&1)" || code=$?
			[ $code != 0 ] && rout="${rout}"$'\n'"[exit $code]"
			[ -n "$rout" ] && result="${result:+$result$'\n'}[run]"$'\n'"$rout"
		fi
		if [ -n "$dump" ]; then
			local dout
			dout="$(check dump "$(native "$dll")" "$dump" 2>&1)"
			[ -n "$dout" ] && result="${result:+$result$'\n'}[dump]"$'\n'"$dout"
		fi
	fi

	local want got
	want="$(normalize "$expected")"
	got="$(normalize "$result")"
	if [ -z "$problem" ] && [ "$want" = "$got" ]; then
		echo "ok $name"
	else
		echo "FAIL $name"
		[ -n "$problem" ] && printf '%s' "$problem"
		if [ "$want" != "$got" ]; then
			printf '%s\n' "$want" > "$casedir/expected.txt"
			printf '%s\n' "$got" > "$casedir/actual.txt"
			diff -u "$casedir/expected.txt" "$casedir/actual.txt" | tail -n +3
		fi
		failed=$((failed + 1))
	fi
	rm -rf "$casedir"
}

# Reads the cases: `#` and `# ` lines are comments, trailing blank lines of a block are dropped.
name=""
flush() {
	if [ -n "$name" ] && { [ -z "$only" ] || [ "$only" = "$name" ]; }; then
		run_case "$name" "$tags" "$extra" "$source" "$expected"
	fi
	name=""
}
while IFS= read -r line || [ -n "$line" ]; do
	line="${line%$'\r'}"
	if [ "$line" = "#" ] || [ "${line#\# }" != "$line" ]; then continue; fi
	if [ "${line#---}" != "$line" ]; then
		flush
		head="${line#---}"
		extra=""
		case "$head" in *" + "*) extra="${head#* + }"; head="${head%% + *}" ;; esac
		set -f
		set -- $head
		set +f
		name="$1"
		shift
		tags="$*"
		source=""
		expected=""
		inexpect=0
	elif [ -z "$name" ]; then
		continue
	elif [ "${line#===}" != "$line" ]; then
		inexpect=1
	elif [ $inexpect = 1 ]; then
		expected="$expected$line"$'\n'
	else
		source="$source$line"$'\n'
	fi
done < "$here/cases.hx.txt"
flush

if [ $total = 0 ]; then
	echo "no case matched" >&2
	exit 1
fi
if [ $failed != 0 ]; then
	echo "$failed of $total cases failed"
	exit 1
fi
echo "all $total cases passed"

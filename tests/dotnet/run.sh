#!/usr/bin/env bash
# Runs the .NET generator's cases in cases.hx.txt.
#   tests/dotnet/run.sh --compiler <hxc> [--std <dir>] [--case <name>] [--haxe <haxe>]
# A case is `--- name [@lib] [@module=pack.Mod] [@dump=items] [@gencs] [@stress-fieldlookup]
# [@runtimeconfig] [+ extra hxc args]`, its source, `===`, and the expected result. Each case
# compiles twice into a fresh directory, and its .dll must be byte-identical between the two, pass
# ILVerify, run (unless @lib) and dump as expected. A @stress-fieldlookup case's .dll must also pass
# HxcCheck's stress-fieldlookup (haxe.lang.FieldLookup called from many threads at once). A
# @runtimeconfig case is not run; its <name>.runtimeconfig.json is the result instead, so a case can
# build for a .NET version this machine does not have.
# A @gencs case is also compiled by Haxe 4.3.7's gencs (-D no-compilation, built for net10.0 with
# gencs.csproj.in); a run whose output differs from the hxc run adds a [gencs] section to the result,
# and a case whose expectation has no [run] section takes the gencs output as that expectation.
# @gencs compares runs, so it cannot go with @lib.
# Case directories go under $HXC_TEST_TMP, by default tests/dotnet/tmp (gitignored), so one
# antivirus exclusion covers the assemblies they write.
set -u

here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/../.." && pwd)"
compiler=""
std=""
only=""
haxe="haxe"
while [ $# -gt 0 ]; do
	case "$1" in
		--compiler) compiler="$2"; shift 2 ;;
		--std) std="$2"; shift 2 ;;
		--case) only="$2"; shift 2 ;;
		--haxe) haxe="$2"; shift 2 ;;
		*) echo "unknown argument: $1" >&2; exit 2 ;;
	esac
done
if [ -z "$compiler" ]; then
	echo "usage: $0 --compiler <hxc> [--std <dir>] [--case <name>] [--haxe <haxe>]" >&2
	exit 2
fi
compiler="$(cd "$(dirname "$compiler")" && pwd)/$(basename "$compiler")"
if [ -n "$std" ]; then export HAXE_STD_PATH="$std"; fi
tmproot="${HXC_TEST_TMP:-$here/tmp}"
mkdir -p "$tmproot" || exit 1
tmproot="$(cd "$tmproot" && pwd)"

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
	local s="$1" dir="${2:-$casedir}" d
	s="${s//$'\r'/}"
	for d in "$dir" "$(native "$dir")" "$(cygpath -w "$dir" 2>/dev/null)"; do
		[ -n "$d" ] && s="${s//"$d"/\$CASE}"
	done
	printf '%s\n' "$s" | sed -e 's/[[:space:]]*$//'
}

failed=0
total=0

# The module's source file, relative to a case directory.
source_file() {
	if [ "$1" = "P" ]; then echo "P.hx"; else echo "$(printf '%s' "$1" | tr . /).hx"; fi
}

# Builds and runs every @gencs case in one go: generates the C# in parallel, builds all the projects
# with one batch MSBuild project, runs each. For a case it leaves $gencsroot/<name>/out (the run's
# output) or $gencsroot/<name>/problem.
gencsroot=""
gencs_prepare() {
	local i t module has
	local -a todo=()
	for i in "${!c_name[@]}"; do
		has=0
		for t in ${c_tags[$i]}; do [ "$t" = "@gencs" ] && has=1; done
		for t in ${c_tags[$i]}; do [ "$t" = "@lib" ] && has=0; done
		[ $has = 1 ] && todo+=("$i")
	done
	[ ${#todo[@]} = 0 ] && return 0
	gencsroot="$(mktemp -d "$tmproot/gencs.XXXXXX")" || { echo "could not create a directory for the gencs cases" >&2; exit 1; }
	# The oracle must be Haxe 4.3.7 (with hxcs): every @gencs case fails otherwise.
	local hv wrong=""
	hv="$("$haxe" --version 2>&1 | tr -d '\r')"
	if [ "$hv" != "4.3.7" ]; then
		wrong="--haxe $haxe is Haxe '$hv', @gencs cases need Haxe 4.3.7 with hxcs"
		echo "$wrong" >&2
	fi
	for i in "${todo[@]}"; do
		local d="$gencsroot/${c_name[$i]}" file
		module="P"
		for t in ${c_tags[$i]}; do
			case "$t" in @module=*) module="${t#@module=}" ;; esac
		done
		file="$(source_file "$module")"
		mkdir -p "$d/$(dirname "$file")"
		printf '%s\n' "${c_source[$i]}" > "$d/$file"
		if [ -n "$wrong" ]; then printf '%s\n' "$wrong" > "$d/problem"; continue; fi
		while [ "$(jobs -rp | wc -l)" -ge 6 ]; do wait -n; done
		(
			set -f
			# --std is hxc's std; gencs gets the std that belongs to its own Haxe.
			unset HAXE_STD_PATH
			if glog="$("$haxe" --cwd "$(native "$d")" --haxelib-global -cp . -main "$module" --cs g -D no-compilation ${c_extra[$i]} 2>&1)"; then
				mainclass="$(sed -n '/^begin main/,/^end main/{/^begin main/d;/^end main/d;p;}' "$d/g/hxcs_build.txt" 2>/dev/null | tr -d '\r' | head -n 1)"
				if [ -z "$mainclass" ]; then
					printf 'gencs wrote no main class in hxcs_build.txt\n' > "$d/problem"
				else
					sed -e "s/@NAME@/${module##*.}/" -e "s/@MAIN@/$mainclass/" "$here/gencs.csproj.in" > "$d/g/${module##*.}.csproj"
				fi
			else
				printf 'gencs could not compile the case:\n%s\n' "$glog" > "$d/problem"
			fi
		) &
	done
	wait

	cat > "$gencsroot/batch.proj" <<'EOF'
<Project DefaultTargets="All">
  <ItemGroup><Case Include="*/g/*.csproj" /></ItemGroup>
  <Target Name="All">
    <MSBuild Projects="@(Case)" Targets="Restore" Properties="MSBuildRestoreSessionId=$([System.Guid]::NewGuid())" BuildInParallel="true" />
    <MSBuild Projects="@(Case)" Properties="Configuration=Release;OutDir=bin/" BuildInParallel="true" />
  </Target>
</Project>
EOF
	local blog
	# No node reuse: an idle MSBuild node left over from an earlier build once hung this one.
	blog="$(cd "$gencsroot" && MSBUILDDISABLENODEREUSE=1 dotnet build batch.proj -m -nologo -v q 2>&1)" || true

	for i in "${todo[@]}"; do
		local d="$gencsroot/${c_name[$i]}" dll code=0 out
		[ -f "$d/problem" ] && continue
		module="P"
		for t in ${c_tags[$i]}; do case "$t" in @module=*) module="${t#@module=}" ;; esac; done
		dll="g/bin/${module##*.}.dll"
		if [ ! -f "$d/$dll" ]; then
			printf 'gencs output did not build:\n%s\n' "$(printf '%s\n' "$blog" | grep -F "/${c_name[$i]}/" | sort -u | head -n 20)" > "$d/problem"
			continue
		fi
		out="$(cd "$d" && dotnet "$dll" 2>&1)" || code=$?
		[ $code != 0 ] && out="${out}"$'\n'"[exit $code]"
		printf '%s' "$out" > "$d/out"
	done
}

run_case() {
	local name="$1" tags="$2" extra="$3" source="$4" expected="$5"
	local lib=0 module="P" dump="" gencs=0 stress=0 config=0 t
	for t in $tags; do
		case "$t" in
			@lib) lib=1 ;;
			@module=*) module="${t#@module=}" ;;
			@dump=*) dump="${t#@dump=}" ;;
			@gencs) gencs=1 ;;
			@stress-fieldlookup) stress=1 ;;
			@runtimeconfig) config=1 ;;
			*) echo "$name: unknown tag $t" >&2; failed=$((failed + 1)); return ;;
		esac
	done
	total=$((total + 1))
	if [ $gencs = 1 ] && [ $lib = 1 ]; then
		echo "FAIL $name"
		echo "@gencs compares the runs of hxc's and gencs's output, and a @lib case does not run"
		failed=$((failed + 1))
		return
	fi
	casedir="$(mktemp -d "$tmproot/case.XXXXXX")"
	local file
	file="$(source_file "$module")"
	mkdir -p "$casedir/$(dirname "$file")"
	printf '%s\n' "$source" > "$casedir/$file"

	local main=(--main "$module")
	if [ $lib = 1 ]; then main=("$module"); fi
	# --cs adds -lib hxcs, and haxelib would find the checkout's own .haxelib above the case directory;
	# --haxelib-global, which only counts after the library, keeps the global hxcs.
	set -f
	local cout
	cout="$("$compiler" --cwd "$(native "$casedir")" -cp . "${main[@]}" --cs a/P --haxelib-global -D dotnet $extra 2>&1)"
	"$compiler" --cwd "$(native "$casedir")" -cp . "${main[@]}" --cs b/P --haxelib-global -D dotnet $extra > /dev/null 2>&1
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
		if [ $config = 1 ]; then
			result="${result:+$result$'\n'}[runtimeconfig]"$'\n'"$(cat "$casedir"/a/P/*.runtimeconfig.json 2>&1)"
		elif [ $lib = 0 ]; then
			local rout code=0
			rout="$(cd "$casedir" && dotnet "a/P/$(basename "$dll")" 2>&1)" || code=$?
			[ $code != 0 ] && rout="${rout}"$'\n'"[exit $code]"
			[ -n "$rout" ] && result="${result:+$result$'\n'}[run]"$'\n'"$rout"
			if [ $gencs = 1 ] && [ -f "$gencsroot/$name/out" ]; then
				local gdir="$gencsroot/$name" gout
				gout="$(normalize "$(cat "$gdir/out")" "$gdir")"
				if [ "$gout" != "$(normalize "$rout")" ]; then
					result="${result:+$result$'\n'}[gencs]"$'\n'"$gout"
				elif ! printf '%s\n' "$expected" | grep -qx '\[run\]'; then
					# No [run] expectation: gencs's output is it.
					[ -n "$gout" ] && expected="${expected}[run]"$'\n'"$gout"$'\n'
				fi
			fi
		fi
		if [ $stress = 1 ]; then
			local sout
			if ! sout="$(check stress-fieldlookup "$(native "$dll")" 2>&1)"; then problem="${problem}stress-fieldlookup failed:"$'\n'"${sout}"$'\n'; fi
		fi
		if [ -n "$dump" ]; then
			local dout
			dout="$(check dump "$(native "$dll")" "$dump" 2>&1)"
			[ -n "$dout" ] && result="${result:+$result$'\n'}[dump]"$'\n'"$dout"
		fi
	fi

	if [ $gencs = 1 ] && [ -f "$gencsroot/$name/problem" ]; then problem="${problem}$(cat "$gencsroot/$name/problem")"$'\n'; fi
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
c_name=(); c_tags=(); c_extra=(); c_source=(); c_expected=()
flush() {
	if [ -n "$name" ] && { [ -z "$only" ] || [ "$only" = "$name" ]; }; then
		c_name+=("$name"); c_tags+=("$tags"); c_extra+=("$extra"); c_source+=("$source"); c_expected+=("$expected")
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

gencs_prepare
for i in "${!c_name[@]}"; do
	run_case "${c_name[$i]}" "${c_tags[$i]}" "${c_extra[$i]}" "${c_source[$i]}" "${c_expected[$i]}"
done
[ -n "$gencsroot" ] && rm -rf "$gencsroot"

if [ $total = 0 ]; then
	echo "no case matched" >&2
	exit 1
fi
if [ $failed != 0 ]; then
	echo "$failed of $total cases failed"
	exit 1
fi
echo "all $total cases passed"

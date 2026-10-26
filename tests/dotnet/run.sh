#!/usr/bin/env bash
# Runs the .NET generator's cases in cases.hx.txt.
#   tests/dotnet/run.sh --compiler <hxc> [--std <dir>] [--case <name>] [--haxe <haxe>] [-j <jobs>]
#                       [--no-gencs-cache]
# A case is `--- name [@lib] [@module=pack.Mod] [@dump=items] [@gencs] [@serial] [@stress-fieldlookup]
# [@runtimeconfig] [@run-timeout=seconds] [+ extra hxc args]`, its source, `===`, and the expected
# result. Each case compiles twice into a fresh directory, and its .dll must be byte-identical
# between the two, pass ILVerify, run (unless @lib) and dump as expected. A @stress-fieldlookup
# case's .dll must also pass HxcCheck's stress-fieldlookup (haxe.lang.FieldLookup called from many
# threads at once). A @runtimeconfig case is not run; its <name>.runtimeconfig.json is the result
# instead, so a case can build for a .NET version this machine does not have.
# A @gencs case is also compiled by Haxe 4.3.7's gencs (-D no-compilation, built for net10.0 with
# gencs.csproj.in); a run whose output differs from the hxc run adds a [gencs] section to the result,
# and a case whose expectation has no [run] section takes the gencs output as that expectation.
# @gencs compares runs, so it cannot go with @lib or @runtimeconfig (nor can @serial). A @gencs case
# is expected to compile: unless its expectation has a [compile] section, hxc failing or writing no
# .dll fails the case.
# A @serial case is a @gencs case whose program takes `gen <file>` and `rt <in> <file>`: gen writes
# `name<TAB>serialized` lines to <file> and prints them, rt unserializes each line of <in>, serializes
# it again, writes the lines to <file> and prints them. Both builds run gen (the [run] comparison
# above); gencs's rt of its own file is the reference, shown under [rt]. hxc's rt of gencs's file,
# gencs's rt of hxc's file and hxc's rt of its own file must print the same, or the result gets an
# [rt hxc<-gencs], [rt gencs<-hxc] or [rt hxc<-hxc] section. With no [rt] in the expectation,
# gencs's is the expectation, as for [run]. A gencs gen that prints nothing or writes an empty file
# fails the case, since every comparison would then pass with nothing in it.
# Every run of a test program (hxc's or gencs's build) stops after $HXC_RUN_TIMEOUT seconds, 120 by
# default, or after @run-timeout's seconds for that case; its output then ends with
# `[timeout after Ns]` (a gencs run that times out fails the case), and the other cases go on.
# Compiles and builds have no such limit.
# Case directories go under $HXC_TEST_TMP, by default tests/dotnet/tmp (gitignored), so one
# antivirus exclusion covers the assemblies they write.
# Cases run -j at a time (default $HXC_TEST_JOBS, or 8), each in its own directory. Their reports
# print in case order as they become available, and the totals add up each case's own result. The
# cases whose results depend on timing, @stress-* and @run-timeout ones, run alone after the rest, so
# the reports from the first of them on wait for that. -j 1 runs every case in order, one at a time,
# as the script always did. gencs's builds run -j at a time too (the timing-dependent cases' alone,
# after the rest), and gencs generates C# at least 6 at a time. If $HXC_TEST_TIMES names a file, each
# case appends `<seconds> <name>` to it.
# gencs's results for a case are cached in $HXC_TEST_TMP/gencs-cache: its run's output or its
# problem, and for a @serial case also its rt output, gen.txt and its build, which hxc's builds read
# and run. The key covers the case (name, tags, extra args, source and run time limit),
# gencs.csproj.in, this script's gencs steps, the Haxe version, path and std files, the global hxcs
# (haxelib's path for it, its haxelib.json, git HEAD and files), the .NET SDK version and the time
# zone, so only a case whose gencs results could differ goes through gencs again. Problems from
# gencs's build or a timed-out run are not cached, and nothing is when the Haxe version is wrong.
# --no-gencs-cache neither reads nor writes the cache; entries unused for 30 days are removed.
# Bash's forks are slow on Windows, so the steps for each case avoid subshells where they can.
set -u

# Sets $dir to directory $1's absolute path, as $(cd "$1" && pwd) prints it, without a subshell.
absdir() {
	local back="$PWD"
	dir=""
	CDPATH= cd "${1:-/}" || return 1
	dir="$PWD"
	cd "$back" || exit 1
}
case "$0" in */*) absdir "${0%/*}" ;; *) absdir . ;; esac
here="$dir"
absdir "$here/../.."
root="$dir"
compiler=""
std=""
only=""
haxe="haxe"
njobs="${HXC_TEST_JOBS:-8}"
usecache=1
usage="usage: $0 --compiler <hxc> [--std <dir>] [--case <name>] [--haxe <haxe>] [-j <jobs>] [--no-gencs-cache]"
while [ $# -gt 0 ]; do
	case "$1" in
		--compiler) compiler="$2"; shift 2 ;;
		--std) std="$2"; shift 2 ;;
		--case) only="$2"; shift 2 ;;
		--haxe) haxe="$2"; shift 2 ;;
		-j | --jobs) njobs="$2"; shift 2 ;;
		-j*) njobs="${1#-j}"; shift ;;
		--no-gencs-cache) usecache=0; shift ;;
		*) echo "unknown argument: $1" >&2; exit 2 ;;
	esac
done
if [ -z "$compiler" ]; then
	echo "$usage" >&2
	exit 2
fi
case "$njobs" in
	"" | *[!0-9]* | 0*) echo "-j needs a positive number of jobs, not '$njobs'" >&2; exit 2 ;;
esac
case "$compiler" in */*) absdir "${compiler%/*}" ;; *) absdir . ;; esac
compiler="$dir/${compiler##*/}"
if [ -n "$std" ]; then export HAXE_STD_PATH="$std"; fi
tmproot="${HXC_TEST_TMP:-$here/tmp}"
mkdir -p "$tmproot" || exit 1
absdir "$tmproot"
tmproot="$dir"

checkdir="$root/tests/fixtures/hxccheck"
checkdll="$checkdir/bin/out/HxcCheck.dll"
# Each case writes its report to $resdir/<i>.out and <i>.err, then `<cases> <failures> <seconds>` to
# $resdir/<i>.res, and has its directory in $resdir.
resdir="$(mktemp -d "$tmproot/results.XXXXXX")" || { echo "could not create a directory for the results" >&2; exit 1; }
trap 'rm -rf "$resdir"' EXIT

runlimit="${HXC_RUN_TIMEOUT:-120}"
# A case's run time limit: @run-timeout's, or $runlimit. Sets $limit.
case_limit() {
	local t
	limit="$runlimit"
	for t in $1; do case "$t" in @run-timeout=*) limit="${t#@run-timeout=}" ;; esac; done
}
# Runs a test program, `dotnet <dll> [args]` in directory $1, for at most $2 seconds and sets $ran to
# its output; `[exit N]` follows if it fails, `[timeout after Ns]` if it runs out of time.
run_program() {
	local dir="$1" lim="$2" code=0
	shift 2
	ran="$(cd "$dir" && exec timeout -k 10 "$lim" dotnet "$@" 2>&1)" || code=$?
	case $code in
		0) ;;
		124 | 137) ran="${ran}"$'\n'"[timeout after ${lim}s]" ;;
		*) ran="${ran}"$'\n'"[exit $code]" ;;
	esac
}

# A native Windows path for a directory, when cygpath exists.
native() { cygpath -m "$1" 2>/dev/null || printf '%s' "$1"; }
# Sets $path_m to path $1's native form and $path_w to its Windows form (empty without cygpath). A
# path under $tmproot reuses $tmproot's forms, so only paths elsewhere go through cygpath.
tmproot_m="$(native "$tmproot")"
tmproot_w="$(cygpath -w "$tmproot" 2>/dev/null)"
paths() {
	local rest
	case "$1" in
		"$tmproot" | "$tmproot"/*)
			rest="${1#"$tmproot"}"
			path_m="$tmproot_m$rest"
			path_w=""
			[ -n "$tmproot_w" ] && path_w="$tmproot_w${rest//\//\\}"
			;;
		*)
			path_m="$(native "$1")"
			path_w="$(cygpath -w "$1" 2>/dev/null)"
			;;
	esac
}

# Sets $norm to $1 with line endings as \n, directory $2 (by default the case directory) as $CASE,
# no trailing whitespace on any line and no trailing blank lines. sed only runs when a line has
# trailing whitespace, or the text has a byte sed's locale may read differently.
normalize() {
	local s="$1" d ws=$' \t\v\f'
	paths "${2:-$casedir}"
	s="${s//$'\r'/}"
	for d in "${2:-$casedir}" "$path_m" "$path_w"; do
		[ -n "$d" ] && s="${s//"$d"/\$CASE}"
	done
	if [[ $s == *[![:ascii:]]* || $s$'\n' == *[$ws]$'\n'* ]]; then
		s="$(printf '%s\n' "$s" | sed -e 's/[[:space:]]*$//')"
	else
		s="${s%"${s##*[!$'\n']}"}"
	fi
	norm="$s"
}

# Sets $text to file $1's content without trailing newlines, as $(cat "$1") would. For files this
# script wrote from shell strings, which hold no NUL.
slurp() {
	text=""
	IFS= read -r -d '' text < "$1"
	text="${text%"${text##*[!$'\n']}"}"
}

# Whether text $1 has a line that is exactly $2.
has_line() {
	[[ $'\n'"$1"$'\n' == *$'\n'"$2"$'\n'* ]]
}

failed=0
total=0

# The module's source file, relative to a case directory: sets $file.
source_file() {
	if [ "$1" = "P" ]; then file="P.hx"; else file="$(printf '%s' "$1" | tr . /).hx"; fi
}

# Whether tags $1 make a case's result depend on timing, so that it runs alone.
timing_case() {
	local t
	for t in $1; do case "$t" in @stress-* | @run-timeout=*) return 0 ;; esac; done
	return 1
}

# Background jobs: start_job counts one more, reap_job waits for one to finish, throttle waits
# until fewer than $1 run.
running=0
start_job() { running=$((running + 1)); }
reap_job() {
	wait -n
	if [ $? = 127 ]; then running=0; else running=$((running - 1)); fi
}
throttle() {
	while [ $running -ge "$1" ]; do reap_job; done
}
reap_all() {
	wait
	running=0
}

# Generates the C# for case $1 (module $3) in $2 with gencs and fills in its project, or writes
# $2/problem. Runs in a subshell.
gencs_generate() {
	local i="$1" d="$2" module="$3" glog mainclass
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
}

# Runs gencs's build of case $1 (module $3, @serial if $4 is 1) in $2: leaves $2/out (and $2/rt.out
# for @serial) or $2/problem. $blog is the batch build's log.
gencs_run() {
	local i="$1" d="$2" module="$3" serial="$4" dll out limit args=() rtout=""
	case_limit "${c_tags[$i]}"
	dll="g/bin/${module##*.}.dll"
	if [ ! -f "$d/$dll" ]; then
		printf 'gencs output did not build:\n%s\n' "$(printf '%s\n' "$blog" | grep -F "/${c_name[$i]}/" | sort -u | head -n 20)" > "$d/problem"
		return
	fi
	# A @serial case: gen writes gen.txt, then rt of gen.txt (gencs reading itself) is the reference.
	[ $serial = 1 ] && args=(gen gen.txt)
	run_program "$d" "$limit" "$dll" "${args[@]}"
	out="$ran"
	if [ $serial = 1 ]; then
		run_program "$d" "$limit" "$dll" rt gen.txt rt.txt
		rtout="$ran"
	fi
	case "$out$rtout" in
		*"[timeout after ${limit}s]"*)
			printf "gencs's build ran out of time; the end of its output:\n%s\n" "$(printf '%s\n%s\n' "$out" "$rtout" | tail -n 5)" > "$d/problem"
			return
			;;
	esac
	if [ $serial = 1 ] && { [ -z "$out" ] || [ ! -s "$d/gen.txt" ]; }; then
		printf "gencs's gen printed nothing or wrote no gen.txt, which leaves nothing to compare\n" > "$d/problem"
		return
	fi
	printf '%s' "$out" > "$d/out"
	if [ $serial = 1 ]; then printf '%s' "$rtout" > "$d/rt.out"; fi
}

gencs_batch='<Project DefaultTargets="All">
  <ItemGroup><Case Include="*/g/*.csproj" /></ItemGroup>
  <Target Name="All">
    <MSBuild Projects="@(Case)" Targets="Restore" Properties="MSBuildRestoreSessionId=$([System.Guid]::NewGuid())" BuildInParallel="true" />
    <MSBuild Projects="@(Case)" Properties="Configuration=Release;OutDir=bin/" BuildInParallel="true" />
  </Target>
</Project>'

# What gencs's results depend on besides the case itself, hashed into every key.
gencs_fingerprint() {
	local exe hxcs="" line f
	printf 'gencs-cache 1\n%s\n' "$hv"
	exe="$(command -v "$haxe")"
	printf '%s\n' "$exe"
	# Its own std (HAXE_STD_PATH is unset for gencs): the files' sizes and times, in find's order (a
	# new order only misses the cache).
	case "$exe" in */*) find "${exe%/*}/std" -type f -printf '%P %s %T@\n' 2>&1 ;; esac
	# The global hxcs, found as --haxelib-global finds it (away from the checkout's .haxelib).
	while IFS= read -r line; do
		line="${line%$'\r'}"
		printf '%s\n' "$line"
		[ -z "$hxcs" ] && [ "${line#-}" = "$line" ] && hxcs="$line"
	done < <(cd / && exec haxelib --global path hxcs 2>&1)
	hxcs="${hxcs%/}"
	if [ -n "$hxcs" ] && [ -d "$hxcs" ]; then
		for f in haxelib.json .git/HEAD .git/packed-refs; do
			[ -f "$hxcs/$f" ] && read_exact "$hxcs/$f" && printf '%s\n' "$f" "$text"
		done
		if [ -f "$hxcs/.git/HEAD" ]; then
			read_exact "$hxcs/.git/HEAD"
			text="${text%%[$'\r\n']*}"
			case "$text" in "ref: "*) [ -f "$hxcs/.git/${text#ref: }" ] && read_exact "$hxcs/.git/${text#ref: }" && printf '%s\n' "$text" ;; esac
		fi
		find "$hxcs" -path "$hxcs/.git" -prune -o -type f -printf '%P %s %T@\n'
	fi
	read_exact "$here/gencs.csproj.in"
	printf '%s\n' "$text"
	declare -f gencs_generate gencs_run run_program case_limit native source_file
	printf '%s\n' "$gencs_batch"
	dotnet --version 2>&1
	printf '%(%z %Z)T\n' -1
}

# Sets $text to file $1's exact content (no NUL), trailing newlines included.
read_exact() {
	text=""
	IFS= read -r -d '' text < "$1"
	return 0
}

# Copies cache entry $1's text results into case directory $2, with the directory they were made in
# replaced by $2. Copies of builds (and gen.txt) are left to the caller.
gencs_restore() {
	local src="$gencs_cache/$1" d="$2" f old_p old_m old_w new_m new_w
	{ IFS= read -r old_p; IFS= read -r old_m; IFS= read -r old_w; } < "$src/origin"
	paths "$d"
	new_m="$path_m"
	new_w="$path_w"
	for f in out rt.out problem; do
		[ -f "$src/$f" ] || continue
		read_exact "$src/$f"
		[ -n "$old_p" ] && text="${text//"$old_p"/"$d"}"
		[ -n "$old_m" ] && text="${text//"$old_m"/"$new_m"}"
		[ -n "$old_w" ] && text="${text//"$old_w"/"$new_w"}"
		printf '%s' "$text" > "$d/$f"
	done
}

# Builds and runs every @gencs case in one go: generates the C# in parallel, builds all the projects
# with one batch MSBuild project, runs each. For a case it leaves $gencsroot/<name>/out (the run's
# output) or $gencsroot/<name>/problem. Cases found in the cache skip all three.
gencsroot=""
gencs_cache=""
gencs_prepare() {
	local i t module has file
	local -a todo=() dirs=() run=() key=() hits=() copies=() genproblem=()
	for i in "${!c_name[@]}"; do
		has=0
		for t in ${c_tags[$i]}; do [ "$t" = "@gencs" ] || [ "$t" = "@serial" ] && has=1; done
		for t in ${c_tags[$i]}; do [ "$t" = "@lib" ] || [ "$t" = "@runtimeconfig" ] && has=0; done
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
	# Every case's source goes in place first, with one mkdir.
	for i in "${todo[@]}"; do
		module="P"
		for t in ${c_tags[$i]}; do
			case "$t" in @module=*) module="${t#@module=}" ;; esac
		done
		source_file "$module"
		c_gfile[$i]="$file"
		c_gmodule[$i]="$module"
		case "$file" in */*) dirs+=("$gencsroot/${c_name[$i]}/${file%/*}") ;; *) dirs+=("$gencsroot/${c_name[$i]}") ;; esac
	done
	mkdir -p "${dirs[@]}"
	for i in "${todo[@]}"; do
		printf '%s\n' "${c_source[$i]}" > "$gencsroot/${c_name[$i]}/${c_gfile[$i]}"
	done
	if [ $usecache = 1 ] && [ -z "$wrong" ] && mkdir -p "$tmproot/gencs-cache"; then
		gencs_cache="$tmproot/gencs-cache"
		# A key hashes the fingerprint's hash and the case's fields, each with its length; one sha1sum
		# hashes them all.
		local fp f n=0 h rest limit
		fp="$(gencs_fingerprint | sha1sum)"
		fp="${fp%% *}"
		mkdir -p "$gencsroot/.keys"
		for i in "${todo[@]}"; do
			case_limit "${c_tags[$i]}"
			{
				printf '%s\n' "$fp"
				for f in "${c_name[$i]}" "${c_tags[$i]}" "${c_extra[$i]}" "${c_source[$i]}" "$limit"; do
					printf '%d:%s\n' "${#f}" "$f"
				done
			} > "$gencsroot/.keys/$i"
		done
		while read -r h rest; do
			key[${todo[$n]}]="${h#\\}"
			n=$((n + 1))
		done < <(cd "$gencsroot/.keys" && sha1sum "${todo[@]}")
	fi
	local genjobs=$((njobs > 6 ? njobs : 6))
	for i in "${todo[@]}"; do
		local d="$gencsroot/${c_name[$i]}"
		if [ -n "$wrong" ]; then printf '%s\n' "$wrong" > "$d/problem"; continue; fi
		if [ -n "$gencs_cache" ] && [ -f "$gencs_cache/${key[$i]}/origin" ]; then
			gencs_restore "${key[$i]}" "$d"
			hits+=("$gencs_cache/${key[$i]}")
			[ -d "$gencs_cache/${key[$i]}/g" ] && copies+=("$i")
			continue
		fi
		run+=("$i")
		throttle $genjobs
		(gencs_generate "$i" "$d" "${c_gmodule[$i]}") &
		start_job
	done
	reap_all
	# A cached @serial case's build and gen.txt, and the times that keep hits from being pruned.
	for i in "${copies[@]}"; do
		cp -R "$gencs_cache/${key[$i]}/g" "$gencs_cache/${key[$i]}/gen.txt" "$gencsroot/${c_name[$i]}/"
	done
	[ ${#hits[@]} = 0 ] || touch "${hits[@]}"
	for i in "${run[@]}"; do [ -f "$gencsroot/${c_name[$i]}/problem" ] && genproblem[$i]=1; done

	printf '%s\n' "$gencs_batch" > "$gencsroot/batch.proj"
	blog=""
	# No node reuse: an idle MSBuild node left over from an earlier build once hung this one. With
	# every case cached there is nothing to build.
	if [ -z "$gencs_cache" ] || compgen -G "$gencsroot/*/g/*.csproj" > /dev/null; then
		blog="$(cd "$gencsroot" && MSBUILDDISABLENODEREUSE=1 dotnet build batch.proj -m -nologo -v q 2>&1)" || true
	fi

	# With -j above 1, the timing-dependent cases' builds run alone, after the rest.
	local pass serial alone
	for pass in 0 1; do
		for i in "${run[@]}"; do
			local d="$gencsroot/${c_name[$i]}"
			[ -f "$d/problem" ] && continue
			alone=0
			[ $njobs != 1 ] && timing_case "${c_tags[$i]}" && alone=1
			[ $pass = $alone ] || continue
			serial=0
			for t in ${c_tags[$i]}; do [ "$t" = "@serial" ] && serial=1; done
			if [ $njobs = 1 ] || [ $alone = 1 ]; then
				gencs_run "$i" "$d" "${c_gmodule[$i]}" $serial
			else
				throttle $njobs
				gencs_run "$i" "$d" "${c_gmodule[$i]}" $serial &
				start_job
			fi
		done
		reap_all
	done

	# Only what does not depend on the machine's load goes in the cache: a run's output, or a problem
	# found while generating the C#. The new entries are written under .new.<pid> and then moved into
	# place by one mv; an entry another run stored meanwhile stays as it is.
	if [ -n "$gencs_cache" ] && [ ${#run[@]} != 0 ]; then
		local new="$gencs_cache/.new.$$" store=() builds=()
		for i in "${run[@]}"; do
			local d="$gencsroot/${c_name[$i]}"
			if [ -f "$d/out" ] || [ "${genproblem[$i]:-0}" = 1 ]; then store+=("$i"); fi
		done
		if [ ${#store[@]} != 0 ]; then
			rm -rf "$new"
			dirs=()
			for i in "${store[@]}"; do dirs+=("$new/${key[$i]}"); done
			mkdir -p "${dirs[@]}"
			for i in "${store[@]}"; do
				local d="$gencsroot/${c_name[$i]}" e="$new/${key[$i]}"
				paths "$d"
				printf '%s\n%s\n%s\n' "$d" "$path_m" "$path_w" > "$e/origin"
				for f in out rt.out problem; do
					if [ -f "$d/$f" ]; then read_exact "$d/$f"; printf '%s' "$text" > "$e/$f"; fi
				done
				[ -f "$d/rt.out" ] && builds+=("$i")
			done
			for i in "${builds[@]}"; do
				local d="$gencsroot/${c_name[$i]}" e="$new/${key[$i]}"
				mkdir -p "$e/g" && cp -R "$d/g/bin" "$e/g/bin" && cp "$d/gen.txt" "$e/gen.txt" || rm -rf "$e"
			done
			mv -t "$gencs_cache" "$new"/* 2> /dev/null
			rm -rf "$new"
		fi
	fi
	[ -n "$gencs_cache" ] && find "$gencs_cache" -mindepth 1 -maxdepth 1 -mtime +30 -exec rm -rf {} + 2> /dev/null
}

# Runs case $1 (tags $2, extra args $3, source $4, expected result $5) in directory $6, which must
# not exist yet, and prints its report.
run_case() {
	local name="$1" tags="$2" extra="$3" source="$4" expected="$5"
	local lib=0 module="P" dump="" gencs=0 serial=0 stress=0 config=0 limit t
	for t in $tags; do
		case "$t" in
			@lib) lib=1 ;;
			@module=*) module="${t#@module=}" ;;
			@dump=*) dump="${t#@dump=}" ;;
			@gencs) gencs=1 ;;
			@serial) serial=1; gencs=1 ;;
			@run-timeout=*) ;;
			@stress-fieldlookup) stress=1 ;;
			@runtimeconfig) config=1 ;;
			*) echo "$name: unknown tag $t" >&2; failed=$((failed + 1)); return ;;
		esac
	done
	case_limit "$tags"
	total=$((total + 1))
	if [ $gencs = 1 ] && [ $lib = 1 ]; then
		echo "FAIL $name"
		echo "@gencs compares the runs of hxc's and gencs's output, and a @lib case does not run"
		failed=$((failed + 1))
		return
	fi
	if [ $gencs = 1 ] && [ $config = 1 ]; then
		echo "FAIL $name"
		echo "@gencs compares the runs of hxc's and gencs's output, and a @runtimeconfig case does not run"
		failed=$((failed + 1))
		return
	fi
	casedir="$6"
	local file casedir_m
	source_file "$module"
	case "$file" in */*) mkdir -p "$casedir/${file%/*}" ;; *) mkdir "$casedir" ;; esac
	printf '%s\n' "$source" > "$casedir/$file"
	paths "$casedir"
	casedir_m="$path_m"

	local main=(--main "$module")
	if [ $lib = 1 ]; then main=("$module"); fi
	# --cs adds -lib hxcs, and haxelib would find the checkout's own .haxelib above the case directory;
	# --haxelib-global, which only counts after the library, keeps the global hxcs.
	set -f
	local cout ccode=0
	cout="$("$compiler" --cwd "$casedir_m" -cp . "${main[@]}" --cs a/P --haxelib-global -D dotnet $extra 2>&1)" || ccode=$?
	"$compiler" --cwd "$casedir_m" -cp . "${main[@]}" --cs b/P --haxelib-global -D dotnet $extra > /dev/null 2>&1
	set +f

	local result="" problem="" dll="" dll_m f
	[ -n "$cout" ] && result="[compile]"$'\n'"$cout"
	for f in "$casedir"/a/P/*.dll; do [ -f "$f" ] && dll="$f" && break; done
	# A @gencs case that is not expected to fail compiling must give an assembly to compare.
	if [ $gencs = 1 ] && ! has_line "$expected" "[compile]"; then
		if [ $ccode != 0 ]; then
			problem="${problem}hxc failed (exit $ccode)"$'\n'
		elif [ -z "$dll" ]; then
			problem="${problem}hxc wrote no .dll"$'\n'
		fi
	fi
	if [ -n "$dll" ]; then
		paths "$dll"
		dll_m="$path_m"
		for f in "$casedir"/a/P/*; do
			if ! cmp -s "$f" "$casedir/b/P/${f##*/}"; then
				problem="${problem}not deterministic: ${f##*/}"$'\n'
			fi
		done
		local vout
		if ! vout="$(exec dotnet "$checkdll" verify "$dll_m" 2>&1)"; then problem="${problem}${vout}"$'\n'; fi
		if [ $config = 1 ]; then
			result="${result:+$result$'\n'}[runtimeconfig]"$'\n'"$(cat "$casedir"/a/P/*.runtimeconfig.json 2>&1)"
		elif [ $lib = 0 ]; then
			local rout hdll="a/P/${dll##*/}" args=()
			[ $serial = 1 ] && args=(gen h.gen.txt)
			run_program "$casedir" "$limit" "$hdll" "${args[@]}"
			rout="$ran"
			[ -n "$rout" ] && result="${result:+$result$'\n'}[run]"$'\n'"$rout"
			if [ $gencs = 1 ] && [ -f "$gencsroot/$name/out" ]; then
				local gdir="$gencsroot/$name" gout
				slurp "$gdir/out"
				normalize "$text" "$gdir"
				gout="$norm"
				normalize "$rout"
				if [ "$gout" != "$norm" ]; then
					result="${result:+$result$'\n'}[gencs]"$'\n'"$gout"
				elif ! has_line "$expected" "[run]"; then
					# No [run] expectation: gencs's output is it.
					[ -n "$gout" ] && expected="${expected}[run]"$'\n'"$gout"$'\n'
				fi
			fi
			if [ $serial = 1 ] && [ -f "$gencsroot/$name/rt.out" ]; then
				# gencs reading its own data is the reference; every other reader must print the same.
				local gdir="$gencsroot/$name" ref section out
				slurp "$gdir/rt.out"
				normalize "$text" "$gdir"
				ref="$norm"
				result="${result:+$result$'\n'}[rt]"$'\n'"$ref"
				for section in "hxc<-gencs" "gencs<-hxc" "hxc<-hxc"; do
					case "$section" in
						"hxc<-gencs") paths "$gdir/gen.txt"; run_program "$casedir" "$limit" "$hdll" rt "$path_m" h.rt.g.txt ;;
						"gencs<-hxc") paths "$casedir/h.gen.txt"; run_program "$gdir" "$limit" "g/bin/${module##*.}.dll" rt "$path_m" g.rt.h.txt ;;
						"hxc<-hxc") run_program "$casedir" "$limit" "$hdll" rt h.gen.txt h.rt.h.txt ;;
					esac
					normalize "$ran"
					out="$norm"
					[ "$out" != "$ref" ] && result="$result"$'\n'"[rt $section]"$'\n'"$out"
				done
				if ! has_line "$expected" "[rt]"; then
					# No [rt] expectation: gencs's is it.
					expected="${expected}[rt]"$'\n'"$ref"$'\n'
				fi
			fi
		fi
		if [ $stress = 1 ]; then
			local sout
			if ! sout="$(exec dotnet "$checkdll" stress-fieldlookup "$dll_m" 2>&1)"; then problem="${problem}stress-fieldlookup failed:"$'\n'"${sout}"$'\n'; fi
		fi
		if [ -n "$dump" ]; then
			local dout
			dout="$(exec dotnet "$checkdll" dump "$dll_m" "$dump" 2>&1)"
			[ -n "$dout" ] && result="${result:+$result$'\n'}[dump]"$'\n'"$dout"
		fi
	fi

	if [ $gencs = 1 ] && [ -f "$gencsroot/$name/problem" ]; then
		slurp "$gencsroot/$name/problem"
		problem="${problem}${text}"$'\n'
	fi
	local want got
	normalize "$expected"
	want="$norm"
	normalize "$result"
	got="$norm"
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
c_name=(); c_tags=(); c_extra=(); c_source=(); c_expected=(); c_gfile=(); c_gmodule=()
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

# HxcCheck builds while gencs's cases get ready; the cases wait for it.
(
	dotnet build "$checkdir" -c Release -o "$checkdir/bin/out" -nologo -v q > "$resdir/hxccheck.log" 2>&1
	echo $? > "$resdir/hxccheck.status"
) &
start_job
gencs_prepare
reap_all
code=1
[ -f "$resdir/hxccheck.status" ] && read -r code < "$resdir/hxccheck.status"
if [ "$code" != 0 ]; then
	slurp "$resdir/hxccheck.log"
	echo "$text"
	echo "could not build HxcCheck" >&2
	exit 1
fi

# Each case runs in a subshell; the reports print in case order.
start_case() {
	local i="$1"
	(
		exec > "$resdir/$i.out" 2> "$resdir/$i.err"
		total=0
		failed=0
		started=$SECONDS
		run_case "${c_name[$i]}" "${c_tags[$i]}" "${c_extra[$i]}" "${c_source[$i]}" "${c_expected[$i]}" "$resdir/c$i"
		# One write, after the report is complete.
		printf '%s %s %s\n' $total $failed $((SECONDS - started)) > "$resdir/$i.res"
	) &
	start_job
}
next=0
report_ready() {
	local t f s
	while [ $next -lt ${#c_name[@]} ] && [ -f "$resdir/$next.res" ]; do
		read -r t f s < "$resdir/$next.res"
		# Not written yet: its job is still running.
		[ -n "$s" ] || break
		[ -s "$resdir/$next.out" ] && cat "$resdir/$next.out"
		[ -s "$resdir/$next.err" ] && cat "$resdir/$next.err" >&2
		total=$((total + t))
		failed=$((failed + f))
		[ -n "${HXC_TEST_TIMES:-}" ] && printf '%s %s\n' "$s" "${c_name[$next]}" >> "$HXC_TEST_TIMES"
		next=$((next + 1))
	done
}
later=()
for i in "${!c_name[@]}"; do
	if [ $njobs != 1 ] && timing_case "${c_tags[$i]}"; then later+=("$i"); continue; fi
	while [ $running -ge "$njobs" ]; do reap_job; report_ready; done
	start_case "$i"
done
while [ $running -gt 0 ]; do reap_job; report_ready; done
reap_all
for i in "${later[@]}"; do
	start_case "$i"
	reap_all
	report_ready
done
report_ready
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

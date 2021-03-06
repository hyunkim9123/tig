#!/bin/sh
#
# Setup test environment.
#
# Copyright (c) 2014 Jonas Fonseca <jonas.fonseca@gmail.com>
#
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License as
# published by the Free Software Foundation; either version 2 of
# the License, or (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.

set -eu
if [ -n "${BASH_VERSION:-}" ]; then
	set -o pipefail
	IFS=$'\n\t'
fi

test="$(basename "$0")"
source_dir="$(cd "$(dirname "$0")" && pwd)"
base_dir="$(echo "$source_dir" | sed -n 's#\(.*/test\)\([/].*\)*#\1#p')"
prefix_dir="$(echo "$source_dir" | sed -n 's#\(.*/test/\)\([/].*\)*#\2#p')"
output_dir="$base_dir/tmp/$prefix_dir/$test"
tmp_dir="$base_dir/tmp"
output_dir="$tmp_dir/$prefix_dir/$test"
work_dir="work dir"

# The locale must specify UTF-8 for Ncurses to output correctly. Since C.UTF-8
# does not exist on Mac OS X, we end up with en_US as the only sane choice.
export LANG=en_US.UTF-8
export LC_ALL=en_US.UTF-8

export PAGER=cat
export TZ=UTC
export TERM=dumb
export HOME="$output_dir"
unset CDPATH
unset VISUAL

# Git env
export GIT_CONFIG_NOSYSTEM
unset GIT_CONFIG GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE
unset GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_AUTHOR_DATE
unset GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL GIT_COMMITTER_DATE
unset GIT_EDITOR GIT_SEQUENCE_EDITOR GIT_PAGER GIT_EXTERNAL_DIFF
unset GIT_NOTES_REF GIT_NOTES_DISPLAY_REF

# Tig env
export TIG_TRACE=
export TIGRC_SYSTEM=
unset TIGRC_USER

# Ncurses env
export ESCDELAY=200
export LINES=30
export COLUMNS=80

# Internal test env
# A comma-separated list of options. See docs in test/README.
export TEST_OPTS="${TEST_OPTS:-}"
# Used by tig_script to set the test "scope" used by test_tig.
export TEST_NAME=

[ -e "$output_dir" ] && rm -rf "$output_dir"
mkdir -p "$output_dir/$work_dir"

if [ ! -d "$tmp_dir/.git" ]; then
	# Create a dummy repository to avoid reading .git/config
	# settings from the tig repository.
	git init -q "$tmp_dir"
fi

mkdir -p "$tmp_dir/bin"

# Setup fake editor
fake_editor="$tmp_dir/bin/vim"
cat > "$fake_editor" <<EOF
#!/bin/sh

file="\$1"
lineno="\$(expr "\$1" : '+\([0-9]*\)')"
if [ -n "\$lineno" ]; then
	file="\$2"
fi

echo "\$@" >> "$HOME/editor.log"
sed -n -e "\${lineno}p" "\$file" >> "$HOME/editor.log"
EOF

chmod +x "$fake_editor"
export EDITOR="$(basename "$fake_editor")"
export PATH="$(dirname "$fake_editor"):$PATH"

cd "$output_dir"

#
# Utilities.
#

die()
{
	echo >&2 "$*"
	exit 1
}

file() {
	path="$1"; shift

	mkdir -p "$(dirname "$path")"
	if [ "$#" = 0 ]; then
		case "$path" in
			stdin|expected*) cat ;;
			*) sed 's/^[ ]//' ;;
		esac > "$path"
	else
		printf '%s' "$@" > "$path"
	fi
}

tig_script() {
	name="$1"; shift
	prefix="${name:+$name.}"

	export TIG_SCRIPT="$HOME/${prefix}steps"
	export TEST_NAME="$name"

	# Ensure that the steps finish by quitting
	printf '%s\n:quit\n' "$@" \
		| sed -e 's/^[ 	]*//' -e '/^$/d' \
		| sed "s|:save-display\s\+\(\S*\)|:save-display $HOME/\1|" \
		> "$TIG_SCRIPT"
}

steps() {
	tig_script "" "$@"
}

stdin() {
	file "stdin" "$@"
}

tigrc() {
	file "$HOME/.tigrc" "$@"
}

gitconfig() {
	file "$HOME/.gitconfig" "$@"
}

in_work_dir()
{
	(cd "$work_dir" && $@)
}

auto_detect_debugger() {
	for dbg in gdb lldb; do
		dbg="$(command -v "$dbg" 2>/dev/null || true)"
		if [ -n "$dbg" ]; then
			echo "$dbg"
			return
		fi
	done

	die "Failed to detect a supported debugger"
}

#
# Parse TEST_OPTS
#

expected_status_code=0
diff_color_arg=
[ -t 1 ] && diff_color_arg=--color

indent='            '
verbose=
debugger=
trace=

set -- $TIG_TEST_OPTS $TEST_OPTS

while [ $# -gt 0 ]; do
	arg="$1"; shift
	case "$arg" in
		verbose) verbose=yes ;;
		no-indent) indent= ;;
		debugger=*) debugger=$(expr "$arg" : 'debugger=\(.*\)') ;;
		debugger) debugger="$(auto_detect_debugger)" ;;
		trace) trace=yes ;;
	esac
done

#
# Test runners and assertion checking.
#

assert_equals()
{
	file="$1"; shift

	file "expected/$file" "$@"

	if [ -e "$file" ]; then
		git diff -w --no-index $diff_color_arg "expected/$file" "$file" > "$file.diff" || true
		if [ -s "$file.diff" ]; then
			echo "[FAIL] $file != expected/$file" >> .test-result
			cat "$file.diff" >> .test-result
		else
			echo "  [OK] $file assertion" >> .test-result
		fi
		rm -f "$file.diff"
	else
		echo "[FAIL] $file not found" >> .test-result
	fi
}

assert_not_exists()
{
	file="$1"; shift

	if [ -e "$file" ]; then
		echo "[FAIL] $file should not exist" >> .test-result
	else
		echo "  [OK] $file does not exist" >> .test-result
	fi
}

show_test_results()
{
	if [ -n "$trace" -a -n "$TIG_TRACE" -a -e "$TIG_TRACE" ]; then
		sed "s/^/$indent[trace] /" < "$TIG_TRACE"
	fi
	if [ ! -d "$HOME" ]; then
		echo "Skipped"
	elif [ ! -e .test-result ]; then
		[ -e stderr ] &&
			sed "s/^/[stderr] /" < stderr
		[ -e stderr.orig ] &&
			sed "s/^/[stderr] /" < stderr.orig
		echo "No test results found"
	elif grep FAIL -q < .test-result; then
		failed="$(grep FAIL < .test-result | wc -l)"
		count="$(sed -n '/\(FAIL\|OK\)/p' < .test-result | wc -l)"

		printf "Failed %d out of %d test(s)%s\n" $failed $count 

		# Show output from stderr if no output is expected
		if [ -e stderr ]; then
			[ -e expected/stderr ] ||
				sed "s/^/[stderr] /" < stderr
		fi

		[ -e .test-result ] &&
			cat .test-result
	elif [ "$verbose" ]; then
		count="$(sed -n '/\(OK\)/p' < .test-result | wc -l)"
		printf "Passed %d assertions\n" $count
	fi | sed "s/^/$indent| /"
}

trap 'show_test_results' EXIT

test_exec_work_dir()
{
	echo "=== $@ ===" >> "$HOME/test-exec.log"
	set +e
	in_work_dir "$@" 1>>"$HOME/test-exec.log" 2>>"$HOME/test-exec.log"
	set -e
}

test_setup()
{
	run_setup="$(type test_setup_work_dir 2>/dev/null | grep 'function' || true)"

	if [ -n "$run_setup" ]; then
		if test ! -e "$HOME/test-exec.log" || ! grep -q test_setup_work_dir "$HOME/test-exec.log"; then
			test_exec_work_dir test_setup_work_dir
		fi
	fi
}

test_tig()
{
	name="$TEST_NAME"
	prefix="${name:+$name.}"

	test_setup
	export TIG_NO_DISPLAY=
	if [ -n "$trace" ]; then
		export TIG_TRACE="$HOME/${prefix}tig-trace"
	fi
	touch "${prefix}stdin" "${prefix}stderr"
	if [ -n "$debugger" ]; then
		echo "*** Running tests in '$(pwd)/$work_dir'"
		if [ -s "$work_dir/${prefix}stdin" ]; then
			echo "*** - This test requires data to be injected via stdin."
			echo "***   The expected input file is: '../${prefix}stdin'"
		fi
		if [ "$#" -gt 0 ]; then
			echo "*** - This test expects the following arguments: $@"
		fi
		(cd "$work_dir" && $debugger tig "$@")
	else
		set +e
		if [ -s "${prefix}stdin" ]; then
			(cd "$work_dir" && tig "$@") < "${prefix}stdin" > "${prefix}stdout" 2> "${prefix}stderr.orig"
		else
			(cd "$work_dir" && tig "$@") > "${prefix}stdout" 2> "${prefix}stderr.orig"
		fi
		status_code="$?"
		if [ "$status_code" != "$expected_status_code" ]; then
			echo "[FAIL] unexpected status code: $status_code (should be $expected_status_code)" >> .test-result
		fi
		set -e
	fi
	# Normalize paths in stderr output
	if [ -e "${prefix}stderr.orig" ]; then
		sed "s#$output_dir#HOME#" < "${prefix}stderr.orig" > "${prefix}stderr"
		rm -f "${prefix}stderr.orig"
	fi
	if [ -n "$trace" ]; then
		export TIG_TRACE="$HOME/.tig-trace"
		if [ -n "$name" ]; then
			sed "s#^#[$name] #" < "$HOME/${prefix}tig-trace" >> "$HOME/.tig-trace"
		else
			mv "$HOME/${prefix}tig-trace" "$HOME/.tig-trace"
		fi
	fi
	if [ -n "$prefix" ]; then
		sed "s#^#[$name] #" < "${prefix}stderr" >> "stderr"
	fi
}

test_graph()
{
	test-graph $@ > stdout 2> stderr.orig
}

test_case()
{
	name="$1"; shift

	echo "$name" >> test-cases
	cat > "$name.expected"

	touch "$name-before.sh" "$name-after.sh" "$name.script" "$name-args"

	while [ "$#" -gt 0 ]; do
		arg="$1"; shift
		value="$(expr "$arg" : '--[^=]*=\(.*\)')"

		case "$arg" in
		--before=*) echo "$value" > "$name-before.sh" ;;
		--after=*)  echo "$value" > "$name-after.sh" ;;
		--script=*) echo "$value" > "$name.script" ;;
		--args=*)   echo "$value" > "$name-args" ;;
		--cwd=*)    echo "$value" > "$name-cwd" ;;
		*)	    die "Unknown test_case argument: $arg"
		esac
	done
}

run_test_cases()
{
	if [ ! -e test-cases ]; then
		return
	fi
	test_setup
	for name in $(cat test-cases); do
		tig_script "$name" "
			$(if [ -e "$name.script" ]; then cat "$name.script"; fi)
			:save-display $name.screen
		"
		if [ -e "$name-before.sh" ]; then
			test_exec_work_dir sh "$HOME/$name-before.sh" 
		fi
		old_work_dir="$work_dir"
		if [ -e "$name-cwd" ]; then
			work_dir="$work_dir/$(cat "$name-cwd")"
		fi
		test_tig $(if [ -e "$name-args" ]; then cat "$name-args"; fi)
		work_dir="$old_work_dir"
		if [ -e "$name-after.sh" ]; then
			test_exec_work_dir sh "$HOME/$name-after.sh" 
		fi

		assert_equals "$name.screen" < "$name.expected"
		assert_equals "$name.stderr" ''
	done
}

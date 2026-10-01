#!/usr/bin/env bash
# Run the agentmap.nvim test suite.
#
#   bash tests/run.sh [name-filter]
#
# Runs every tests/test_*.lua with `nvim --headless --clean -u tests/minimal_init.lua -l <file>`
# and every tests/test_*.sh with bash. Exit code 1 if any test fails, 0 otherwise.
#
# Environment:
#   AGENTMAP_TEST_NVIM  Neovim binary to use (highest priority).
#   NVIM                Also honored, but only when it is an executable file. Inside a Neovim
#                       :terminal, $NVIM is the parent's RPC socket; it is ignored in that case.
#
# Each test gets a fresh temporary HOME, XDG_* dirs, CLAUDE_CONFIG_DIR and AGENTMAP_DIR, so no test
# can read or write your real records, Claude Code settings or Neovim config.
#
# Portability: works without `timeout` (macOS) and without `sha256sum` by providing small shims;
# tests that need Python 3 (collector, hook registration) are reported as SKIP when python3 is missing.
set -u

here="$(cd "$(dirname "$0")" && pwd)"
filter="${1:-}"

case "$filter" in
  -h|--help)
    sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'
    exit 0 ;;
esac

# ---------------------------------------------------------------- Neovim
is_nvim() { # $1 = candidate path; true if it is an executable file that reports "NVIM v..."
  [ -n "$1" ] && [ -f "$1" ] && [ -x "$1" ] || return 1
  "$1" --version 2>/dev/null | head -n 1 | grep -q '^NVIM v'
}

find_nvim() {
  local c
  for c in "${AGENTMAP_TEST_NVIM:-}" "${NVIM:-}"; do
    if is_nvim "$c"; then printf '%s\n' "$c"; return 0; fi
  done
  # Every nvim on PATH, in order (a wrapper or shim may come first).
  local IFS=:
  local d
  for d in $PATH; do
    [ -n "$d" ] || continue
    if is_nvim "$d/nvim"; then printf '%s\n' "$d/nvim"; return 0; fi
  done
  for c in "$HOME/.local/bin/nvim" /opt/homebrew/bin/nvim /usr/local/bin/nvim /usr/bin/nvim /snap/bin/nvim; do
    if is_nvim "$c"; then printf '%s\n' "$c"; return 0; fi
  done
  return 1
}

if ! nvim_bin="$(find_nvim)"; then
  echo "ERROR: Neovim not found. Put nvim on PATH or set AGENTMAP_TEST_NVIM=/path/to/nvim." >&2
  if [ -n "${NVIM:-}" ]; then
    echo "       (\$NVIM is set to '$NVIM', which is not an executable file - probably a :terminal socket)" >&2
  fi
  exit 2
fi
# Children (e.g. test_smoke.sh) read $NVIM; give them the binary, not a socket.
NVIM="$nvim_bin"
export NVIM

# ---------------------------------------------------------------- shims (timeout, sha256sum)
shim_dir="$(mktemp -d "${TMPDIR:-/tmp}/agentmap-shims.XXXXXX")"
trap 'rm -rf "$shim_dir"' EXIT

timeout_mode="timeout"
if ! command -v timeout >/dev/null 2>&1; then
  if command -v gtimeout >/dev/null 2>&1; then
    ln -s "$(command -v gtimeout)" "$shim_dir/timeout"
    timeout_mode="gtimeout"
  elif command -v perl >/dev/null 2>&1; then
    # Minimal `timeout SECONDS CMD...`; exit 124 on expiry like GNU timeout.
    cat >"$shim_dir/timeout" <<'SH'
#!/usr/bin/env bash
secs="${1%s}"; shift
exec perl -e '
  my $t = shift; my $pid = fork();
  die "fork failed\n" unless defined $pid;
  if ($pid == 0) { exec { $ARGV[0] } @ARGV or exit 127 }
  local $SIG{ALRM} = sub { kill "TERM", $pid; sleep 2; kill "KILL", $pid; exit 124 };
  alarm $t; waitpid($pid, 0);
  exit($? & 127 ? 128 + ($? & 127) : $? >> 8);
' "$secs" "$@"
SH
    chmod +x "$shim_dir/timeout"
    timeout_mode="perl shim"
  else
    printf '#!/usr/bin/env bash\nshift\nexec "$@"\n' >"$shim_dir/timeout"
    chmod +x "$shim_dir/timeout"
    timeout_mode="none (no timeout, gtimeout or perl; tests run without a time limit)"
  fi
fi
if ! command -v sha256sum >/dev/null 2>&1 && command -v shasum >/dev/null 2>&1; then
  printf '#!/usr/bin/env bash\nexec shasum -a 256 "$@"\n' >"$shim_dir/sha256sum"
  chmod +x "$shim_dir/sha256sum"
fi
PATH="$shim_dir:$PATH"
export PATH

# ---------------------------------------------------------------- Python
have_python=0
if command -v python3 >/dev/null 2>&1 && python3 -c 'import sys; sys.exit(0 if sys.version_info[0] == 3 else 1)' >/dev/null 2>&1; then
  have_python=1
fi
# Tests that need Python 3: the collector itself, and hook registration (hooks.install() looks up
# a Python interpreter to build the hook command). A test can also opt in with a line containing
# "requires: python3" near the top of the file.
PYTHON_TESTS=" test_collector.sh test_smoke.sh test_hooks_merge.lua "
needs_python() {
  local name; name="$(basename "$1")"
  [[ "$PYTHON_TESTS" == *" $name "* ]] && return 0
  head -n 15 "$1" | grep -q 'requires: python3'
}

echo "nvim:    $nvim_bin ($("$nvim_bin" --version | head -n 1))"
if [ $have_python -eq 1 ]; then
  echo "python3: $(python3 --version 2>&1)"
else
  echo "python3: not found (collector and hook-registration tests will be skipped)"
fi
echo "timeout: $timeout_mode"
echo

# ---------------------------------------------------------------- run
pass=0; fail=0; skip=0; failed=(); skipped=()
started=$(date +%s)

for f in "$here"/test_*.lua "$here"/test_*.sh; do
  [ -e "$f" ] || continue
  name="$(basename "$f")"
  if [ -n "$filter" ] && [[ "$name" != *"$filter"* ]]; then continue; fi
  echo "== $name"
  if [ $have_python -eq 0 ] && needs_python "$f"; then
    echo "SKIP $name (python3 not found)"
    skip=$((skip+1)); skipped+=("$name")
    continue
  fi
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/agentmap-test.XXXXXX")"
  mkdir -p "$tmp/home" "$tmp/store" "$tmp/claude" "$tmp/xdg/config" "$tmp/xdg/data" "$tmp/xdg/state" "$tmp/xdg/cache"
  (
    unset AGENTFLOW_DIR NVIM_APPNAME VIMINIT MYVIMRC
    export HOME="$tmp/home"
    export XDG_CONFIG_HOME="$tmp/xdg/config" XDG_DATA_HOME="$tmp/xdg/data"
    export XDG_STATE_HOME="$tmp/xdg/state" XDG_CACHE_HOME="$tmp/xdg/cache"
    export CLAUDE_CONFIG_DIR="$tmp/claude"
    export AGENTMAP_DIR="$tmp/store"
    cd "$tmp" || exit 1
    if [[ "$name" == *.lua ]]; then
      exec timeout 120 "$NVIM" --headless --clean -u "$here/minimal_init.lua" -l "$f"
    else
      exec timeout 300 bash "$f"
    fi
  )
  code=$?
  rm -rf "$tmp"
  if [ $code -eq 0 ]; then
    echo "PASS $name"; pass=$((pass+1))
  else
    [ $code -eq 124 ] && echo "  (timed out)"
    echo "FAIL $name (exit $code)"; fail=$((fail+1)); failed+=("$name")
  fi
done

echo "------------------------------"
echo "Total: PASS $pass / FAIL $fail / SKIP $skip ($(( $(date +%s) - started )) s)"
if [ $skip -gt 0 ]; then
  printf '  skipped: %s\n' "${skipped[@]}"
fi
if [ $fail -gt 0 ]; then
  printf '  failed: %s\n' "${failed[@]}"
  exit 1
fi
if [ $((pass + skip)) -eq 0 ]; then
  echo "No tests matched '${filter}'." >&2
  exit 1
fi
exit 0

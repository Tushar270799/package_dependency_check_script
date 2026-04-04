#!/bin/bash
# =============================================================================
# slack-deps.sh — Runtime Dependency Finder for Slackware / Nakshatra Linux
# =============================================================================
#
# PURPOSE:
#   Tells you which Slackware packages a given program or package needs at
#   *runtime* — i.e. the shared libraries (.so files) that must be present
#   for it to actually run.  This is NOT build-time / compile-time deps.
#
# HOW IT WORKS (3 steps):
#   1. Find every ELF binary/library inside the target package or binary
#   2. Run `ldd` on each ELF to get the list of required shared libraries
#   3. Look up each .so in /var/log/packages to find the owning package
#
# Usage:
#   ./slack-deps.sh [OPTIONS] <target>
#
# <target> can be:
#   - A binary name in PATH       (e.g. "ls", "mkdir", "python3")
#   - An absolute binary path     (e.g. "/usr/bin/ls")
#   - An installed package name   (e.g. "coreutils", "htop")
#   - A .t?z package file         (e.g. "/tmp/curl-7.88-x86_64-1.txz")
#
# OPTIONS:
#   -r, --recursive     Also resolve deps-of-deps (full transitive tree)
#   -v, --verbose       Show individual .so → package mappings
#   -u, --unresolved    Show libraries not owned by any Slackware package
#   -h, --help          Show this help
#
# EXAMPLES:
#   ./slack-deps.sh htop
#   ./slack-deps.sh -v ls
#   ./slack-deps.sh -r -v mozilla-firefox
#   ./slack-deps.sh -u /tmp/myapp-1.0-x86_64-1.txz
# =============================================================================

# ── Shell safety options ──────────────────────────────────────────────────────
# -e  : exit immediately if any command returns a non-zero status
# -u  : treat unset variables as errors (catches typos in variable names)
# -o pipefail : if any command in a pipeline fails, the whole pipeline fails
#               (without this, "false | true" would silently succeed)
set -euo pipefail

# ── Terminal colour codes ─────────────────────────────────────────────────────
# $'...' is bash ANSI-C quoting — it allows escape sequences like \e inside strings.
# These are standard ANSI escape codes supported by all Linux terminals.
# Every coloured string MUST end with $RST to reset formatting.
RED=$'\e[1;31m'   # bold red    — fatal errors
YEL=$'\e[1;33m'   # bold yellow — warnings and unresolved items
GRN=$'\e[1;32m'   # bold green  — package names in output
CYN=$'\e[1;36m'   # bold cyan   — informational ":: " status lines
BLD=$'\e[1m'      # bold only   — section headers and counts
RST=$'\e[0m'      # reset all   — must follow every coloured string

# ── Helper functions ──────────────────────────────────────────────────────────

# die: print a red ERROR message to stderr, then exit with code 1 (failure).
# All fatal conditions use this.  "$*" joins all arguments with spaces.
die()  { echo "${RED}ERROR:${RST} $*" >&2; exit 1; }

# info: print a cyan ":: message" status line to stdout during normal operation.
info() { echo "${CYN}::${RST} $*"; }

# warn: print a yellow WARN message to stderr.
# Non-fatal — the script continues after a warning.
warn() { echo "${YEL}WARN:${RST}  $*" >&2; }

# ── Default option values ─────────────────────────────────────────────────────
RECURSIVE=0         # -r flag: if 1, resolve the full transitive dep tree
VERBOSE=0           # -v flag: if 1, print each individual .so → package line
SHOW_UNRESOLVED=0   # -u flag: if 1, list .so files not owned by any package
PKG_DB="/var/log/packages"  # Slackware/Nakshatra package database directory
TMPDIR_WORK=""      # path to temp extraction dir; empty until a .txz is used

# ── usage(): print the Usage block from the script header and exit ────────────
# sed -n with two address patterns prints only lines between those patterns.
# The second sed strips the leading "# " comment prefix from each line.
usage() {
    sed -n '/^# Usage:/,/^# ====/p' "$0" | sed 's/^# \?//'
    exit 0
}

# ── Argument parsing ──────────────────────────────────────────────────────────
[[ $# -eq 0 ]] && usage   # no arguments at all → show help

POSITIONAL=()   # collects non-option arguments (the target package/binary)

# Loop through all arguments.
# We use a while loop instead of getopts because we want to support
# long options like --recursive as well as short ones like -r.
while [[ $# -gt 0 ]]; do
    case "$1" in
        -r|--recursive)  RECURSIVE=1 ;;
        -v|--verbose)    VERBOSE=1 ;;
        -u|--unresolved) SHOW_UNRESOLVED=1 ;;
        -h|--help)       usage ;;
        -*)              die "Unknown option: $1" ;;
        *)               POSITIONAL+=("$1") ;;  # non-option: save it
    esac
    shift   # advance to the next argument
done

# Require at least one positional argument
[[ ${#POSITIONAL[@]} -eq 0 ]] && die "No target specified. Use -h for help."
TARGET="${POSITIONAL[0]}"   # the thing we want to find deps for

# ── Sanity checks: required external tools ────────────────────────────────────
# ldd   : "list dynamic dependencies" — prints shared libs an ELF needs
# file  : identifies file types by magic bytes (we use it to detect ELFs)
# Both are present in every base Slackware/Nakshatra installation.
command -v ldd  &>/dev/null || die "'ldd' not found. Is glibc installed?"
command -v file &>/dev/null || die "'file' not found. Is file(1) installed?"

# The package database directory must exist
[[ -d "$PKG_DB" ]] || die "Package database not found at $PKG_DB"

# ── Build the shared-library → package reverse lookup map ────────────────────
#
# /var/log/packages/ contains one plain-text file per installed package.
# Each file is named:   <name>-<version>-<arch>-<build>
# Example filename:     glibc-2.34-x86_64-1
#
# Each file looks like this:
#   PACKAGE NAME:     glibc
#   COMPRESSED PACKAGE SIZE:  ...
#   ...more metadata...
#   FILE LIST:
#   ./
#   ./lib64/
#   ./lib64/libc.so.6
#   ./lib64/libm.so.6
#   ./usr/lib64/libpthread.so
#   ...
#
# We scan every package file, find all .so entries in the FILE LIST,
# and build a hash map (associative array):
#   SO_OWNER["libc.so.6"]  = "glibc-2.34-x86_64-1"
#   SO_OWNER["libm.so.6"]  = "glibc-2.34-x86_64-1"
#   SO_OWNER["libcap.so.2"] = "aaa_libraries-1.0-x86_64-19"
#   ...
#
# Later, when ldd tells us a binary needs libc.so.6, we look it up here
# and immediately know it comes from the glibc package.

info "Building shared-library → package map (this may take a moment)…"

# declare -A creates an associative array (hash map / dictionary).
# The =() initialises it as empty — REQUIRED under set -u, otherwise
# accessing a key before any value is set would error with "unbound variable".
declare -A SO_OWNER=()

for pkgfile in "$PKG_DB"/*; do
    # Some entries in /var/log/packages/ might be directories — skip them
    [[ -f "$pkgfile" ]] || continue

    # The package name is the filename itself (e.g. glibc-2.34-x86_64-1)
    pkgname=$(basename "$pkgfile")

    # Flag: 0 = still in metadata section, 1 = inside FILE LIST section
    in_filelist=0

    while IFS= read -r line; do
        # IFS=  : don't strip leading/trailing whitespace
        # -r    : don't interpret backslashes

        if [[ $in_filelist -eq 0 ]]; then
            # In the metadata section — wait for the FILE LIST marker
            [[ "$line" == "FILE LIST:" ]] && in_filelist=1
            continue
        fi

        # ── Inside FILE LIST ──────────────────────────────────────────────────

        # Directory entries end with /  (e.g. "usr/lib64/")
        # We only want files, not directories, so skip these.
        [[ "$line" == */ ]] && continue

        # File path entries may appear in two forms:
        #   ./usr/lib64/libfoo.so.1.2.3   (older Slackware: with leading ./)
        #   usr/lib64/libfoo.so.1.2.3     (newer: without ./)
        #
        # Strip the leading "./" if present, then get just the filename.
        stripped_line="${line#./}"            # remove ./ prefix if present
        basename_line="${stripped_line##*/}"  # everything after the last /  = filename

        # Only index shared library files.
        # They match either:
        #   *.so      (bare soname, e.g. libfoo.so)
        #   *.so.*    (versioned,   e.g. libfoo.so.1  or  libfoo.so.1.2.3)
        if [[ "$basename_line" == *.so || "$basename_line" == *.so.* ]]; then

            # Index the full versioned name: "libfoo.so.1.2.3" → package
            SO_OWNER["$basename_line"]="$pkgname"

            # Also index a bare .so fallback: "libfoo.so" → package
            # This catches cases where ldd reports just the soname without version.
            # Syntax:  ${var%%.so*} strips everything from the first ".so" onward
            sobase="${basename_line%%.so*}.so"   # e.g. libfoo.so.1.2.3 → libfoo.so
            # Only set if not already set — first package to claim it wins
            # ${var+_} expands to "_" if var is set, empty if not (safe under set -u)
            [[ "${SO_OWNER[$sobase]+_}" ]] || SO_OWNER["$sobase"]="$pkgname"
        fi

    done < "$pkgfile"   # redirect the package file into the while loop
done

info "Indexed ${#SO_OWNER[@]} shared library entries."

# ── resolve_so(): map a .so name or path to its owning package ────────────────
#
# Input:  $1 = a shared library path (/lib64/libc.so.6) or name (libc.so.6)
# Output: the owning package name printed to stdout, or empty string if not found
#
# Four strategies tried in order from fastest to slowest:
#   1. Direct exact lookup in SO_OWNER map
#   2. Progressively strip version suffixes and retry
#   3. Follow symlinks to the real filename and retry
#   4. Grep all package DB files for the exact path (slowest, last resort)
resolve_so() {
    local so="$1"
    local base
    base=$(basename "$so")   # strip any directory prefix

    # ── Strategy 1: direct lookup ─────────────────────────────────────────────
    # Check if this exact name is in our map.
    # ${SO_OWNER[$base]+_} expands to "_" if the key exists (even if value=""),
    # or to "" if the key doesn't exist. This is the correct idiom under set -u.
    if [[ "${SO_OWNER[$base]+_}" ]]; then
        echo "${SO_OWNER[$base]}"
        return
    fi

    # ── Strategy 2: strip version suffixes ────────────────────────────────────
    # ldd might say "libc.so.6" but the DB only has "libc.so", or vice versa.
    # We iteratively strip the last ".something" from the name:
    #   libfoo.so.1.2.3  →  libfoo.so.1.2  →  libfoo.so.1  →  libfoo.so
    # and check the map after each step.
    local stripped="$base"
    while [[ "$stripped" == *.*.* ]]; do     # keep going while name has 2+ dots after .so
        stripped="${stripped%.*}"            # remove the last .component
        [[ "${SO_OWNER[$stripped]+_}" ]] && { echo "${SO_OWNER[$stripped]}"; return; }
    done

    # ── Strategy 3: follow symlinks ───────────────────────────────────────────
    # Many .so files are symlinks:  /lib64/libc.so.6 → /lib64/libc-2.34.so
    # The package DB might index the real filename, not the symlink name.
    if [[ -f "$so" ]]; then
        local real
        real=$(readlink -f "$so" 2>/dev/null || echo "$so")  # resolve symlink chain
        local realbase
        realbase=$(basename "$real")
        [[ "${SO_OWNER[$realbase]+_}" ]] && { echo "${SO_OWNER[$realbase]}"; return; }

        # ── Strategy 4: grep the raw DB ───────────────────────────────────────
        # Slowest option — scan all package record files looking for this path.
        # This catches edge cases not covered by the initial map build.
        # grep -r : recursive scan of all files in PKG_DB
        # grep -l : print only the filenames of matching records (not the lines)
        local rel_path="${so#/}"   # remove leading / to get e.g. lib64/libc.so.6
        local found
        found=$(grep -rl "^\.\?/${rel_path}$" "$PKG_DB" 2>/dev/null | head -1)
        [[ -n "$found" ]] && { basename "$found"; return; }
    fi

    echo ""   # not found — caller checks for empty return value
}

# ── elf_files_from_installed(): get ELF binary paths for an installed package ──
#
# Input:  $1 = package name, either exact (htop-3.2.1-x86_64-2) or short (htop)
# Output: absolute path of each ELF binary/library that belongs to the package
#
# How we find the package record:
#   - Try exact filename match first (user gave the full versioned name)
#   - Then try a shell glob:  /var/log/packages/htop-[0-9]*
#     The [0-9] ensures we only match the version number, not e.g. htop-extra
elf_files_from_installed() {
    local pkgname="$1"
    local pkgfile=""

    # ── Exact match ───────────────────────────────────────────────────────────
    if [[ -f "$PKG_DB/$pkgname" ]]; then
        pkgfile="$PKG_DB/$pkgname"
    else
        # ── Fuzzy/glob match ──────────────────────────────────────────────────
        # Bash expands the glob before assigning to the array.
        # If nothing matches, the array contains the literal glob string.
        local matches=( "$PKG_DB/${pkgname}"-[0-9]* )
        pkgfile=""
        local m
        for m in "${matches[@]}"; do
            [[ -f "$m" ]] && { pkgfile="$m"; break; }  # use first real match
        done

        if [[ -z "$pkgfile" ]]; then
            warn "Package '$pkgname' is not installed (not found in $PKG_DB)"
            return 1   # signal failure to the caller
        fi
    fi

    # ── Walk the FILE LIST section ────────────────────────────────────────────
    local in_list=0
    while IFS= read -r line; do
        if [[ $in_list -eq 0 ]]; then
            [[ "$line" == "FILE LIST:" ]] && in_list=1
            continue
        fi

        # Skip directory entries (trailing slash)
        [[ "$line" == */ ]] && continue

        # Build absolute path from the relative entry
        # Strip optional "./" prefix, then prepend "/"
        local abs="/${line#./}"

        # Skip if the file doesn't actually exist on disk
        # (can happen if the package is partially installed or the DB is stale)
        [[ -f "$abs" ]] || continue

        # file -b = brief output (no filename prefix in the output).
        # ELF files (executables and shared libraries) start with "ELF".
        # We only emit actual ELF files; scripts, configs etc. are skipped.
        file -b "$abs" 2>/dev/null | grep -q "^ELF" && echo "$abs"

    done < "$pkgfile"
}

# ── elf_files_from_tgz(): extract and scan a .txz/.tgz package archive ───────
#
# Input:  $1 = path to the package archive file
# Output: absolute paths of all ELF files found inside the archive
#
# Slackware packages are tarballs compressed with gzip (.tgz) or xz (.txz).
# tar -xf auto-detects the compression format.
# We extract to a temporary directory, scan for ELFs, then clean up on EXIT.
elf_files_from_tgz() {
    local pkgfile="$1"

    # mktemp -d creates a unique temporary directory safely
    TMPDIR_WORK=$(mktemp -d /tmp/slack-deps.XXXXXX)
    info "Extracting package to $TMPDIR_WORK …"

    # Extract the archive into the temp directory
    tar -xf "$pkgfile" -C "$TMPDIR_WORK" 2>/dev/null || \
        die "Failed to extract $pkgfile — is it a valid Slackware package?"

    # find -type f : only regular files (not symlinks or dirs)
    # -exec sh -c '...' _ {} \;  : run a shell for each file
    # Inside the shell: file -b checks magic bytes, grep filters for ELF
    find "$TMPDIR_WORK" -type f -exec sh -c \
        'file -b "$1" 2>/dev/null | grep -q "^ELF" && echo "$1"' _ {} \;
}

# ── pkg_for_binary(): reverse-lookup which package owns a given binary ────────
#
# Input:  $1 = a binary name ("ls") or path ("/usr/bin/ls")
# Output: line 1 = resolved absolute path of the binary
#         line 2 = name of the package that owns it
# Returns: 0 on success, 1 if not found
#
# This lets the user type  ./slack-deps.sh ls  without needing to know
# that "ls" belongs to the "coreutils" package.
pkg_for_binary() {
    local bin="$1"
    local abspath=""

    # Resolve to an absolute path:
    # Case 1: user gave a path that already exists as a file
    if [[ -f "$bin" ]]; then
        abspath=$(readlink -f "$bin")   # resolve any symlinks in the path
    else
        # Case 2: look up the binary name in PATH (like the shell does)
        abspath=$(command -v "$bin" 2>/dev/null) || true
        [[ -n "$abspath" ]] && abspath=$(readlink -f "$abspath")
    fi

    [[ -z "$abspath" ]] && return 1   # couldn't find the binary at all

    # Search the package DB for a record that lists this file.
    # The relative path in the DB (e.g. "usr/bin/ls") is our search key.
    # Records may list it as  "./usr/bin/ls"  or  "usr/bin/ls"  — we match both.
    local rel="${abspath#/}"   # strip leading /  →  usr/bin/ls
    local pkgfile
    # grep -r : scan all files in PKG_DB
    # grep -l : print only filenames of matching records
    pkgfile=$(grep -rl "^\./${rel}$\|^${rel}$" "$PKG_DB" 2>/dev/null | head -1)

    if [[ -n "$pkgfile" ]]; then
        echo "$abspath"               # line 1: the binary's absolute path
        echo "$(basename "$pkgfile")" # line 2: owning package record name
        return 0
    fi

    return 1   # not found in any package record
}

# ── Cleanup trap ──────────────────────────────────────────────────────────────
# The EXIT trap runs whenever the script exits — normally, on error, or on Ctrl-C.
# It removes the temporary directory if one was created by elf_files_from_tgz().
cleanup() { [[ -n "$TMPDIR_WORK" ]] && rm -rf "$TMPDIR_WORK"; }
trap cleanup EXIT

# ── Input mode detection ──────────────────────────────────────────────────────
#
# We support four types of input and handle each differently:
#
#   Mode 1 — .t?z archive:     extract it, scan for ELFs
#   Mode 2 — binary name/path: resolve to single ELF via PATH or filesystem
#   Mode 3 — package name:     look up in /var/log/packages, list its ELFs

declare -a ELF_FILES=()   # will hold absolute paths of ELF files to analyse
PKG_LABEL="$TARGET"       # label shown in the output header

if [[ -f "$TARGET" && "$TARGET" == *.t?z ]]; then
    # ── Mode 1: package archive file (.txz, .tgz, .tbz, .tlz) ───────────────
    # The glob *.t?z matches any single character: txz, tgz, tbz, tlz
    info "Mode: package file  →  $TARGET"
    mapfile -t ELF_FILES < <(elf_files_from_tgz "$TARGET")

elif [[ -f "$TARGET" ]] || command -v "$TARGET" &>/dev/null; then
    # ── Mode 2: binary name or path ──────────────────────────────────────────
    # Matches when TARGET is an existing file OR a name found in $PATH.
    # Examples:  "ls", "python3", "/usr/bin/gcc", "./myprog"
    info "Mode: binary  →  $TARGET"

    # pkg_for_binary prints two lines to stdout; we capture them together
    local_result=$(pkg_for_binary "$TARGET") || true

    if [[ -n "$local_result" ]]; then
        abspath=$(echo "$local_result" | head -1)    # line 1: binary path
        owner_pkg=$(echo "$local_result" | tail -1)  # line 2: package name
        PKG_LABEL="$TARGET  (package: $owner_pkg)"

        # Verify it's actually an ELF — could be a shell script (#!/bin/bash)
        # or a Python script etc., which ldd can't analyse
        if file -b "$abspath" 2>/dev/null | grep -q "^ELF"; then
            ELF_FILES=( "$abspath" )
        else
            die "'$abspath' is not an ELF binary (it may be a shell script or text file)"
        fi
    else
        die "Could not find '$TARGET' in any installed package."
    fi

else
    # ── Mode 3: installed package name ───────────────────────────────────────
    # Examples: "htop", "coreutils", "mozilla-firefox", "glibc-2.34-x86_64-1"
    info "Mode: installed package  →  $TARGET"
    # "|| true" prevents set -e from killing the script if the package
    # isn't found — elf_files_from_installed will already print a warning.
    mapfile -t ELF_FILES < <(elf_files_from_installed "$TARGET" || true)
fi

# ── Guard: we must have at least one ELF to analyse ──────────────────────────
if [[ ${#ELF_FILES[@]} -eq 0 ]]; then
    die "No ELF binaries found for '$TARGET'.
       If '$TARGET' is a command (like ls, mkdir), it should be auto-detected.
       Otherwise pass the owning package name (e.g. coreutils, util-linux)."
fi
info "Found ${#ELF_FILES[@]} ELF file(s) to inspect."

# ── Global result maps ────────────────────────────────────────────────────────
# These are written to directly by collect_deps_for_elfs() below.
# Using globals (instead of passing arrays by reference) avoids the bash 4.x
# nameref bug where assignments through local -n namerefs are silently dropped.
declare -A FOUND_PKGS=()  # set of owning packages found  (key=pkgname, value=1)
declare -A UNRES=()       # set of unresolved .so names    (key=soname,  value=1)

# ── collect_deps_for_elfs(): core dependency analysis function ────────────────
#
# Reads ELF file paths from stdin (one path per line).
# For each ELF, calls ldd and parses its output.
# Resolved packages are written into global FOUND_PKGS.
# Unresolved .so names are written into global UNRES.
#
# Why stdin?
#   Bash namerefs (local -n) for passing associative arrays into functions
#   are unreliable in bash 4.x: assignments through the nameref to an array
#   declared in the outer scope are silently discarded in some versions.
#   stdin + globals sidesteps this entirely.
#
# ldd output format (two main forms):
#
#   Form A — normal library:
#     "        libc.so.6 => /lib64/libc.so.6 (0x00007f...)"
#      ^spaces  ^soname     ^resolved path     ^load address
#
#   Form B — dynamic linker (no "=>" form):
#     "        /lib64/ld-linux-x86-64.so.2 (0x00007f...)"
#      ^spaces  ^absolute path              ^load address
collect_deps_for_elfs() {
    local elf
    while IFS= read -r elf; do
        [[ -z "$elf" ]] && continue   # skip blank lines from printf

        # Run ldd on this ELF.
        # 2>/dev/null : suppress ldd error messages
        # || true     : don't abort under set -e if ldd exits non-zero
        local ldd_out
        ldd_out=$(ldd "$elf" 2>/dev/null) || true
        [[ -z "$ldd_out" ]] && continue   # no output → nothing to parse

        while IFS= read -r line; do

            # ── Lines to skip ─────────────────────────────────────────────────

            # linux-vdso.so.1 is a virtual DSO injected by the kernel.
            # It has no file on disk and belongs to no installable package.
            [[ "$line" == *"linux-vdso"* ]]       && continue

            # ldd prints "not a dynamic executable" for static binaries or
            # files that aren't ELF at all (shouldn't happen here, but safe)
            [[ "$line" == *"not a dynamic"* ]]     && continue

            # Fully statically linked binaries produce this single line
            [[ "$line" == *"statically linked"* ]] && continue

            # ── Parse the library line ────────────────────────────────────────
            local soname="" sopath=""

            # Form A: "    libfoo.so.1 => /lib64/libfoo.so.1 (0x7f...)"
            # We anchor to leading whitespace (ldd indents all lines).
            # BASH_REMATCH[1] = soname,  BASH_REMATCH[2] = resolved path
            if [[ "$line" =~ [[:space:]]([^[:space:]]+)[[:space:]]+\=\>[[:space:]]+([^[:space:]]+) ]]; then
                soname="${BASH_REMATCH[1]}"   # e.g. libc.so.6
                sopath="${BASH_REMATCH[2]}"   # e.g. /lib64/libc.so.6
                # "(0x..." means the library was not found on disk
                [[ "$sopath" == "(0x"* ]] && sopath=""

            # Form B: "    /lib64/ld-linux-x86-64.so.2 (0x7f...)"
            # Matches a leading-space + absolute path
            elif [[ "$line" =~ ^[[:space:]]+(/[^[:space:]]+) ]]; then
                sopath="${BASH_REMATCH[1]}"   # e.g. /lib64/ld-linux-x86-64.so.2
                soname="${sopath##*/}"        # basename: ld-linux-x86-64.so.2
            else
                continue   # line matched neither form — skip
            fi

            [[ -z "$soname" ]] && continue

            # ── Resolve .so to its owning package ─────────────────────────────
            local owner=""

            # Try by full path first (more accurate — handles symlinks)
            if [[ -n "$sopath" && "$sopath" != "not" ]]; then
                owner=$(resolve_so "$sopath")
            fi
            # Fall back to soname alone
            if [[ -z "$owner" ]]; then
                owner=$(resolve_so "$soname")
            fi

            # ── Record the result ─────────────────────────────────────────────
            if [[ -n "$owner" ]]; then
                # Using the map as a set: key = package name, value = 1.
                # Duplicate entries are automatically deduplicated since
                # assigning the same key twice just overwrites with "1" again.
                FOUND_PKGS["$owner"]=1

                # In verbose mode, print the per-library mapping line
                if [[ $VERBOSE -eq 1 ]]; then
                    printf "    ${GRN}%-40s${RST} → %s\n" "$soname" "$owner"
                fi
            else
                # Not found in any package — record as unresolved
                UNRES["$soname"]=1
            fi

        done <<< "$ldd_out"
        # <<< is a "herestring" — feeds the string into the while loop's stdin
    done
}

# ── Print output header ───────────────────────────────────────────────────────
echo ""
echo "${BLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RST}"
echo "${BLD} Runtime dependencies for: ${CYN}${PKG_LABEL}${RST}"
echo "${BLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RST}"
[[ $VERBOSE -eq 1 ]] && echo ""

# ── First pass: direct (immediate) dependencies ───────────────────────────────
# Feed all ELF paths into collect_deps_for_elfs via process substitution.
# printf '%s\n' prints each array element on its own line.
# < <(...)  feeds the process substitution output into the function's stdin.
# The function runs in the CURRENT shell (not a subshell), so it can write
# to the global FOUND_PKGS and UNRES arrays.
collect_deps_for_elfs < <(printf '%s\n' "${ELF_FILES[@]}")

# Remove the target itself from results.
# This can appear if one of the package's own .so files happens to be listed
# as a dependency of another binary in the same package.
unset "FOUND_PKGS[$TARGET]"
for k in "${!FOUND_PKGS[@]}"; do
    # Also remove versioned forms, e.g. if TARGET=htop, remove htop-3.2.1-x86_64-2
    [[ "$k" == "${TARGET}-"* ]] && unset "FOUND_PKGS[$k]"
done

# ── Optional recursive pass: full transitive dependency tree ──────────────────
#
# With -r we don't just find what htop needs — we also find what those
# packages need, and what THOSE need, all the way down.
#
# Algorithm: Breadth-First Search (BFS)
#   - Initial queue = direct deps found above
#   - While queue is not empty:
#       - Dequeue a package
#       - Find its ELFs and run ldd on them
#       - Any new package discovered → add to queue
#   - Result = every package reachable transitively
#
# BFS is used instead of DFS to process packages "level by level",
# and the visited map prevents infinite loops from circular deps.
if [[ $RECURSIVE -eq 1 && ${#FOUND_PKGS[@]} -gt 0 ]]; then
    info "Resolving transitive dependencies…"

    # ALL_PKGS collects every package seen across all BFS iterations
    declare -A ALL_PKGS=()
    for p in "${!FOUND_PKGS[@]}"; do ALL_PKGS["$p"]=1; done

    # bfs_queue is a regular indexed array used as a FIFO queue
    # Initialised with the direct deps
    declare -a bfs_queue=("${!FOUND_PKGS[@]}")

    # visited prevents reprocessing the same package (handles circular deps)
    declare -A visited=()

    while [[ ${#bfs_queue[@]} -gt 0 ]]; do
        # Dequeue: take the first element
        current="${bfs_queue[0]}"
        # Remove element 0 by re-slicing the array from index 1 onward
        bfs_queue=("${bfs_queue[@]:1}")

        # Skip if we've already processed this package
        [[ "${visited[$current]+_}" ]] && continue
        visited["$current"]=1

        # Get ELF files for this dependency package
        mapfile -t sub_elfs < <(elf_files_from_installed "$current" 2>/dev/null || true)
        [[ ${#sub_elfs[@]} -eq 0 ]] && continue

        # Analyse — results accumulate into the global FOUND_PKGS
        collect_deps_for_elfs < <(printf '%s\n' "${sub_elfs[@]}")

        # Queue any newly discovered packages
        for p in "${!FOUND_PKGS[@]}"; do
            [[ "${ALL_PKGS[$p]+_}" ]] || bfs_queue+=("$p")
            ALL_PKGS["$p"]=1
        done
    done

    # Merge ALL_PKGS into FOUND_PKGS so the output section sees everything
    for p in "${!ALL_PKGS[@]}"; do FOUND_PKGS["$p"]=1; done
fi

# ── Output section: required packages ────────────────────────────────────────
echo ""
if [[ ${#FOUND_PKGS[@]} -eq 0 ]]; then
    echo "  ${YEL}No runtime dependencies found.${RST}"
else
    echo "${BLD}  Required Slackware packages (${#FOUND_PKGS[@]}):${RST}"
    echo ""
    # Sort package names alphabetically for consistent, readable output.
    # We print two columns:
    #   left  = base package name (without version/arch/build)
    #   right = full record name  (with version/arch/build)
    for pkg in $(printf '%s\n' "${!FOUND_PKGS[@]}" | sort); do

        # Parse the Slackware naming convention:  name-version-arch-build
        # The regex handles package names that themselves contain hyphens
        # (e.g. "aaa-base", "mozilla-firefox").
        # Key insight: the version always starts with a digit, so we use
        # -([0-9][^-]*) to find where the version begins.
        if [[ "$pkg" =~ ^([^-]+(-[^-]+)*)-([0-9][^-]*)-([^-]+)-([^-]+)$ ]]; then
            name="${BASH_REMATCH[1]}"   # base name only (e.g. "glibc")
            printf "  ${GRN}%-35s${RST}  %s\n" "$name" "$pkg"
        else
            # Fallback for unexpected name formats
            printf "  ${GRN}%s${RST}\n" "$pkg"
        fi
    done
fi

# ── Output section: unresolved libraries (shown only with -u) ─────────────────
# These are .so files that ldd found but we couldn't map to any package.
# Common causes: third-party software not in the Slackware DB, or
# libraries installed manually outside the package manager.
if [[ $SHOW_UNRESOLVED -eq 1 && ${#UNRES[@]} -gt 0 ]]; then
    echo ""
    echo "${BLD}  ${YEL}Unresolved shared libraries (${#UNRES[@]}):${RST}"
    echo "  ${YEL}(present at runtime but not owned by any indexed package)${RST}"
    echo ""
    for so in $(printf '%s\n' "${!UNRES[@]}" | sort); do
        printf "  ${YEL}⚠  %s${RST}\n" "$so"
    done
fi

echo "${BLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RST}"

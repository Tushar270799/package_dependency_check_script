#!/bin/bash
# =============================================================================
# slack-deps.sh — Runtime Dependency Finder for Slackware / Nakshatra Linux
# =============================================================================
#
# WHAT THIS SCRIPT DOES (in simple words):
#   When you install a program like "htop" or "firefox", that program does NOT
#   contain everything it needs inside itself. Instead it BORROWS code from
#   shared library files (files ending in .so like libc.so.6, libm.so.6).
#   These .so files must already be installed on your system for the program
#   to run. This script tells you WHICH Slackware packages provide those .so
#   files — so you know what else needs to be installed.
#
#   Example: htop needs these .so files to run:
#     libc.so.6       → comes from package: glibc-2.34-x86_64-1
#     libncurses.so.6 → comes from package: ncurses-6.3-x86_64-1
#     libnl-3.so.200  → comes from package: libnl3-3.5.0-x86_64-3
#
# HOW IT WORKS (3 steps):
#   1. Find every ELF binary/library inside the target package or binary
#      (ELF = the format of real compiled programs on Linux, not shell scripts)
#   2. Run `ldd` on each ELF to get the list of required shared libraries
#      (ldd = a tool that asks "what .so files does this program need?")
#   3. Look up each .so in /var/log/packages to find the owning package
#      (/var/log/packages = Slackware's database of installed packages,
#       each package has a text file listing every file it put on your disk)
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
#   -v, --verbose       Show individual .so → package mappings
#   -u, --unresolved    Show libraries not owned by any Slackware package
#   -h, --help          Show this help
#
# EXAMPLES:
#   ./slack-deps.sh htop
#   ./slack-deps.sh -v ls
#   ./slack-deps.sh -v mozilla-firefox
#   ./slack-deps.sh -u /tmp/myapp-1.0-x86_64-1.txz
# =============================================================================

set -euo pipefail
RED=$'\e[1;31m'   # bold red    — used for: fatal ERROR messages
YEL=$'\e[1;33m'   # bold yellow — used for: WARN messages and unresolved items
GRN=$'\e[1;32m'   # bold green  — used for: package names in the output list
CYN=$'\e[1;36m'   # bold cyan   — used for: the ":: " status/progress lines
BLD=$'\e[1m'      # bold only   — used for: section headers and counts
RST=$'\e[0m'      # reset all   — must follow every coloured string


die()  { echo "${RED}ERROR:${RST} $*" >&2; exit 1; }
info() { echo "${CYN}::${RST} $*"; }
warn() { echo "${YEL}WARN:${RST}  $*" >&2; }
VERBOSE=0
SHOW_UNRESOLVED=0
PKG_DB="/var/log/packages"
TMPDIR_WORK=""
usage() {
    sed -n '/^# Usage:/,/^# ====/p' "$0" | sed 's/^# \?//'
    exit 0
}


# =============================================================================
# SECTION 6 — ARGUMENT PARSING
# =============================================================================

[[ $# -eq 0 ]] && usage
POSITIONAL=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        -v|--verbose)    VERBOSE=1 ;;
        -u|--unresolved) SHOW_UNRESOLVED=1 ;;
        -h|--help)       usage ;;
        -*)              die "Unknown option: $1" ;;
        *)               POSITIONAL+=("$1") ;;

    esac
    shift
done
[[ ${#POSITIONAL[@]} -eq 0 ]] && die "No target specified. Use -h for help."
TARGET="${POSITIONAL[0]}"


# =============================================================================
# SECTION 7 — SANITY CHECKS
# =============================================================================
command -v ldd  &>/dev/null || die "'ldd' not found. Is glibc installed?"
command -v file &>/dev/null || die "'file' not found. Is file(1) installed?"
[[ -d "$PKG_DB" ]] || die "Package database not found at $PKG_DB"


# =============================================================================
# SECTION 8 — BUILD THE .so → PACKAGE REVERSE LOOKUP MAP
# =============================================================================
info "Building shared-library → package map (this may take a moment)…"
declare -A SO_OWNER=()
for pkgfile in "$PKG_DB"/*; do
    [[ -f "$pkgfile" ]] || continue
    pkgname=$(basename "$pkgfile")
    in_filelist=0
    while IFS= read -r line; do

        if [[ $in_filelist -eq 0 ]]; then
            [[ "$line" == "FILE LIST:" ]] && in_filelist=1
            continue
        fi

        # ── We are now INSIDE the FILE LIST section ───────────────────────────
        [[ "$line" == */ ]] && continue
        stripped_line="${line#./}"
        basename_line="${stripped_line##*/}"
        if [[ "$basename_line" == *.so || "$basename_line" == *.so.* ]]; then
            SO_OWNER["$basename_line"]="$pkgname"
            sobase="${basename_line%%.so*}.so"
            [[ "${SO_OWNER[$sobase]+_}" ]] || SO_OWNER["$sobase"]="$pkgname"
        fi

    done < "$pkgfile"   # ← THIS is where the file gets opened and read
                         # The redirection < feeds pkgfile into the while loop's stdin
done

info "Indexed ${#SO_OWNER[@]} shared library entries."


# =============================================================================
# SECTION 8a — FUNCTION: resolve_so()
# =============================================================================
resolve_so() {
    local so="$1"
    local base
    base=$(basename "$so")
    if [[ "${SO_OWNER[$base]+_}" ]]; then
        echo "${SO_OWNER[$base]}"
        return   # return = exit function immediately (success, exit code 0)
    fi

    local stripped="$base"   # start with full name, will shorten each iteration
    while [[ "$stripped" == *.*.* ]]; do
        stripped="${stripped%.*}"
        [[ "${SO_OWNER[$stripped]+_}" ]] && { echo "${SO_OWNER[$stripped]}"; return; }
    done

    if [[ -f "$so" ]]; then
        local real
        real=$(readlink -f "$so" 2>/dev/null || echo "$so")
        local realbase
        realbase=$(basename "$real")
        [[ "${SO_OWNER[$realbase]+_}" ]] && { echo "${SO_OWNER[$realbase]}"; return; }
        local rel_path="${so#/}"
        local found
        found=$(grep -rl "^\.\?/${rel_path}$" "$PKG_DB" 2>/dev/null | head -1)
        [[ -n "$found" ]] && { basename "$found"; return; }
    fi
    echo ""
}


# =============================================================================
# SECTION 8b — FUNCTION: elf_files_from_installed()
# =============================================================================

elf_files_from_installed() {
    local pkgname="$1"
    local pkgfile=""
    if [[ -f "$PKG_DB/$pkgname" ]]; then
        pkgfile="$PKG_DB/$pkgname"   # exact match found, use it directly

    else
        local matches=( "$PKG_DB/${pkgname}"-[0-9]* )

        pkgfile=""   # reset pkgfile to empty before the search loop
        local m      # loop variable (declared local to keep it inside function)
        for m in "${matches[@]}"; do
            [[ -f "$m" ]] && { pkgfile="$m"; break; }
        done

        if [[ -z "$pkgfile" ]]; then
            warn "Package '$pkgname' is not installed (not found in $PKG_DB)"
            return 1   # return 1 = signal FAILURE to whoever called this function
                        # The caller can check: function_call || handle_error
        fi
    fi

    # ── Walk the FILE LIST section of the found package file ──────────────────

    local in_list=0   # flag: 0=in metadata, 1=in FILE LIST section

    while IFS= read -r line; do

        if [[ $in_list -eq 0 ]]; then
            [[ "$line" == "FILE LIST:" ]] && in_list=1
            continue   # skip this line (metadata or the marker itself)
        fi

        [[ "$line" == */ ]] && continue

        local abs="/${line#./}"

        [[ -f "$abs" ]] || continue

        file -b "$abs" 2>/dev/null | grep -q "^ELF" && echo "$abs"

    done < "$pkgfile"   # feed the package record file into the while loop
}


# =============================================================================
# SECTION 8c — FUNCTION: elf_files_from_tgz()
# =============================================================================


elf_files_from_tgz() {
    local pkgfile="$1"
    TMPDIR_WORK=$(mktemp -d /tmp/slack-deps.XXXXXX)
    info "Extracting package to $TMPDIR_WORK …"
    tar -xf "$pkgfile" -C "$TMPDIR_WORK" 2>/dev/null || \
        die "Failed to extract $pkgfile — is it a valid Slackware package?"
    find "$TMPDIR_WORK" -type f -exec sh -c \
        'file -b "$1" 2>/dev/null | grep -q "^ELF" && echo "$1"' _ {} \;
}


# =============================================================================
# SECTION 8d — FUNCTION: pkg_for_binary()
# =============================================================================
pkg_for_binary() {
    local bin="$1"
    local abspath=""   # will hold the resolved absolute path
    if [[ -f "$bin" ]]; then
        abspath=$(readlink -f "$bin")

    else
        abspath=$(command -v "$bin" 2>/dev/null) || true

        [[ -n "$abspath" ]] && abspath=$(readlink -f "$abspath")
    fi

    [[ -z "$abspath" ]] && return 1

    local rel="${abspath#/}"

    local pkgfile
    pkgfile=$(grep -rl "^\./${rel}$\|^${rel}$" "$PKG_DB" 2>/dev/null | head -1)

    if [[ -n "$pkgfile" ]]; then
        echo "$abspath"                # Line 1: print the absolute binary path
        echo "$(basename "$pkgfile")"  # Line 2: print just the package name
                                       # basename strips "/var/log/packages/" prefix
        return 0   # 0 = success
    fi

    return 1   # package not found in database — return failure
}


# =============================================================================
# SECTION 9 — CLEANUP TRAP
# =============================================================================

cleanup() { [[ -n "$TMPDIR_WORK" ]] && rm -rf "$TMPDIR_WORK"; }
trap cleanup EXIT


# =============================================================================
# SECTION 10 — INPUT MODE DETECTION
# =============================================================================

declare -a ELF_FILES=()
PKG_LABEL="$TARGET"

if [[ -f "$TARGET" && "$TARGET" == *.t?z ]]; then
    info "Mode: package file  →  $TARGET"
    mapfile -t ELF_FILES < <(elf_files_from_tgz "$TARGET")

# ── MODE 2: Target is a binary name or path ───────────────────────────────────

elif [[ -f "$TARGET" ]] || command -v "$TARGET" &>/dev/null; then

    info "Mode: binary  →  $TARGET"

    local_result=$(pkg_for_binary "$TARGET") || true

    if [[ -n "$local_result" ]]; then

        abspath=$(echo "$local_result" | head -1)
        owner_pkg=$(echo "$local_result" | tail -1)
        PKG_LABEL="$TARGET  (package: $owner_pkg)"
        if file -b "$abspath" 2>/dev/null | grep -q "^ELF"; then
            ELF_FILES=( "$abspath" )
        else
            die "'$abspath' is not an ELF binary (it may be a shell script or text file)"
        fi
    else
        die "Could not find '$TARGET' in any installed package."
    fi

# ── MODE 3: Target is an installed package name ───────────────────────────────
else
    info "Mode: installed package  →  $TARGET"
    mapfile -t ELF_FILES < <(elf_files_from_installed "$TARGET" || true)
fi


# =============================================================================
# SECTION 11 — GUARD CHECK: must have at least one ELF file
# =============================================================================

if [[ ${#ELF_FILES[@]} -eq 0 ]]; then
    die "No ELF binaries found for '$TARGET'.
       If '$TARGET' is a command (like ls, mkdir), it should be auto-detected.
       Otherwise pass the owning package name (e.g. coreutils, util-linux)."
fi

info "Found ${#ELF_FILES[@]} ELF file(s) to inspect."


# =============================================================================
# SECTION 12 — GLOBAL RESULT MAPS
# =============================================================================

declare -A FOUND_PKGS=()
declare -A UNRES=()


# =============================================================================
# SECTION 13 — FUNCTION: collect_deps_for_elfs()
# =============================================================================

collect_deps_for_elfs() {
    local elf   # loop variable: will hold each ELF file path from stdin
    while IFS= read -r elf; do
        [[ -z "$elf" ]] && continue
        local ldd_out
        ldd_out=$(ldd "$elf" 2>/dev/null) || true
        [[ -z "$ldd_out" ]] && continue
        while IFS= read -r line; do

            [[ "$line" == *"linux-vdso"* ]]       && continue
            [[ "$line" == *"not a dynamic"* ]]     && continue
            [[ "$line" == *"statically linked"* ]] && continue

            local soname="" sopath=""   # reset for each line
            if [[ "$line" =~ [[:space:]]([^[:space:]]+)[[:space:]]+\=\>[[:space:]]+([^[:space:]]+) ]]; then
                soname="${BASH_REMATCH[1]}"   # e.g. "libc.so.6"
                sopath="${BASH_REMATCH[2]}"   # e.g. "/lib64/libc.so.6"
                [[ "$sopath" == "(0x"* ]] && sopath=""
            elif [[ "$line" =~ ^[[:space:]]+(/[^[:space:]]+) ]]; then
                sopath="${BASH_REMATCH[1]}"   # e.g. "/lib64/ld-linux-x86-64.so.2"
                soname="${sopath##*/}"         # strip all dirs: get just the filename
                                               # ##*/ = remove everything up to last /

            else
                continue
            fi

            [[ -z "$soname" ]] && continue

            # ── Resolve the .so to its owning package ─────────────────────────
            local owner=""
            if [[ -n "$sopath" && "$sopath" != "not" ]]; then
                owner=$(resolve_so "$sopath")
            fi
            if [[ -z "$owner" ]]; then
                owner=$(resolve_so "$soname")
            fi

            # ── Record the result ─────────────────────────────────────────────

            if [[ -n "$owner" ]]; then
                FOUND_PKGS["$owner"]=1
                if [[ $VERBOSE -eq 1 ]]; then
                    printf "    ${GRN}%-40s${RST} → %s\n" "$soname" "$owner"
                fi
            else
                UNRES["$soname"]=1
            fi

        done <<< "$ldd_out"
    done
}


# =============================================================================
# SECTION 14 — PRINT OUTPUT HEADER
# =============================================================================
# Print the decorative bordered header at the top of the results output
# =============================================================================

echo ""   # blank line before the header for visual spacing

echo "${BLD}--------------------------------------------------------━${RST}"

echo "${BLD} Runtime dependencies for: ${CYN}${PKG_LABEL}${RST}"

echo "${BLD}--------------------------------------------------------${RST}"

[[ $VERBOSE -eq 1 ]] && echo ""


# =============================================================================
# SECTION 15 — FIRST PASS: DIRECT (IMMEDIATE) DEPENDENCIES
# =============================================================================

collect_deps_for_elfs < <(printf '%s\n' "${ELF_FILES[@]}")
unset "FOUND_PKGS[$TARGET]"
for k in "${!FOUND_PKGS[@]}"; do
    [[ "$k" == "${TARGET}-"* ]] && unset "FOUND_PKGS[$k]"
done


# =============================================================================
# SECTION 16 — OUTPUT: REQUIRED PACKAGES LIST
# =============================================================================

echo ""   # blank line for spacing
if [[ ${#FOUND_PKGS[@]} -eq 0 ]]; then
    echo "  ${YEL}No runtime dependencies found.${RST}"
else
    echo "${BLD}  Required Slackware packages (${#FOUND_PKGS[@]}):${RST}"
    echo ""
    for pkg in $(printf '%s\n' "${!FOUND_PKGS[@]}" | sort); do
        if [[ "$pkg" =~ ^([^-]+(-[^-]+)*)-([0-9][^-]*)-([^-]+)-([^-]+)$ ]]; then
            name="${BASH_REMATCH[1]}"
            printf "  ${GRN}%-35s${RST}  %s\n" "$name" "$pkg"
        else
            printf "  ${GRN}%s${RST}\n" "$pkg"
        fi
    done
fi


# =============================================================================
# SECTION 17 — OUTPUT: UNRESOLVED LIBRARIES (only shown with -u flag)
# =============================================================================

if [[ $SHOW_UNRESOLVED -eq 1 && ${#UNRES[@]} -gt 0 ]]; then

    echo ""
    echo "${BLD}  ${YEL}Unresolved shared libraries (${#UNRES[@]}):${RST}"
    echo "  ${YEL}(present at runtime but not owned by any indexed package)${RST}"
    echo ""
    for so in $(printf '%s\n' "${!UNRES[@]}" | sort); do

        printf "  ${YEL}  %s${RST}\n" "$so"
    done
fi

echo "${BLD}--------------------------------------------------------${RST}"

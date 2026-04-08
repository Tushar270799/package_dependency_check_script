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


set -euo pipefail

# ── Terminal colour codes ─────────────────────────────────────────────────────

RED=$'\e[1;31m'   
YEL=$'\e[1;33m'   
GRN=$'\e[1;32m'  
CYN=$'\e[1;36m'  
BLD=$'\e[1m'      
RST=$'\e[0m'     

# ── Helper functions ──────────────────────────────────────────────────────────

die()  { echo "${RED}ERROR:${RST} $*" >&2; exit 1; }

info() { echo "${CYN}::${RST} $*"; }

warn() { echo "${YEL}WARN:${RST}  $*" >&2; }

# ── Default option values ─────────────────────────────────────────────────────
RECURSIVE=0         
VERBOSE=0           
SHOW_UNRESOLVED=0  
PKG_DB="/var/log/packages"  
TMPDIR_WORK=""     

# ── usage(): print the Usage block from the script header and exit ────────────

usage() {
    sed -n '/^# Usage:/,/^# ====/p' "$0" | sed 's/^# \?//'
    exit 0
}

# ── Argument parsing ──────────────────────────────────────────────────────────
[[ $# -eq 0 ]] && usage   
POSITIONAL=()   

while [[ $# -gt 0 ]]; do
    case "$1" in
        -r|--recursive)  RECURSIVE=1 ;;
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

# ── Sanity checks: required external tools ────────────────────────────────────

command -v ldd  &>/dev/null || die "'ldd' not found. Is glibc installed?"
command -v file &>/dev/null || die "'file' not found. Is file(1) installed?"

[[ -d "$PKG_DB" ]] || die "Package database not found at $PKG_DB"

# ── Build the shared-library → package reverse lookup map ────────────────────

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

        # ── Inside FILE LIST ──────────────────────────────────────────────────

        [[ "$line" == */ ]] && continue    
        
        stripped_line="${line#./}"            
        basename_line="${stripped_line##*/}"  

        if [[ "$basename_line" == *.so || "$basename_line" == *.so.* ]]; then

            SO_OWNER["$basename_line"]="$pkgname"

            
            sobase="${basename_line%%.so*}.so"  
    
            [[ "${SO_OWNER[$sobase]+_}" ]] || SO_OWNER["$sobase"]="$pkgname"
        fi

    done < "$pkgfile"   
done

info "Indexed ${#SO_OWNER[@]} shared library entries."


resolve_so() {
    local so="$1"
    local base
    base=$(basename "$so")   

    # ── Strategy 1: direct lookup ─────────────────────────────────────────────

    if [[ "${SO_OWNER[$base]+_}" ]]; then
        echo "${SO_OWNER[$base]}"
        return
    fi

    # ── Strategy 2: strip version suffixes ────────────────────────────────────

    local stripped="$base"
    while [[ "$stripped" == *.*.* ]]; do     
        stripped="${stripped%.*}"            
        [[ "${SO_OWNER[$stripped]+_}" ]] && { echo "${SO_OWNER[$stripped]}"; return; }
    done

    # ── Strategy 3: follow symlinks ───────────────────────────────────────────

    if [[ -f "$so" ]]; then
        local real
        real=$(readlink -f "$so" 2>/dev/null || echo "$so")  
        local realbase
        realbase=$(basename "$real")
        [[ "${SO_OWNER[$realbase]+_}" ]] && { echo "${SO_OWNER[$realbase]}"; return; }

        # ── Strategy 4: grep the raw DB ───────────────────────────────────────

        local rel_path="${so#/}"   
        local found
        found=$(grep -rl "^\.\?/${rel_path}$" "$PKG_DB" 2>/dev/null | head -1)
        [[ -n "$found" ]] && { basename "$found"; return; }
    fi

    echo ""  
}


elf_files_from_installed() {
    local pkgname="$1"
    local pkgfile=""

    # ── Exact match ───────────────────────────────────────────────────────────
    if [[ -f "$PKG_DB/$pkgname" ]]; then
        pkgfile="$PKG_DB/$pkgname"
    else
        # ── Fuzzy/glob match ──────────────────────────────────────────────────
        local matches=( "$PKG_DB/${pkgname}"-[0-9]* )
        pkgfile=""
        local m
        for m in "${matches[@]}"; do
            [[ -f "$m" ]] && { pkgfile="$m"; break; }  
        done

        if [[ -z "$pkgfile" ]]; then
            warn "Package '$pkgname' is not installed (not found in $PKG_DB)"
            return 1  
        fi
    fi

    # ── Walk the FILE LIST section ────────────────────────────────────────────
    local in_list=0
    while IFS= read -r line; do
        if [[ $in_list -eq 0 ]]; then
            [[ "$line" == "FILE LIST:" ]] && in_list=1
            continue
        fi


        [[ "$line" == */ ]] && continue


        local abs="/${line#./}"

 
        [[ -f "$abs" ]] || continue

        file -b "$abs" 2>/dev/null | grep -q "^ELF" && echo "$abs"

    done < "$pkgfile"
}


elf_files_from_tgz() {
    local pkgfile="$1"

    TMPDIR_WORK=$(mktemp -d /tmp/slack-deps.XXXXXX)
    info "Extracting package to $TMPDIR_WORK …"

    tar -xf "$pkgfile" -C "$TMPDIR_WORK" 2>/dev/null || \
        die "Failed to extract $pkgfile — is it a valid Slackware package?"

    find "$TMPDIR_WORK" -type f -exec sh -c \
        'file -b "$1" 2>/dev/null | grep -q "^ELF" && echo "$1"' _ {} \;
}

# ── pkg_for_binary(): reverse-lookup which package owns a given binary ────────

pkg_for_binary() {
    local bin="$1"
    local abspath=""

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
        echo "$abspath"               
        echo "$(basename "$pkgfile")" 
        return 0
    fi

    return 1   
}

# ── Cleanup trap ──────────────────────────────────────────────────────────────

cleanup() { [[ -n "$TMPDIR_WORK" ]] && rm -rf "$TMPDIR_WORK"; }
trap cleanup EXIT

# ── Input mode detection ──────────────────────────────────────────────────────

declare -a ELF_FILES=()   
PKG_LABEL="$TARGET"       

if [[ -f "$TARGET" && "$TARGET" == *.t?z ]]; then

    info "Mode: package file  →  $TARGET"
    mapfile -t ELF_FILES < <(elf_files_from_tgz "$TARGET")

elif [[ -f "$TARGET" ]] || command -v "$TARGET" &>/dev/null; then

    info "Mode: binary  →  $TARGET"

    local_result=$(pkg_for_binary "$TARGET") || true

    if [[ -n "$local_result" ]]; then
        abspath=$(echo "$local_result" | head -1)   
        owner_pkg=$(echo "$local_result" | tail -1) 
        PKG_LABEL="$TARGET  (package: $owner_pkg)"

\\        if file -b "$abspath" 2>/dev/null | grep -q "^ELF"; then
            ELF_FILES=( "$abspath" )
        else
            die "'$abspath' is not an ELF binary (it may be a shell script or text file)"
        fi
    else
        die "Could not find '$TARGET' in any installed package."
    fi

else
    # ── Mode 3: installed package name ───────────────────────────────────────
\    info "Mode: installed package  →  $TARGET"
\\    mapfile -t ELF_FILES < <(elf_files_from_installed "$TARGET" || true)
fi

# ── Guard: we must have at least one ELF to analyse ──────────────────────────
if [[ ${#ELF_FILES[@]} -eq 0 ]]; then
    die "No ELF binaries found for '$TARGET'.
       If '$TARGET' is a command (like ls, mkdir), it should be auto-detected.
       Otherwise pass the owning package name (e.g. coreutils, util-linux)."
fi
info "Found ${#ELF_FILES[@]} ELF file(s) to inspect."

# ── Global result maps ────────────────────────────────────────────────────────

declare -A FOUND_PKGS=()  
declare -A UNRES=()       

# ── collect_deps_for_elfs(): core dependency analysis function ────────────────

collect_deps_for_elfs() {
    local elf
    while IFS= read -r elf; do
        [[ -z "$elf" ]] && continue   

        local ldd_out
        ldd_out=$(ldd "$elf" 2>/dev/null) || true
        [[ -z "$ldd_out" ]] && continue  

        while IFS= read -r line; do

            # ── Lines to skip ─────────────────────────────────────────────────

            [[ "$line" == *"linux-vdso"* ]]       && continue

            [[ "$line" == *"not a dynamic"* ]]     && continue

            [[ "$line" == *"statically linked"* ]] && continue

            # ── Parse the library line ────────────────────────────────────────
            local soname="" sopath=""


            if [[ "$line" =~ [[:space:]]([^[:space:]]+)[[:space:]]+\=\>[[:space:]]+([^[:space:]]+) ]]; then
                soname="${BASH_REMATCH[1]}"   
                sopath="${BASH_REMATCH[2]}"   
                [[ "$sopath" == "(0x"* ]] && sopath=""

            elif [[ "$line" =~ ^[[:space:]]+(/[^[:space:]]+) ]]; then
                sopath="${BASH_REMATCH[1]}"   
                soname="${sopath##*/}"       
            else
                continue  
            fi

            [[ -z "$soname" ]] && continue

            # ── Resolve .so to its owning package ─────────────────────────────
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

# ── Print output header ───────────────────────────────────────────────────────
echo ""
echo "${BLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RST}"
echo "${BLD} Runtime dependencies for: ${CYN}${PKG_LABEL}${RST}"
echo "${BLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RST}"
[[ $VERBOSE -eq 1 ]] && echo ""

# ── First pass: direct (immediate) dependencies ───────────────────────────────

collect_deps_for_elfs < <(printf '%s\n' "${ELF_FILES[@]}")


unset "FOUND_PKGS[$TARGET]"
for k in "${!FOUND_PKGS[@]}"; do
    [[ "$k" == "${TARGET}-"* ]] && unset "FOUND_PKGS[$k]"
done

# ── Optional recursive pass: full transitive dependency tree ──────────────────

if [[ $RECURSIVE -eq 1 && ${#FOUND_PKGS[@]} -gt 0 ]]; then
    info "Resolving transitive dependencies…"

    declare -A ALL_PKGS=()
    for p in "${!FOUND_PKGS[@]}"; do ALL_PKGS["$p"]=1; done

    declare -a bfs_queue=("${!FOUND_PKGS[@]}")

    declare -A visited=()

    while [[ ${#bfs_queue[@]} -gt 0 ]]; do
        current="${bfs_queue[0]}"
        bfs_queue=("${bfs_queue[@]:1}")

        [[ "${visited[$current]+_}" ]] && continue
        visited["$current"]=1

        mapfile -t sub_elfs < <(elf_files_from_installed "$current" 2>/dev/null || true)
        [[ ${#sub_elfs[@]} -eq 0 ]] && continue
        collect_deps_for_elfs < <(printf '%s\n' "${sub_elfs[@]}")
        for p in "${!FOUND_PKGS[@]}"; do
            [[ "${ALL_PKGS[$p]+_}" ]] || bfs_queue+=("$p")
            ALL_PKGS["$p"]=1
        done
    done
    for p in "${!ALL_PKGS[@]}"; do FOUND_PKGS["$p"]=1; done
fi

# ── Output section: required packages ────────────────────────────────────────
echo ""
if [[ ${#FOUND_PKGS[@]} -eq 0 ]]; then
    echo "  ${YEL}No runtime dependencies found.${RST}"
else
    echo "${BLD}  Required Slackware packages (${#FOUND_PKGS[@]}):${RST}"
    echo ""

    for pkg in $(printf '%s\n' "${!FOUND_PKGS[@]}" | sort); do

        if [[ "$pkg" =~ ^([^-]+(-[^-]+)*)-([0-9][^-]*)-([^-]+)-([^-]+)$ ]]; then
            name="${BASH_REMATCH[1]}"   # base name only (e.g. "glibc")
            printf "  ${GRN}%-35s${RST}  %s\n" "$name" "$pkg"
        else
            printf "  ${GRN}%s${RST}\n" "$pkg"
        fi
    done
fi

# ── Output section: unresolved libraries (shown only with -u) ─────────────────
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

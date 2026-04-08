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


# =============================================================================
# SECTION 1 — SHELL SAFETY OPTIONS
# =============================================================================
# These three options make the script "strict" so bugs cannot hide silently.
# They are set at the very top so ALL code below runs with these protections.
#
# Without these options, a broken command would be silently ignored and the
# script would keep running with wrong/empty data — hard to debug.
# With these options, the script stops immediately when anything goes wrong.
# =============================================================================

# set        = built-in bash command to change shell behaviour options
# -e         = Exit immediately if ANY command fails (returns non-zero exit code)
#              Example: if "grep something file" finds nothing, exit code = 1
#              Without -e: script ignores this and keeps running
#              With    -e: script stops right there
# -u         = Treat UNSET (undefined) variables as errors
#              Example: if you type $PAKGNAME instead of $PKGNAME (typo),
#              Without -u: $PAKGNAME silently becomes empty string ""
#              With    -u: script immediately dies with "unbound variable" error
# -o         = Set an option by name (used with option name that follows)
# pipefail   = In a pipeline (cmd1 | cmd2 | cmd3), if ANY command fails,
#              the WHOLE pipeline is considered failed
#              Without pipefail: "false | true" succeeds (only last cmd matters)
#              With    pipefail: "false | true" FAILS  (false failed = pipeline failed)
set -euo pipefail


# =============================================================================
# SECTION 2 — TERMINAL COLOUR CODES
# =============================================================================
# These are ANSI escape sequences — special character codes that terminals
# understand as "change colour" or "change style" instructions.
#
# FORMAT OF EACH CODE:
#   $'\e[  = start of escape sequence (\e = ESC character, [ = opens the code)
#   1;     = bold (1 = bold, separated by ; from colour number)
#   31m'   = colour number followed by m (m = end of the code)
#            31=red, 32=green, 33=yellow, 36=cyan
#
# HOW TO USE THEM:
#   echo "${RED}This is red text${RST} and this is normal"
#   The RST at the end is CRITICAL — without it, ALL text after stays coloured
#
# COLOUR NUMBERS REFERENCE:
#   30=black  31=red  32=green  33=yellow  34=blue  35=magenta  36=cyan  37=white
# =============================================================================

# $'...'  = special bash quoting that interprets escape sequences like \e
# \e      = the ESC character (ASCII 27) that starts terminal control codes
# [1;31m  = bold (1) + red foreground (31)
RED=$'\e[1;31m'   # bold red    — used for: fatal ERROR messages

# [1;33m  = bold (1) + yellow foreground (33)
YEL=$'\e[1;33m'   # bold yellow — used for: WARN messages and unresolved items

# [1;32m  = bold (1) + green foreground (32)
GRN=$'\e[1;32m'   # bold green  — used for: package names in the output list

# [1;36m  = bold (1) + cyan foreground (36)
CYN=$'\e[1;36m'   # bold cyan   — used for: the ":: " status/progress lines

# [1m     = bold only, no colour change
BLD=$'\e[1m'      # bold only   — used for: section headers and counts

# [0m     = reset ALL styling back to normal (no colour, no bold)
# This MUST appear at the end of every coloured string to stop the colour
RST=$'\e[0m'      # reset all   — must follow every coloured string


# =============================================================================
# SECTION 3 — HELPER FUNCTIONS (die, info, warn)
# =============================================================================
# These are tiny utility functions used throughout the entire script.
# Defined early (before everything else) so all code below can call them.
#
# In Bash, a "function" is just a named block of commands you can call by name.
# Functions must be DEFINED before they are CALLED (top-to-bottom execution).
# =============================================================================

# die() — Print a fatal error message and EXIT the script immediately
#
# SYNTAX:   die "your error message here"
# EXAMPLE:  die "Package not found"
#           outputs:  ERROR: Package not found   (in bold red, to stderr)
#           then exits with code 1 (standard "failure" exit code)
#
# $*       = all arguments joined into one string
#            if called as: die "file" "not" "found"
#            then $* = "file not found"
# >&2      = redirect output to stderr (file descriptor 2)
#            stderr is separate from stdout so errors don't mix with normal output
#            when user does: ./script.sh > output.txt
#            stdout goes to file, but errors still appear on screen
# exit 1   = terminate the script with exit code 1 (1 = failure in Unix)
die()  { echo "${RED}ERROR:${RST} $*" >&2; exit 1; }

# info() — Print a cyan status/progress line to stdout
#
# SYNTAX:   info "message"
# EXAMPLE:  info "Building map..."
#           outputs:  :: Building map...   (:: in cyan, rest in default colour)
#
# The ":: " prefix is a convention borrowed from Arch Linux's pacman package
# manager — it visually marks these as informational progress messages
info() { echo "${CYN}::${RST} $*"; }

# warn() — Print a yellow warning message to stderr (but DO NOT exit)
#
# SYNTAX:   warn "message"
# EXAMPLE:  warn "Package not found"
#           outputs:  WARN:  Package not found   (in bold yellow, to stderr)
#
# Unlike die(), warn() lets the script CONTINUE running after the warning
# Used when something is missing but we can still keep going
warn() { echo "${YEL}WARN:${RST}  $*" >&2; }


# =============================================================================
# SECTION 4 — DEFAULT OPTION VALUES
# =============================================================================
# These variables store the state of command-line flags.
# They all start at their DEFAULT values here.
# The argument parser (Section 6) may change them based on what user typed.
#
# Naming convention: UPPERCASE = global script variables (common Bash style)
# =============================================================================

# VERBOSE: controls whether to show each individual .so → package mapping
# 0 = off (default) = only show the final package list
# 1 = on  (set by -v flag) = also show each "libfoo.so → packagename" line
VERBOSE=0

# SHOW_UNRESOLVED: controls whether to show .so files with no known package owner
# 0 = off (default) = silently ignore unresolved libraries
# 1 = on  (set by -u flag) = list them at the bottom with a warning symbol
SHOW_UNRESOLVED=0

# PKG_DB: the directory where Slackware stores its package database
# Each installed package has ONE plain text file here named after the package
# Example: /var/log/packages/glibc-2.34-x86_64-1
#          /var/log/packages/htop-3.2.1-x86_64-2
#          /var/log/packages/ncurses-6.3-x86_64-1
# Each file contains: package metadata at top, then "FILE LIST:" section,
# then one line per file that the package installed on your disk
PKG_DB="/var/log/packages"

# TMPDIR_WORK: path to a temporary directory used when extracting .txz files
# Starts EMPTY — only gets a real path if user passes a .txz/.tgz file
# The cleanup() function (Section 9) uses this to delete the temp dir on exit
TMPDIR_WORK=""


# =============================================================================
# SECTION 5 — USAGE FUNCTION
# =============================================================================
# Shows the help text (taken from the script's own header comments) and exits.
# Called when user passes -h/--help, or when no arguments are given at all.
# =============================================================================

usage() {
    # sed    = stream editor — processes text line by line
    # -n     = suppress default output (only print what we explicitly say to print)
    # '/.../,/.../p' = print lines FROM first pattern TO second pattern (inclusive)
    # /^# Usage:/    = line that starts with "# Usage:"
    # /^# ====/      = line that starts with "# ===="  (the closing separator)
    # "$0"           = the script's own filename/path
    # So this reads the script file itself and extracts the usage block from the header
    sed -n '/^# Usage:/,/^# ====/p' "$0" | sed 's/^# \?//'
    # Second sed: 's/^# \?//' removes the leading "# " from each comment line
    # s/     = substitute
    # ^      = start of line
    # # \?   = literal # followed by optional space (\? = zero or one space)
    # //     = replace with nothing (delete the match)
    exit 0
}


# =============================================================================
# SECTION 6 — ARGUMENT PARSING
# =============================================================================
# Reads what the user typed on the command line and sets the appropriate flags.
#
# Command line arguments come in two types:
#   OPTIONS:     start with - or -- like: -v, --verbose, --help
#   POSITIONAL:  everything else like: htop, /usr/bin/ls, /tmp/pkg.txz
#
# This section loops through ALL arguments, processes options (setting flags),
# and collects positional arguments into the POSITIONAL array.
# =============================================================================

# $#          = special variable: NUMBER of arguments passed to the script
# -eq 0       = "equals zero" (arithmetic comparison, -eq = equal)
# &&           = AND: only run right side if left side is true
# usage        = call the usage() function defined above
# If user ran "./script.sh" with nothing after it → show help and exit
[[ $# -eq 0 ]] && usage

# POSITIONAL = indexed array to collect non-option arguments
# ()          = empty array literal
# These will be things like "htop", "/usr/bin/ls", "/tmp/pkg.txz"
POSITIONAL=()

# while [[ $# -gt 0 ]]  = keep looping while there are still arguments left
# $#                     = count of remaining arguments
# -gt 0                  = greater than zero
while [[ $# -gt 0 ]]; do

    # case "$1" in ... esac = match the FIRST remaining argument against patterns
    # "$1"                  = the current first argument
    # Each pattern ends with ) and the commands end with ;;
    case "$1" in

        # -v or --verbose: user wants to see each .so → package mapping
        # Set VERBOSE flag to 1 (on)
        -v|--verbose)    VERBOSE=1 ;;

        # -u or --unresolved: user wants to see libraries with no known owner
        # Set SHOW_UNRESOLVED flag to 1 (on)
        -u|--unresolved) SHOW_UNRESOLVED=1 ;;

        # -h or --help: user wants to see usage instructions
        # Call usage() which prints help and exits
        -h|--help)       usage ;;

        # -*  = any argument starting with - that we don't recognise
        # This catches typos like --recusive or unknown flags like -x
        # die() prints error and exits the script
        -*)              die "Unknown option: $1" ;;

        # *   = anything that doesn't start with - (a positional argument)
        # +=  = append to array
        # ("$1") = append current argument as a new array element
        *)               POSITIONAL+=("$1") ;;

    esac

    # shift = "consume" the current $1 by shifting all arguments left
    # Before shift: $1="-v"  $2="htop"  $3=...
    # After  shift: $1="htop" $2=...
    # This is how the while loop advances through all arguments one by one
    shift
done

# After the loop, check we got at least one positional argument
# ${#POSITIONAL[@]} = number of elements in POSITIONAL array
# -eq 0             = equals zero (array is empty)
# If empty, user only gave options but no target — that's an error
[[ ${#POSITIONAL[@]} -eq 0 ]] && die "No target specified. Use -h for help."

# TARGET = the thing we want to find dependencies for
# POSITIONAL[0] = first (and usually only) element of the POSITIONAL array
# (index 0 = first element in Bash arrays)
TARGET="${POSITIONAL[0]}"


# =============================================================================
# SECTION 7 — SANITY CHECKS
# =============================================================================
# Before doing any real work, verify that required tools and directories exist.
# Fail early with a helpful message rather than failing mysteriously later.
# =============================================================================

# command -v ldd   = check if "ldd" command exists anywhere in $PATH
# &>/dev/null      = discard BOTH stdout and stderr (& means both streams)
# ||               = OR: if the left side FAILS (ldd not found), run right side
# die "..."        = print error and exit
#
# ldd = "list dynamic dependencies" — a tool that reads an ELF binary and
# prints all the .so shared library files it requires at runtime
# It is part of glibc (the C library package)
command -v ldd  &>/dev/null || die "'ldd' not found. Is glibc installed?"

# Same check for the "file" command
# file = a tool that identifies what TYPE a file is by reading its content
# (not by its extension — it reads the actual bytes, called "magic bytes")
# Example output: "ELF 64-bit LSB executable, x86-64..."
#                 "POSIX shell script, ASCII text executable"
# file is part of the "file" package
command -v file &>/dev/null || die "'file' not found. Is file(1) installed?"

# -d "$PKG_DB" = test if the path exists AND is a DIRECTORY (not a file)
# || die       = if it doesn't exist, print error and exit
# This confirms Slackware's package database directory is present
# Without this directory, we cannot look up which package owns which .so file
[[ -d "$PKG_DB" ]] || die "Package database not found at $PKG_DB"


# =============================================================================
# SECTION 8 — BUILD THE .so → PACKAGE REVERSE LOOKUP MAP
# =============================================================================
# This is the MOST IMPORTANT preparation step. Before we can answer
# "which package provides libfoo.so?", we need to build a lookup table
# that maps every known .so filename to its package.
#
# HOW IT WORKS:
#   - Loop through EVERY file in /var/log/packages/ (one file per package)
#   - Each file is a plain text file with this structure:
#       PACKAGE NAME:     glibc-2.34-x86_64-1
#       COMPRESSED PACKAGE SIZE:  4200K
#       ...more metadata...
#       FILE LIST:
#       ./
#       ./usr/
#       ./usr/lib64/
#       ./usr/lib64/libc.so.6
#       ./usr/lib64/libm.so.6
#       ...more files...
#   - Find every line in FILE LIST that ends in .so or .so.X.Y.Z
#   - Store it in SO_OWNER map: SO_OWNER["libc.so.6"] = "glibc-2.34-x86_64-1"
#
# RESULT: a hash map SO_OWNER where:
#   Key   = library filename like "libc.so.6" or "libncurses.so.6"
#   Value = package record name like "glibc-2.34-x86_64-1"
# =============================================================================

info "Building shared-library → package map (this may take a moment)…"

# declare   = explicitly declare a variable with a specific type
# -A        = Associative array (hash map — uses string keys, not just numbers)
# SO_OWNER  = name of our map
# =()       = initialize as empty
#
# Normal (indexed) array:   declare -a myarray=()   → keys are 0,1,2,3...
# Associative array:        declare -A mymap=()     → keys are any strings
#
# Usage example:
#   SO_OWNER["libc.so.6"]="glibc-2.34-x86_64-1"   (store)
#   echo ${SO_OWNER["libc.so.6"]}                   (retrieve)
declare -A SO_OWNER=()

# Loop through every entry in the package database directory
# "$PKG_DB"/* = glob pattern: /var/log/packages/* = all files AND dirs inside
# pkgfile     = loop variable, gets the full path of each entry
for pkgfile in "$PKG_DB"/*; do

    # -f "$pkgfile" = test: is this a regular FILE? (not a directory, not a symlink)
    # ||            = OR
    # continue      = skip to next iteration of the for loop
    # Some entries in /var/log/packages might be subdirectories — skip them
    [[ -f "$pkgfile" ]] || continue

    # basename = extract just the filename from a full path
    # Example: basename "/var/log/packages/glibc-2.34-x86_64-1"
    #          output:  "glibc-2.34-x86_64-1"
    # This IS the package name in Slackware — the filename = the package name
    pkgname=$(basename "$pkgfile")

    # in_filelist = a flag (counter) to track where we are inside the package file
    # 0 = we are still reading the metadata header section
    # 1 = we have passed the "FILE LIST:" marker and are now reading file paths
    in_filelist=0

    # Read the package file line by line
    # while              = keep looping while the read command succeeds
    # IFS=               = set Internal Field Separator to EMPTY
    #                      This preserves leading/trailing whitespace in lines
    #                      Without this, spaces at line start would be stripped
    # read               = read one line from stdin into a variable
    # -r                 = raw mode: backslashes are treated as literal characters
    #                      Without -r, "\n" in a line would be interpreted as newline
    # line               = variable name to store the current line
    # done < "$pkgfile"  = at the END of the while block, redirect the file as input
    #                      This feeds the file's content line by line into "read"
    #                      Equivalent to: cat "$pkgfile" | while ... (but safer)
    while IFS= read -r line; do

        if [[ $in_filelist -eq 0 ]]; then
            # We are in the metadata section — skip everything UNTIL we see "FILE LIST:"
            #
            # [[ "$line" == "FILE LIST:" ]] = exact string match (== not regex)
            # &&                             = AND: only run right side if match found
            # in_filelist=1                  = flip the flag to "now inside file list"
            [[ "$line" == "FILE LIST:" ]] && in_filelist=1

            # continue = skip the rest of this loop iteration, go to next line
            # This skips metadata lines AND the "FILE LIST:" line itself
            # (the "FILE LIST:" line is a marker, not a real file path)
            continue
        fi

        # ── We are now INSIDE the FILE LIST section ───────────────────────────

        # Skip directory entries — lines ending with / are directories not files
        # "$line" == */   = does line end with "/"?
        # *               = wildcard meaning "anything before"
        # /               = literal slash at the end
        # && continue     = if it's a directory line, skip to next iteration
        # Example lines to skip: "./"  "./usr/"  "./usr/lib64/"
        [[ "$line" == */ ]] && continue

        # Strip the leading "./" from the path
        # ${line#./}  = remove the shortest match of "./" from the START of $line
        # #           = strip prefix operator
        # ./          = the prefix to remove
        # Example:  "./usr/lib64/libc.so.6"  →  "usr/lib64/libc.so.6"
        stripped_line="${line#./}"

        # Get just the FILENAME part (basename) — remove all directory components
        # ${stripped_line##*/}  = remove the LONGEST match of "*/" from the START
        # ##                    = greedy strip prefix (removes as much as possible)
        # */                    = any characters followed by a slash
        # Example:  "usr/lib64/libc.so.6"  →  "libc.so.6"
        #           "usr/bin/htop"          →  "htop"
        basename_line="${stripped_line##*/}"

        # Check if this file is a shared library (.so file)
        # *.so    = filename ends with exactly ".so"     (e.g. "libfoo.so")
        # *.so.*  = filename contains ".so." somewhere   (e.g. "libfoo.so.1.2.3")
        # ||      = OR: match either pattern
        if [[ "$basename_line" == *.so || "$basename_line" == *.so.* ]]; then

            # Store the FULL versioned name in the map
            # Key   = "libc.so.6"             (the library filename)
            # Value = "glibc-2.34-x86_64-1"   (the package that owns it)
            # If two packages have the same .so name, the LAST one processed wins
            # (later package in filesystem order overwrites earlier one)
            SO_OWNER["$basename_line"]="$pkgname"

            # Also store the UNVERSIONED base name (e.g. "libc.so" without ".6")
            # This helps resolve lookups that use the base name instead of full name
            #
            # %%.so*  = strip from ".so" to the END (greedy from left with %%)
            # .so     = re-append ".so" to get the base name
            # Example: "libfoo.so.1.2.3" → strip ".so.1.2.3" → "libfoo" → append ".so" → "libfoo.so"
            #          "libbar.so.6"     → strip ".so.6"      → "libbar" → append ".so" → "libbar.so"
            sobase="${basename_line%%.so*}.so"

            # Only store the base name if it's NOT already in the map
            # ${SO_OWNER[$sobase]+_}  = check if key exists in associative array
            #   If key EXISTS:     expands to "_" (truthy, non-empty)
            #   If key NOT exist:  expands to ""  (falsy, empty)
            # [[ ... ]]            = test: is the result truthy?
            # ||                   = OR: only run right side if test FAILED (key not found)
            # SO_OWNER["$sobase"]="$pkgname"  = store the base name → package mapping
            #
            # This means: "first package to provide libfoo.so wins"
            # Prevents overwriting if another package also provides the same base name
            [[ "${SO_OWNER[$sobase]+_}" ]] || SO_OWNER["$sobase"]="$pkgname"
        fi

    done < "$pkgfile"   # ← THIS is where the file gets opened and read
                         # The redirection < feeds pkgfile into the while loop's stdin
done

# Report how many entries were indexed
# ${#SO_OWNER[@]} = the COUNT of keys in the SO_OWNER associative array
# #               = "give me the length/count"
# [@]             = all elements
info "Indexed ${#SO_OWNER[@]} shared library entries."


# =============================================================================
# SECTION 8a — FUNCTION: resolve_so()
# =============================================================================
# Given a .so filename or path, find which installed package owns it.
# Returns the package name by printing it to stdout (empty string if not found).
#
# Tries 4 strategies in order, from fastest to slowest:
#   1. Direct lookup in SO_OWNER map (instant hash map lookup)
#   2. Strip version suffixes one by one and retry (libfoo.so.1.2 → libfoo.so.1 → libfoo.so)
#   3. Follow symlinks to find the real file, then look up its real name
#   4. Grep the raw package database files (slowest, last resort)
#
# WHY 4 STRATEGIES?
#   ldd might give us "libfoo.so.1.2.3" but the package database only has "libfoo.so.1"
#   Or ldd gives a symlink path but the package records the real file
#   These fallbacks handle all these edge cases
# =============================================================================

resolve_so() {
    # $1 = first argument = the .so name or path to look up
    # local = variable only exists inside this function, destroyed when function returns
    local so="$1"

    # base = just the filename part (no directory)
    # basename "$so" strips the directory prefix
    # Example: "/lib64/libc.so.6" → "libc.so.6"
    #          "libc.so.6"        → "libc.so.6" (already just filename, no change)
    local base
    base=$(basename "$so")

    # ── Strategy 1: Direct lookup in the SO_OWNER map ─────────────────────────
    # Try the exact filename as-is first — fastest possible lookup
    #
    # ${SO_OWNER[$base]+_}  = test if key "$base" exists in SO_OWNER array
    #   Syntax: ${array[key]+word}
    #   If key EXISTS:     substitute "word" (here: "_")  → truthy
    #   If key NOT exist:  substitute nothing ""           → falsy
    # This is the standard Bash idiom to test key existence in associative arrays
    if [[ "${SO_OWNER[$base]+_}" ]]; then
        # echo = print the package name to stdout
        # The CALLER captures this with: owner=$(resolve_so "libfoo.so")
        echo "${SO_OWNER[$base]}"
        return   # return = exit function immediately (success, exit code 0)
    fi

    # ── Strategy 2: Strip version suffixes one by one ─────────────────────────
    # Try progressively shorter names:
    # "libfoo.so.1.2.3" → try → "libfoo.so.1.2" → try → "libfoo.so.1" → try → done
    #
    local stripped="$base"   # start with full name, will shorten each iteration

    # "$stripped" == *.*.*  = does the string contain at least TWO dots?
    # *     = any characters
    # .     = literal dot
    # This condition means "there are still version numbers to strip"
    # Example: "libfoo.so.1.2.3" has 3 dots → matches (keep stripping)
    #          "libfoo.so.1"     has 2 dots → matches (keep stripping)
    #          "libfoo.so"       has 1 dot  → does NOT match (stop)
    while [[ "$stripped" == *.*.* ]]; do

        # ${stripped%.*}  = remove the SHORTEST match of ".*" from the END
        # %               = strip suffix operator (removes from end)
        # .*              = a dot followed by anything
        # Example: "libfoo.so.1.2.3" → remove ".3"    → "libfoo.so.1.2"
        #          "libfoo.so.1.2"   → remove ".2"    → "libfoo.so.1"
        stripped="${stripped%.*}"

        # Check if this shorter name is in the map
        # && { ...; return; }  = if found, print result and exit function
        # The { } groups multiple commands to execute together after &&
        [[ "${SO_OWNER[$stripped]+_}" ]] && { echo "${SO_OWNER[$stripped]}"; return; }
    done

    # ── Strategy 3: Follow symlinks ───────────────────────────────────────────
    # Many .so files are symlinks. Example:
    #   /lib64/libm.so.6 → /lib64/libm-2.34.so  (symlink to real file)
    # The package database might record the real filename, not the symlink name
    # So we follow the symlink to find the real file and look that up instead
    #
    # -f "$so"  = test if $so is a regular file that actually exists on disk
    # Only try symlink resolution if the file actually exists
    if [[ -f "$so" ]]; then

        # readlink -f  = resolve the FULL chain of symlinks to the real file
        # -f           = follow all symlinks recursively to the final destination
        # 2>/dev/null  = suppress error if readlink fails
        # || echo "$so" = if readlink fails, use the original path as fallback
        local real
        real=$(readlink -f "$so" 2>/dev/null || echo "$so")

        # Get just the filename of the real file
        local realbase
        realbase=$(basename "$real")

        # Look up the real filename in the map
        [[ "${SO_OWNER[$realbase]+_}" ]] && { echo "${SO_OWNER[$realbase]}"; return; }

        # ── Strategy 4: Grep the raw package database ─────────────────────────
        # Last resort — search through the actual package files with grep
        # This is SLOW (reads many files) but catches anything the map missed
        #
        # ${so#/}   = remove the leading "/" from the path
        # #         = strip prefix operator
        # /         = the prefix to remove
        # Example: "/lib64/libc.so.6" → "lib64/libc.so.6"
        # We need the relative path because package files store paths as "./lib64/..."
        local rel_path="${so#/}"

        # found = variable to hold the result of the grep search
        local found

        # grep -rl "pattern" directory  = search recursively, return filenames only
        # -r  = recursive: search inside every file in the directory
        # -l  = list: print only the FILENAME of matching files, not the matching lines
        # "^\.\?/${rel_path}$"  = the regex pattern to search for:
        #   ^       = start of line (line must begin with this)
        #   \.      = literal dot character (. in regex means "any char", \. means literal dot)
        #   \?      = the \. before it is OPTIONAL (zero or one dot)
        #   /       = literal slash
        #   ${rel_path}  = the path we're looking for (e.g. "lib64/libc.so.6")
        #   $       = end of line (nothing allowed after the path)
        # This matches both "./lib64/libc.so.6" and "/lib64/libc.so.6" in package files
        # 2>/dev/null  = discard any "permission denied" errors
        # | head -1    = take only the FIRST matching file (we just need one)
        found=$(grep -rl "^\.\?/${rel_path}$" "$PKG_DB" 2>/dev/null | head -1)

        # -n "$found"  = is found non-empty? (did grep find anything?)
        # && { basename "$found"; return; }
        #   basename "$found" = extract just the package name from the full path
        #   Example: "/var/log/packages/glibc-2.34-x86_64-1" → "glibc-2.34-x86_64-1"
        #   return = exit function after printing the result
        [[ -n "$found" ]] && { basename "$found"; return; }
    fi

    # All 4 strategies failed — print empty string
    # The caller checks: if [[ -z "$owner" ]]; then ... (empty = not found)
    echo ""
}


# =============================================================================
# SECTION 8b — FUNCTION: elf_files_from_installed()
# =============================================================================
# Given an installed package name, find all ELF binary files it installed.
# Prints one absolute file path per line to stdout.
#
# ELF files = compiled executables and shared libraries (the actual binaries)
# We need ELF files specifically because ldd only works on ELF files
# (not shell scripts, Python files, config files, etc.)
#
# The function handles TWO cases:
#   1. Exact name given:  "glibc-2.34-x86_64-1" (full versioned name)
#   2. Short name given:  "glibc" (just the base name, need to find the version)
# =============================================================================

elf_files_from_installed() {
    # $1 = first argument = the package name (exact or short)
    local pkgname="$1"

    # pkgfile will hold the full path to the package record file once found
    # Starts empty, gets set below
    local pkgfile=""

    # ── Try exact match first ─────────────────────────────────────────────────
    # Construct the full path and check if that exact file exists
    # Example: PKG_DB="var/log/packages", pkgname="glibc-2.34-x86_64-1"
    #          full path = "/var/log/packages/glibc-2.34-x86_64-1"
    if [[ -f "$PKG_DB/$pkgname" ]]; then
        pkgfile="$PKG_DB/$pkgname"   # exact match found, use it directly

    else
        # ── Try fuzzy/glob match ───────────────────────────────────────────────
        # User probably typed just "glibc" instead of "glibc-2.34-x86_64-1"
        # Use a glob pattern to find the versioned filename automatically
        #
        # local matches = declare array as local to this function
        # ( ... )       = array literal — Bash expands the glob into array elements
        # "$PKG_DB/${pkgname}"-[0-9]*  = glob pattern:
        #   $PKG_DB/    = "/var/log/packages/"
        #   ${pkgname}  = "glibc"
        #   -           = literal hyphen
        #   [0-9]       = any single DIGIT character (0,1,2,3,4,5,6,7,8,9)
        #   *           = any characters after
        # This matches: "glibc-2.34-x86_64-1" (starts with digit after "glibc-")
        # But NOT:      "glibc-solibs-2.34-x86_64-1" (starts with letter after "glibc-")
        # The [0-9] is clever — Slackware version numbers start with digits,
        # so this avoids matching "glibc-solibs" when searching for "glibc"
        #
        # IMPORTANT BASH BEHAVIOUR: If the glob matches NOTHING,
        # Bash puts the LITERAL glob string into the array instead of nothing!
        # Example: if no file matches, matches=( "/var/log/packages/glibc-[0-9]*" )
        # This is why we check -f below before using any match
        local matches=( "$PKG_DB/${pkgname}"-[0-9]* )

        pkgfile=""   # reset pkgfile to empty before the search loop
        local m      # loop variable (declared local to keep it inside function)

        # Loop through all glob matches and find the FIRST one that's a real file
        # "${matches[@]}"  = expand ALL elements of the matches array
        # @                = all elements
        # Quotes           = preserve spaces in filenames
        for m in "${matches[@]}"; do
            # -f "$m"  = is this element an actual file on disk?
            # This check filters out the literal unmatched glob string
            # && { pkgfile="$m"; break; }
            #   pkgfile="$m"  = save the found path
            #   break         = exit the for loop immediately (don't check more matches)
            #   { }           = group multiple commands together after &&
            [[ -f "$m" ]] && { pkgfile="$m"; break; }
        done

        # If pkgfile is STILL empty after the loop, package was not found at all
        # -z "$pkgfile"  = is pkgfile zero-length (empty)?
        if [[ -z "$pkgfile" ]]; then
            warn "Package '$pkgname' is not installed (not found in $PKG_DB)"
            return 1   # return 1 = signal FAILURE to whoever called this function
                        # The caller can check: function_call || handle_error
        fi
    fi

    # ── Walk the FILE LIST section of the found package file ──────────────────
    # Now we have the package record file. Read through it to find ELF files.

    local in_list=0   # flag: 0=in metadata, 1=in FILE LIST section

    while IFS= read -r line; do

        # Skip metadata lines until we reach "FILE LIST:" marker
        if [[ $in_list -eq 0 ]]; then
            [[ "$line" == "FILE LIST:" ]] && in_list=1
            continue   # skip this line (metadata or the marker itself)
        fi

        # Inside FILE LIST — skip directory entries (lines ending with /)
        [[ "$line" == */ ]] && continue

        # Build the absolute path from the relative path in the package file
        # ${line#./}  = strip leading "./" from the path
        # "/"${...}   = prepend "/" to make it an absolute path
        # Example: "./usr/bin/htop" → strip "./" → "usr/bin/htop" → prepend "/" → "/usr/bin/htop"
        local abs="/${line#./}"

        # Verify the file actually exists on disk right now
        # (Package records can list files that were deleted or never installed)
        # -f "$abs"  = is this a real file?
        # || continue = if NOT a real file, skip to next line
        [[ -f "$abs" ]] || continue

        # Check if this file is an ELF binary using the "file" command
        # file -b "$abs"    = identify file type, -b = brief (no filename prefix)
        # 2>/dev/null       = discard any errors from file command
        # | grep -q "^ELF"  = does output START with "ELF"?
        #   -q = quiet: don't print anything, just set exit code (0=found, 1=not found)
        #   ^ = start of line
        # && echo "$abs"    = if it IS an ELF, print its absolute path to stdout
        # The caller collects these printed paths into an array
        file -b "$abs" 2>/dev/null | grep -q "^ELF" && echo "$abs"

    done < "$pkgfile"   # feed the package record file into the while loop
}


# =============================================================================
# SECTION 8c — FUNCTION: elf_files_from_tgz()
# =============================================================================
# Given a .txz/.tgz package FILE (not yet installed), extract it to a temp
# directory and find all ELF binaries inside.
# Used when user passes a package file path like /tmp/curl-7.88-x86_64-1.txz
# =============================================================================

elf_files_from_tgz() {
    # $1 = first argument = path to the .txz/.tgz package file
    local pkgfile="$1"

    # mktemp -d = create a NEW unique temporary directory safely
    # -d        = create a directory (not just a file)
    # /tmp/slack-deps.XXXXXX = template: XXXXXX gets replaced with random characters
    # Example result: /tmp/slack-deps.aB3xYz
    # This is stored in TMPDIR_WORK (a GLOBAL variable, not local)
    # It's global so the cleanup() function can find and delete it on exit
    TMPDIR_WORK=$(mktemp -d /tmp/slack-deps.XXXXXX)
    info "Extracting package to $TMPDIR_WORK …"

    # tar = tape archive tool — used to extract compressed archives
    # -x  = extract (unpack the archive)
    # -f  = file: specify the archive file to work with
    # "$pkgfile"  = path to the .txz/.tgz archive
    # -C  = change to this directory before extracting
    # "$TMPDIR_WORK"  = our temp directory (extract files here, not current dir)
    # 2>/dev/null  = discard warning messages during extraction
    # || \         = backslash = line continuation (command continues on next line)
    #    die "..."  = if tar fails, print error and exit
    tar -xf "$pkgfile" -C "$TMPDIR_WORK" 2>/dev/null || \
        die "Failed to extract $pkgfile — is it a valid Slackware package?"

    # find all ELF files inside the extracted temp directory
    # find "$TMPDIR_WORK"  = start searching from this directory
    # -type f              = only find regular FILES (not directories, not symlinks)
    # -exec sh -c '...' _ {} \;  = for each found file, run this shell command
    #   sh -c '...'  = run a one-line shell script
    #   _            = placeholder for $0 (the script name, conventionally "_")
    #   {}           = replaced by find with each found file's path
    #   \;           = end the -exec expression (must be escaped or quoted)
    #
    # Inside the sh -c command:
    #   "$1"                    = the file path passed by find (via {})
    #   file -b "$1"            = identify file type
    #   2>/dev/null             = discard errors
    #   | grep -q "^ELF"        = is it an ELF file?
    #   && echo "$1"            = if yes, print the path to stdout
    find "$TMPDIR_WORK" -type f -exec sh -c \
        'file -b "$1" 2>/dev/null | grep -q "^ELF" && echo "$1"' _ {} \;
}


# =============================================================================
# SECTION 8d — FUNCTION: pkg_for_binary()
# =============================================================================
# Given a binary name or path, find:
#   1. Its absolute path on disk
#   2. Which installed package owns it
#
# Prints TWO lines to stdout:
#   Line 1: absolute path  (e.g. /usr/bin/htop)
#   Line 2: package name   (e.g. htop-3.2.1-x86_64-2)
#
# Returns exit code 1 (failure) if the binary cannot be found
# =============================================================================

pkg_for_binary() {
    # $1 = the binary name ("htop") or path ("/usr/bin/htop")
    local bin="$1"
    local abspath=""   # will hold the resolved absolute path

    # Try to get the absolute path — two possible cases:

    # Case 1: User gave a path that already exists as a file
    # Example: user typed "/usr/bin/htop" or "./myprogram"
    if [[ -f "$bin" ]]; then
        # readlink -f  = resolve ALL symlinks in the path to get the REAL final path
        # -f           = follow symlinks recursively until the real file is reached
        # Example: "/usr/bin/python3" might be a symlink to "/usr/bin/python3.10"
        #          readlink -f resolves to the actual real path
        abspath=$(readlink -f "$bin")

    else
        # Case 2: User gave just a name like "htop" — search for it in $PATH
        # $PATH = a list of directories where the shell looks for commands
        # Example: /usr/bin:/bin:/usr/sbin:/sbin
        #
        # command -v "$bin"  = find the binary in $PATH, print its full path
        # 2>/dev/null        = suppress "not found" error message
        # || true            = if command not found, don't let set -e kill the script
        abspath=$(command -v "$bin" 2>/dev/null) || true

        # If we found the binary in PATH, also resolve any symlinks in its path
        # -n "$abspath"  = is abspath non-empty? (command -v found something)
        # &&             = AND: only resolve symlinks if we found a path
        [[ -n "$abspath" ]] && abspath=$(readlink -f "$abspath")
    fi

    # If we still couldn't find the binary at all, return failure
    # -z "$abspath"  = is abspath empty (zero length)?
    # return 1       = exit function with failure code 1
    [[ -z "$abspath" ]] && return 1

    # Convert absolute path to relative path (remove leading /)
    # ${abspath#/}  = strip the leading "/" character
    # Example: "/usr/bin/htop" → "usr/bin/htop"
    # We need the relative form because package files store paths as "./usr/bin/htop"
    local rel="${abspath#/}"

    # Search through all package files for one that lists this binary
    # grep -rl  = recursive search, return filenames only (not matching lines)
    # "^\./${rel}$\|^${rel}$"  = regex pattern that matches EITHER:
    #   ^\./${rel}$  = line that is exactly "./usr/bin/htop"  (with leading ./)
    #   \|           = OR (regex OR operator)
    #   ^${rel}$     = line that is exactly "usr/bin/htop"    (without leading ./)
    # 2>/dev/null  = discard errors
    # | head -1    = only keep the first match (we just need one package)
    local pkgfile
    pkgfile=$(grep -rl "^\./${rel}$\|^${rel}$" "$PKG_DB" 2>/dev/null | head -1)

    # If we found the owning package file, print both results and return success
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
# Ensures the temporary directory (created when extracting .txz files) is
# ALWAYS deleted when the script ends — no matter HOW it ends.
# This prevents leaving junk in /tmp/ even if the script crashes or is killed.
# =============================================================================

# cleanup() = function that deletes the temp directory if one was created
# [[ -n "$TMPDIR_WORK" ]]  = is TMPDIR_WORK non-empty?
#   If the script never processed a .txz file, TMPDIR_WORK="", so nothing to delete
#   If a .txz WAS processed, TMPDIR_WORK="/tmp/slack-deps.aB3xYz" → delete it
# && rm -rf "$TMPDIR_WORK"
#   rm      = remove command
#   -r      = recursive: delete the directory AND everything inside it
#   -f      = force: no errors if files don't exist, no confirmation prompts
#   This safely removes the entire temp directory and all extracted files
#
# WHY [[ -n ... ]] before rm -rf?
#   CRITICAL SAFETY CHECK: if TMPDIR_WORK were empty and we ran rm -rf "$TMPDIR_WORK"
#   it would become: rm -rf ""  which could delete the CURRENT DIRECTORY — DANGEROUS!
#   The -n check ensures rm only runs when we have a real, non-empty path
cleanup() { [[ -n "$TMPDIR_WORK" ]] && rm -rf "$TMPDIR_WORK"; }

# trap  = Bash built-in command: register a handler for a signal or event
# cleanup  = the function to run when the event fires
# EXIT     = the event: fires whenever the script exits for ANY reason:
#   - Normal completion (script reaches the end)
#   - die() is called (calls exit 1)
#   - set -e kills the script (a command fails)
#   - User presses Ctrl+C
#   - Any other cause of script termination
#
# With this trap, cleanup() is ALWAYS called before the process truly exits
# This is the standard Bash pattern for guaranteed resource cleanup
trap cleanup EXIT


# =============================================================================
# SECTION 10 — INPUT MODE DETECTION
# =============================================================================
# Figure out WHAT the user gave us as TARGET and HOW to get ELF files from it.
#
# There are 3 possible modes:
#   Mode 1: .txz/.tgz file    → extract it, find ELF files inside
#   Mode 2: binary name/path  → verify it's ELF, use just that file
#   Mode 3: package name      → look it up in /var/log/packages, find its ELFs
# =============================================================================

# ELF_FILES = array that will hold all ELF file paths to analyse
# declare -a  = declare as indexed array (normal array, numeric keys 0,1,2...)
# =()         = initialize as empty
declare -a ELF_FILES=()

# PKG_LABEL = text shown in the output header describing what we analysed
# Starts as just the TARGET name, may get updated with extra info below
PKG_LABEL="$TARGET"

# ── MODE 1: Target is a .txz/.tgz package file ────────────────────────────────
# Check if TARGET is a file AND has a package extension
#
# -f "$TARGET"          = is TARGET an existing regular file?
# &&                    = AND both conditions must be true
# "$TARGET" == *.t?z    = does filename match this glob pattern?
#   *    = anything before
#   .t   = literal ".t"
#   ?    = any single character (so: .txz, .tgz, .tbz, .tlz all match)
#   z    = literal "z"
if [[ -f "$TARGET" && "$TARGET" == *.t?z ]]; then

    info "Mode: package file  →  $TARGET"

    # mapfile  = read lines from stdin into an array (built-in Bash command)
    # -t       = strip the trailing newline from each line
    # ELF_FILES  = the array to fill
    # < <(...)   = process substitution fed as stdin:
    #   < = redirect stdin
    #   <(...) = run the command inside (), treat its output as a file to read
    # elf_files_from_tgz "$TARGET"  = function that extracts .txz and prints ELF paths
    mapfile -t ELF_FILES < <(elf_files_from_tgz "$TARGET")

# ── MODE 2: Target is a binary name or path ───────────────────────────────────
# Check if TARGET is a file OR can be found in $PATH
#
# [[ -f "$TARGET" ]]               = is it an existing file path like /usr/bin/ls?
# ||                               = OR
# command -v "$TARGET" &>/dev/null = can it be found by searching $PATH?
#   command -v = like "which" — searches $PATH and prints full path if found
#   &>/dev/null = discard all output (we only care about the exit code: 0=found)
elif [[ -f "$TARGET" ]] || command -v "$TARGET" &>/dev/null; then

    info "Mode: binary  →  $TARGET"

    # Run pkg_for_binary and capture BOTH lines it prints
    # pkg_for_binary prints: line1=absolute_path, line2=package_name
    # || true = if the function returns failure (exit 1), don't let set -e kill us
    # "|| true" makes the overall expression always succeed
    local_result=$(pkg_for_binary "$TARGET") || true

    # Check if pkg_for_binary found anything (local_result non-empty)
    if [[ -n "$local_result" ]]; then

        # Extract line 1 (the binary's absolute path)
        # echo "$local_result"  = print the two-line string
        # | head -1             = keep only the FIRST line
        abspath=$(echo "$local_result" | head -1)

        # Extract line 2 (the owning package name)
        # | tail -1  = keep only the LAST line
        owner_pkg=$(echo "$local_result" | tail -1)

        # Update the label with the package name for the output header
        # Example: "htop  (package: htop-3.2.1-x86_64-2)"
        PKG_LABEL="$TARGET  (package: $owner_pkg)"

        # Verify the binary is actually an ELF file
        # (Could be a shell script, Python script etc. which ldd cannot analyse)
        # file -b "$abspath"    = identify file type (brief mode, no filename prefix)
        # 2>/dev/null           = discard errors
        # | grep -q "^ELF"      = does output start with "ELF"? (-q = quiet, exit code only)
        if file -b "$abspath" 2>/dev/null | grep -q "^ELF"; then
            # It's an ELF — store as the single file to analyse
            # ( "$abspath" ) = create array with one element
            ELF_FILES=( "$abspath" )
        else
            # Not an ELF — shell scripts, Python files etc. have no .so dependencies
            # ldd would fail or give meaningless output on them
            die "'$abspath' is not an ELF binary (it may be a shell script or text file)"
        fi
    else
        # pkg_for_binary returned empty — couldn't find the binary in any package
        die "Could not find '$TARGET' in any installed package."
    fi

# ── MODE 3: Target is an installed package name ───────────────────────────────
# Everything else: treat TARGET as a package name to look up
# Examples: "htop", "coreutils", "mozilla-firefox", "glibc-2.34-x86_64-1"
else
    info "Mode: installed package  →  $TARGET"

    # elf_files_from_installed = function defined above
    # || true = if function fails (package not found), produce empty output
    #           without "|| true", set -e would kill the script here
    #           the function already printed a warning, so we just continue
    #           with an empty ELF_FILES array (caught by the guard below)
    mapfile -t ELF_FILES < <(elf_files_from_installed "$TARGET" || true)
fi


# =============================================================================
# SECTION 11 — GUARD CHECK: must have at least one ELF file
# =============================================================================
# After all 3 mode attempts, if ELF_FILES is still empty, there's nothing
# to analyse — die with a helpful message explaining what went wrong
# =============================================================================

# ${#ELF_FILES[@]}  = number of elements in ELF_FILES array
# #                 = "give me the count"
# ELF_FILES[@]      = all elements
# -eq 0             = equals zero (array is empty)
if [[ ${#ELF_FILES[@]} -eq 0 ]]; then
    die "No ELF binaries found for '$TARGET'.
       If '$TARGET' is a command (like ls, mkdir), it should be auto-detected.
       Otherwise pass the owning package name (e.g. coreutils, util-linux)."
fi

# Report how many ELF files were found and will be inspected
info "Found ${#ELF_FILES[@]} ELF file(s) to inspect."


# =============================================================================
# SECTION 12 — GLOBAL RESULT MAPS
# =============================================================================
# Two associative arrays to collect results during dependency analysis:
#   FOUND_PKGS = packages found as dependencies (what we want to report)
#   UNRES      = .so files that couldn't be matched to any package
# =============================================================================

# FOUND_PKGS = set of packages that own the .so files our target needs
# Using associative array as a SET (only keys matter, values are always 1)
# This automatically handles DEDUPLICATION — if multiple .so files belong
# to the same package (e.g. libc.so.6 AND libm.so.6 both from glibc),
# setting FOUND_PKGS["glibc"]=1 twice is the same as setting it once
# Key   = full package record name like "glibc-2.34-x86_64-1"
# Value = 1 (just a marker, we only care about the keys)
declare -A FOUND_PKGS=()

# UNRES = set of .so filenames that could NOT be matched to any package
# Useful for debugging: these are libraries present at runtime but not
# tracked by Slackware's package system (maybe compiled manually, etc.)
# Key   = soname like "libproprietary.so.3"
# Value = 1 (just a marker)
declare -A UNRES=()


# =============================================================================
# SECTION 13 — FUNCTION: collect_deps_for_elfs()
# =============================================================================
# THE CORE FUNCTION — does the actual dependency analysis.
# Reads ELF file paths from stdin (one per line), runs ldd on each,
# parses the ldd output, and populates FOUND_PKGS and UNRES.
# =============================================================================

collect_deps_for_elfs() {
    local elf   # loop variable: will hold each ELF file path from stdin

    # Read ELF paths from stdin, one per line
    # The function RECEIVES its input from stdin — no arguments
    # Callers use: collect_deps_for_elfs < <(printf '%s\n' "${ELF_FILES[@]}")
    while IFS= read -r elf; do

        # -z "$elf"  = is elf empty?
        # && continue = skip blank lines (printf might produce them)
        [[ -z "$elf" ]] && continue

        # Run ldd on the ELF file to get its shared library requirements
        # ldd "$elf"   = list dynamic dependencies of this ELF binary
        # 2>/dev/null  = discard error output (e.g. "not a dynamic executable")
        # || true      = don't let set -e kill us if ldd returns non-zero
        local ldd_out
        ldd_out=$(ldd "$elf" 2>/dev/null) || true

        # If ldd produced no output, nothing to parse — skip this ELF
        [[ -z "$ldd_out" ]] && continue

        # Parse the ldd output line by line
        # ldd output examples:
        #   linux-vdso.so.1 (0x00007ffd...)           ← virtual, skip
        #   libc.so.6 => /lib64/libc.so.6 (0x...)     ← normal dep
        #   /lib64/ld-linux-x86-64.so.2 (0x...)       ← loader line
        while IFS= read -r line; do

            # ── Skip lines we don't care about ────────────────────────────────

            # linux-vdso = Virtual Dynamic Shared Object provided by the kernel
            # It's mapped into every process by the kernel automatically
            # Not a real file on disk, has no package owner — skip it
            # *"text"* = does line CONTAIN this text anywhere (glob wildcard)
            [[ "$line" == *"linux-vdso"* ]]       && continue

            # "not a dynamic executable" = ldd output when file is not dynamically linked
            [[ "$line" == *"not a dynamic"* ]]     && continue

            # "statically linked" = binary has all libraries baked in, no external deps
            [[ "$line" == *"statically linked"* ]] && continue

            # ── Parse the library line ────────────────────────────────────────
            local soname="" sopath=""   # reset for each line

            # Pattern 1: normal dependency line with "=>"
            # Example: "        libc.so.6 => /lib64/libc.so.6 (0x00007f...)"
            #
            # =~  = regex match operator (right side is an Extended Regular Expression)
            # [[:space:]]          = one whitespace character (space or tab)
            # ([^[:space:]]+)      = CAPTURE GROUP 1: one or more non-space chars = soname
            # [[:space:]]+         = one or more whitespace chars
            # \=\>                 = literal "=>" (escaped because = and > are special)
            # [[:space:]]+         = whitespace
            # ([^[:space:]]+)      = CAPTURE GROUP 2: one or more non-space chars = path
            #
            # After a successful =~ match, BASH_REMATCH array is auto-populated:
            # BASH_REMATCH[0] = entire matched string
            # BASH_REMATCH[1] = first capture group  = soname
            # BASH_REMATCH[2] = second capture group = path
            if [[ "$line" =~ [[:space:]]([^[:space:]]+)[[:space:]]+\=\>[[:space:]]+([^[:space:]]+) ]]; then
                soname="${BASH_REMATCH[1]}"   # e.g. "libc.so.6"
                sopath="${BASH_REMATCH[2]}"   # e.g. "/lib64/libc.so.6"

                # When ldd can't find a library on disk, it shows "(0x...)" as path
                # Example: "libmissing.so.1 => (0x00007f...)"  ← library not found
                # In this case, blank out sopath so we fall back to soname-only lookup
                # "(0x"*  = does sopath start with "(0x"?
                [[ "$sopath" == "(0x"* ]] && sopath=""

            # Pattern 2: path-only line (the dynamic linker itself)
            # Example: "        /lib64/ld-linux-x86-64.so.2 (0x00007f...)"
            # These lines have no "=>" — just a path then the address in parens
            #
            # ^[[:space:]]+  = starts with one or more whitespace characters
            # (/[^[:space:]]+) = CAPTURE GROUP 1: path starting with "/" then non-spaces
            elif [[ "$line" =~ ^[[:space:]]+(/[^[:space:]]+) ]]; then
                sopath="${BASH_REMATCH[1]}"   # e.g. "/lib64/ld-linux-x86-64.so.2"
                soname="${sopath##*/}"         # strip all dirs: get just the filename
                                               # ##*/ = remove everything up to last /

            else
                # Line doesn't match either pattern — skip it
                # (Could be the address lines "(0x...)" or blank lines)
                continue
            fi

            # Safety: if somehow soname is still empty, skip this line
            [[ -z "$soname" ]] && continue

            # ── Resolve the .so to its owning package ─────────────────────────
            local owner=""

            # Try resolving by FULL PATH first (more reliable, handles symlinks)
            # Only if sopath is non-empty AND not the word "not" (from "not found")
            # ldd sometimes outputs: "libfoo.so.1 => not found"
            if [[ -n "$sopath" && "$sopath" != "not" ]]; then
                owner=$(resolve_so "$sopath")
            fi

            # If path lookup failed, try resolving by SONAME alone
            # -z "$owner"  = is owner empty? (path lookup found nothing)
            if [[ -z "$owner" ]]; then
                owner=$(resolve_so "$soname")
            fi

            # ── Record the result ─────────────────────────────────────────────

            if [[ -n "$owner" ]]; then
                # Successfully found the owning package — add to FOUND_PKGS set
                # FOUND_PKGS["glibc-2.34-x86_64-1"]=1
                # If this package was already in the map, this just overwrites
                # with 1 again — effectively a no-op, achieving deduplication
                FOUND_PKGS["$owner"]=1

                # If verbose mode is on, print the individual .so → package line
                # $VERBOSE -eq 1  = was -v flag passed?
                if [[ $VERBOSE -eq 1 ]]; then
                    # printf = formatted print (more control than echo)
                    # %-40s  = left-justify the soname in a 40-character wide column
                    #          % = format specifier, - = left-align, 40 = width, s = string
                    # → %s\n = then print the package name and newline
                    # \n     = newline character
                    printf "    ${GRN}%-40s${RST} → %s\n" "$soname" "$owner"
                fi
            else
                # No package found for this .so — add to UNRES set
                # Will be shown at the end if -u flag was passed
                UNRES["$soname"]=1
            fi

        done <<< "$ldd_out"
        # <<< = "herestring" operator
        # Feeds the STRING stored in $ldd_out as the stdin of the while loop
        # Difference from < file: feeds a string directly, not a file
        # Difference from echo | while: doesn't create a subshell, so
        # variable changes inside the loop (FOUND_PKGS, UNRES) are preserved

    done
    # The outer while loop (reading ELF paths) gets its stdin from the CALLER:
    # collect_deps_for_elfs < <(printf '%s\n' "${ELF_FILES[@]}")
}


# =============================================================================
# SECTION 14 — PRINT OUTPUT HEADER
# =============================================================================
# Print the decorative bordered header at the top of the results output
# =============================================================================

echo ""   # blank line before the header for visual spacing

# ${BLD}...${RST}  = make the line bold
# ━  = unicode "box drawing heavy horizontal" character — used as a visual divider
echo "${BLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RST}"

# Show what we're analysing
# ${CYN}${PKG_LABEL}${RST}  = print PKG_LABEL in cyan
# PKG_LABEL = either just "htop" or "htop  (package: htop-3.2.1-x86_64-2)"
echo "${BLD} Runtime dependencies for: ${CYN}${PKG_LABEL}${RST}"

echo "${BLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RST}"

# In verbose mode, add a blank line after the header before the .so → pkg lines
# [[ $VERBOSE -eq 1 ]]  = was -v flag passed?
# && echo ""            = if yes, print blank line
[[ $VERBOSE -eq 1 ]] && echo ""


# =============================================================================
# SECTION 15 — FIRST PASS: DIRECT (IMMEDIATE) DEPENDENCIES
# =============================================================================
# Run the core analysis on the ELF files we found — get their direct deps.
# After this, FOUND_PKGS contains all packages that directly satisfy
# the .so requirements of our target's ELF binaries.
# =============================================================================

# Call collect_deps_for_elfs, feeding it the ELF_FILES array via stdin
# printf '%s\n' "${ELF_FILES[@]}"  = print each array element on its own line
#   '%s\n' = format: string followed by newline
#   "${ELF_FILES[@]}" = all elements of ELF_FILES
# < <(...)  = process substitution: run command in (), feed output as stdin
collect_deps_for_elfs < <(printf '%s\n' "${ELF_FILES[@]}")

# Remove the TARGET ITSELF from the results
# A package should not be listed as its own dependency
# Example: if target is "htop", remove "htop" and "htop-3.2.1-x86_64-2" from results
#
# unset "FOUND_PKGS[$TARGET]"  = delete the exact TARGET key if it exists
unset "FOUND_PKGS[$TARGET]"

# Also remove versioned forms of TARGET
# Example: target="htop", also remove "htop-3.2.1-x86_64-2" (versioned record name)
# ${!FOUND_PKGS[@]}   = all KEYS of FOUND_PKGS (! means keys, not values)
# "$k" == "${TARGET}-"*  = does this key START with "TARGET-"?
#   ${TARGET}-  = target name followed by hyphen
#   *           = any characters after
# && unset "FOUND_PKGS[$k]"  = if it matches, delete this key
for k in "${!FOUND_PKGS[@]}"; do
    [[ "$k" == "${TARGET}-"* ]] && unset "FOUND_PKGS[$k]"
done


# =============================================================================
# SECTION 16 — OUTPUT: REQUIRED PACKAGES LIST
# =============================================================================
# Print the final results: sorted list of packages that the target needs.
# Each line shows: short_name (left column)  full_versioned_name (right column)
# =============================================================================

echo ""   # blank line for spacing

# Check if any dependencies were found at all
if [[ ${#FOUND_PKGS[@]} -eq 0 ]]; then
    # No packages found — could mean target is statically linked or has no deps
    echo "  ${YEL}No runtime dependencies found.${RST}"
else
    # Print the count header
    # ${#FOUND_PKGS[@]}  = number of packages found
    echo "${BLD}  Required Slackware packages (${#FOUND_PKGS[@]}):${RST}"
    echo ""

    # Loop through ALL package names, SORTED alphabetically
    # printf '%s\n' "${!FOUND_PKGS[@]}"  = print each key (package name) on its own line
    #   ${!FOUND_PKGS[@]}  = all KEYS of FOUND_PKGS (! = keys)
    # | sort  = pipe to sort command: alphabetical sort
    # $(...) with no quotes = word splitting happens, giving us sorted list
    for pkg in $(printf '%s\n' "${!FOUND_PKGS[@]}" | sort); do

        # Try to parse the Slackware package naming format: name-version-arch-build
        # Example: "glibc-2.34-x86_64-1"
        #   name    = "glibc"
        #   version = "2.34"
        #   arch    = "x86_64"
        #   build   = "1"
        #
        # Regex breakdown:
        # ^                = start of string
        # ([^-]+(-[^-]+)*) = CAPTURE GROUP 1: the package base name
        #   [^-]+          = one or more non-hyphen characters (e.g. "glibc")
        #   (-[^-]+)*      = zero or more groups of: hyphen + non-hyphen chars
        #                    This handles names with hyphens like "mozilla-firefox"
        # -                = literal hyphen separating name from version
        # ([0-9][^-]*)     = CAPTURE GROUP 3: version starting with a digit
        #   [0-9]          = must start with digit (so "2.34" matches, "solibs" doesn't)
        #   [^-]*          = any non-hyphen chars after
        # -                = literal hyphen
        # ([^-]+)          = CAPTURE GROUP 4: architecture (e.g. "x86_64")
        # -                = literal hyphen
        # ([^-]+)          = CAPTURE GROUP 5: build number (e.g. "1")
        # $                = end of string
        if [[ "$pkg" =~ ^([^-]+(-[^-]+)*)-([0-9][^-]*)-([^-]+)-([^-]+)$ ]]; then
            # BASH_REMATCH[1] = first capture group = the base package name
            # Example: "glibc-2.34-x86_64-1" → BASH_REMATCH[1] = "glibc"
            #          "mozilla-firefox-102.0-x86_64-1" → BASH_REMATCH[1] = "mozilla-firefox"
            name="${BASH_REMATCH[1]}"

            # Print two columns:
            # Left:  short name    — green, left-justified in 35-char wide column
            # Right: full pkg name — default colour
            # %-35s  = format: %-=left-align, 35=column width, s=string
            # All rows use same width so the right column lines up perfectly
            printf "  ${GRN}%-35s${RST}  %s\n" "$name" "$pkg"
        else
            # Fallback for unexpected name formats that don't match Slackware convention
            # Just print the full name in green without two-column formatting
            printf "  ${GRN}%s${RST}\n" "$pkg"
        fi
    done
fi


# =============================================================================
# SECTION 17 — OUTPUT: UNRESOLVED LIBRARIES (only shown with -u flag)
# =============================================================================
# Show any .so files that were needed but couldn't be matched to any package.
# This section is ONLY shown if BOTH conditions are true:
#   1. User passed the -u flag (SHOW_UNRESOLVED=1)
#   2. There are actually some unresolved libraries (UNRES is not empty)
# =============================================================================

# $SHOW_UNRESOLVED -eq 1   = -u flag was passed
# &&                       = AND
# ${#UNRES[@]} -gt 0       = UNRES array has at least one entry
if [[ $SHOW_UNRESOLVED -eq 1 && ${#UNRES[@]} -gt 0 ]]; then

    echo ""

    # Print count header (in bold yellow to make it stand out as a warning)
    echo "${BLD}  ${YEL}Unresolved shared libraries (${#UNRES[@]}):${RST}"
    echo "  ${YEL}(present at runtime but not owned by any indexed package)${RST}"
    echo ""

    # Loop through unresolved sonames, sorted alphabetically
    # ${!UNRES[@]}  = all KEYS of UNRES (the sonames)
    for so in $(printf '%s\n' "${!UNRES[@]}" | sort); do
        # ⚠  = unicode warning sign character
        # Print each unresolved .so name in yellow with a warning symbol
        printf "  ${YEL}⚠  %s${RST}\n" "$so"
    done
fi

# Final closing divider line
echo "${BLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RST}"
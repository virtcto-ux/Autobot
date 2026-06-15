#!/usr/bin/env bash
# backup-to-s3.sh — incremental backup of Windows drives and WSL paths to S3
# Run from WSL. Uses aws s3 sync (additive only, no deletions).
#
# Usage:
#   ./backup-to-s3.sh
#   Or with overrides:
#   BUCKET=my-bucket PREFIX=backups/laptop ./backup-to-s3.sh
#
# Custom exclusions:
#   Add patterns to ~/.backup-excludes (one per line, # for comments).
#   Patterns follow aws s3 sync glob syntax — see EXCLUDE FILE section below.

set -euo pipefail

# ---------------------------------------------------------------------------
# CONFIGURATION — edit these or override via environment variables
# ---------------------------------------------------------------------------

BUCKET="${BUCKET:-}"                    # e.g. my-backup-bucket
PREFIX="${PREFIX:-}"                    # e.g. backups/mymachine  (no trailing slash)
AWS_PROFILE="${AWS_PROFILE:-default}"   # AWS CLI profile name

# Path to your custom exclusions file. Override with EXCLUDE_FILE env var.
EXCLUDE_FILE="${EXCLUDE_FILE:-$HOME/.backup-excludes}"

# Windows paths to back up (accessed via /mnt/<drive>)
WINDOWS_SOURCES=(
    # "/mnt/d"                          # entire D: drive
    # "/mnt/d/Documents"
    # "/mnt/d/Projects"
)

# WSL paths to back up (native Linux paths)
WSL_SOURCES=(
    # "$HOME"
    # "/home/youruser/projects"
)

# ---------------------------------------------------------------------------
# BUILT-IN EXCLUSIONS
# These are always applied. Add your own in ~/.backup-excludes instead of
# editing here, so script updates don't overwrite your customisations.
# ---------------------------------------------------------------------------

BUILTIN_EXCLUDES=(
    # Windows system noise
    "pagefile.sys"
    "hiberfil.sys"
    "swapfile.sys"
    "\$Recycle.Bin/*"
    "System Volume Information/*"
    "Windows/*"
    "Thumbs.db"
    "desktop.ini"

    # macOS noise (if backing up drives that were ever used on a Mac)
    ".DS_Store"
    "._*"
    ".Spotlight-V100/*"
    ".Trashes/*"

    # Temp / junk
    "*.tmp"
    "*.temp"
    "~$*"                   # Office temp files
    "*.bak"
    "*.swp"
    "*.swo"

    # Logs (comment out if you DO want logs backed up)
    "*.log"
    "*.log.*"

    # Node / JS
    "*/node_modules/*"
    "*/.npm/*"
    "*/.yarn/cache/*"
    "*/.pnp.*"
    "*/dist/*"
    "*/build/*"
    "*/.next/*"
    "*/.nuxt/*"
    "*/.svelte-kit/*"
    "*/.turbo/*"
    "*/.parcel-cache/*"

    # Python
    "*/__pycache__/*"
    "*/.mypy_cache/*"
    "*/.ruff_cache/*"
    "*/.pytest_cache/*"
    "*.pyc"
    "*.pyo"
    "*/.venv/*"
    "*/venv/*"
    "*/env/*"
    "*.egg-info/*"

    # Rust
    "*/target/debug/*"
    "*/target/release/*"

    # Go
    "*/vendor/*"

    # Java / JVM
    "*/target/classes/*"
    "*/target/generated-sources/*"
    "*.class"
    "*.jar"
    "*.war"
    "*/.gradle/*"
    "*/.m2/*"

    # .NET
    "*/bin/Debug/*"
    "*/bin/Release/*"
    "*/obj/Debug/*"
    "*/obj/Release/*"

    # Git internals (keep .git/config etc., skip the bulk)
    "*/.git/objects/*"
    "*/.git/lfs/*"

    # IDE / editor artifacts
    "*/.idea/*"
    "*/.vscode/*"
    "*/.vs/*"
    "*.iml"

    # Docker
    # (Docker's data root is usually outside user dirs, but just in case)
    "*/docker/volumes/*"

    # Large media / compiled assets you likely don't need versioned
    "*.iso"
    "*.vmdk"
    "*.vhd"
    "*.vhdx"
)

# ---------------------------------------------------------------------------
# VALIDATION
# ---------------------------------------------------------------------------

die() { echo "ERROR: $*" >&2; exit 1; }

[[ -z "$BUCKET" ]] && die "Set BUCKET (e.g. export BUCKET=my-backup-bucket)"
[[ -z "$PREFIX" ]] && die "Set PREFIX (e.g. export PREFIX=backups/mymachine)"

command -v aws &>/dev/null || die "aws CLI not found. Install it in WSL: https://docs.aws.amazon.com/cli/latest/userguide/install-cliv2-linux.html"

if [[ ${#WINDOWS_SOURCES[@]} -eq 0 && ${#WSL_SOURCES[@]} -eq 0 ]]; then
    die "No sources configured. Edit WINDOWS_SOURCES or WSL_SOURCES in this script."
fi

# ---------------------------------------------------------------------------
# LOGGING
# ---------------------------------------------------------------------------

LOGFILE="${LOGFILE:-$HOME/.backup-to-s3.log}"
LOG_MAX_BYTES=5242880  # 5 MB — rotate when exceeded

rotate_log() {
    if [[ -f "$LOGFILE" && $(stat -c%s "$LOGFILE" 2>/dev/null || echo 0) -gt $LOG_MAX_BYTES ]]; then
        mv "$LOGFILE" "${LOGFILE}.1"
    fi
}

log() {
    local ts
    ts=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$ts] $*" | tee -a "$LOGFILE"
}

# ---------------------------------------------------------------------------
# EXCLUSION HANDLING
# ---------------------------------------------------------------------------

# Load patterns from the user's exclude file (skip blank lines and # comments)
load_user_excludes() {
    local patterns=()
    if [[ -f "$EXCLUDE_FILE" ]]; then
        while IFS= read -r line || [[ -n "$line" ]]; do
            # Strip leading/trailing whitespace
            line="${line#"${line%%[![:space:]]*}"}"
            line="${line%"${line##*[![:space:]]}"}"
            # Skip empty lines and comments
            [[ -z "$line" || "$line" == \#* ]] && continue
            patterns+=("$line")
        done < "$EXCLUDE_FILE"
        log "INFO  Loaded $(( ${#patterns[@]} )) custom exclusion(s) from $EXCLUDE_FILE"
    fi
    printf '%s\n' "${patterns[@]}"
}

build_exclude_args() {
    local args=()

    for pat in "${BUILTIN_EXCLUDES[@]}"; do
        args+=(--exclude "$pat")
    done

    # Append user exclusions from file
    while IFS= read -r pat; do
        [[ -n "$pat" ]] && args+=(--exclude "$pat")
    done < <(load_user_excludes)

    printf '%s\0' "${args[@]}"
}

# ---------------------------------------------------------------------------
# SYNC
# ---------------------------------------------------------------------------

sync_path() {
    local src="$1"
    local s3_dest="$2"
    local label="$3"

    if [[ ! -e "$src" ]]; then
        log "WARN  [$label] Source not found, skipping: $src"
        return 0
    fi

    log "START [$label] $src  →  s3://$s3_dest"

    # Build exclude args into a temp array via NUL-delimited output
    local -a exclude_args=()
    while IFS= read -r -d '' arg; do
        exclude_args+=("$arg")
    done < <(build_exclude_args)

    if AWS_PROFILE="$AWS_PROFILE" aws s3 sync \
            "$src" "s3://$s3_dest" \
            --storage-class STANDARD_IA \
            --no-progress \
            "${exclude_args[@]}" \
            2>&1 | tee -a "$LOGFILE"; then
        log "OK    [$label] completed"
    else
        log "FAIL  [$label] aws s3 sync exited with error"
        FAILED_SOURCES+=("$label: $src")
    fi
}

# ---------------------------------------------------------------------------
# MAIN
# ---------------------------------------------------------------------------

rotate_log
log "======== Backup started (profile=$AWS_PROFILE, bucket=$BUCKET, prefix=$PREFIX) ========"
[[ -f "$EXCLUDE_FILE" ]] && log "INFO  Using exclude file: $EXCLUDE_FILE" \
                          || log "INFO  No exclude file at $EXCLUDE_FILE (create one to add custom patterns)"

FAILED_SOURCES=()

for src in "${WINDOWS_SOURCES[@]}"; do
    rel="${src#/mnt/}"
    sync_path "$src" "$BUCKET/$PREFIX/windows/$rel" "win:$rel"
done

for src in "${WSL_SOURCES[@]}"; do
    rel="${src#/}"
    sync_path "$src" "$BUCKET/$PREFIX/wsl/$rel" "wsl:$rel"
done

if [[ ${#FAILED_SOURCES[@]} -gt 0 ]]; then
    log "======== Backup FINISHED WITH ERRORS ========"
    for f in "${FAILED_SOURCES[@]}"; do
        log "  FAILED: $f"
    done
    exit 1
else
    log "======== Backup completed successfully ========"
fi

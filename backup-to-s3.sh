#!/usr/bin/env bash
# backup-to-s3.sh — incremental backup of Windows drives and WSL paths to S3
# Run from WSL. Uses aws s3 sync (additive only, no deletions).
#
# Usage:
#   ./backup-to-s3.sh
#   Or with overrides:
#   BUCKET=my-bucket PREFIX=backups/laptop ./backup-to-s3.sh

set -euo pipefail

# ---------------------------------------------------------------------------
# CONFIGURATION — edit these or override via environment variables
# ---------------------------------------------------------------------------

BUCKET="${BUCKET:-}"                    # e.g. my-backup-bucket
PREFIX="${PREFIX:-}"                    # e.g. backups/mymachine  (no trailing slash)
AWS_PROFILE="${AWS_PROFILE:-default}"   # AWS CLI profile name

# Windows paths to back up (accessed via /mnt/<drive>)
# Add or remove entries as needed.
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

# Patterns to exclude (passed to aws s3 sync --exclude)
EXCLUDES=(
    "*.tmp"
    "*.log"
    "Thumbs.db"
    ".DS_Store"
    "pagefile.sys"
    "hiberfil.sys"
    "swapfile.sys"
    "\$Recycle.Bin/*"
    "System Volume Information/*"
    "Windows/*"
    "*/node_modules/*"
    "*/.git/objects/*"
    "*/__pycache__/*"
    "*.pyc"
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
# HELPERS
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

build_exclude_args() {
    local args=()
    for pat in "${EXCLUDES[@]}"; do
        args+=(--exclude "$pat")
    done
    echo "${args[@]}"
}

sync_path() {
    local src="$1"
    local s3_dest="$2"
    local label="$3"

    if [[ ! -e "$src" ]]; then
        log "WARN  [$label] Source not found, skipping: $src"
        return 0
    fi

    log "START [$label] $src  →  s3://$s3_dest"

    local exclude_args
    exclude_args=$(build_exclude_args)

    # shellcheck disable=SC2086
    if AWS_PROFILE="$AWS_PROFILE" aws s3 sync \
            "$src" "s3://$s3_dest" \
            --storage-class STANDARD_IA \
            --no-progress \
            $exclude_args \
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

FAILED_SOURCES=()

for src in "${WINDOWS_SOURCES[@]}"; do
    # Derive a clean S3 sub-prefix from the path.
    # /mnt/d/Documents  → windows/d/Documents
    # /mnt/d            → windows/d
    rel="${src#/mnt/}"
    dest="$BUCKET/$PREFIX/windows/$rel"
    sync_path "$src" "$dest" "win:$rel"
done

for src in "${WSL_SOURCES[@]}"; do
    # /home/user/projects → wsl/home/user/projects
    rel="${src#/}"
    dest="$BUCKET/$PREFIX/wsl/$rel"
    sync_path "$src" "$dest" "wsl:$rel"
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

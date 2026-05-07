#!/usr/bin/env bash
#
# remove-snapd.sh
#
# Purpose:
#   Completely remove and block Snap/Snapd from Ubuntu systems,
#   with optional steps to install Firefox and the Phoenix configuration overlay.
#
# Target:
#   Ubuntu 26.04 LTS (currently tested target)
#
# Features:
#   - Safe to rerun (idempotent)
#   - Graceful error handling
#   - Dependency-aware snap removal loop
#   - Colored TUI output with timestamps
#   - Noninteractive apt operations
#   - Prevents snapd reinstall via apt pinning
#   - Cleans residual directories
#   - Interactive confirmation before destructive actions
#   - Optional Firefox DEB installation with GPG fingerprint verification
#   - Optional Phoenix installation (requires --install-firefox)
#
# Usage:
#   chmod +x remove-snapd.sh
#   sudo ./remove-snapd.sh
#
# Flags / env vars:
#   -y / --yes              Skip confirmation prompt
#   --dry-run               Preview actions without making changes
#   --install-firefox       Install Firefox from packages.mozilla.org after removal
#   --install-phoenix       Install Phoenix after Firefox (implies --install-firefox)
#   DRY_RUN=true            Same as --dry-run
#   AUTO_CONFIRM=true       Same as -y
#   INSTALL_FIREFOX=true    Same as --install-firefox
#   INSTALL_PHOENIX=true    Same as --install-phoenix
#   NO_COLOR=1              Disable colored output
#

set -Eeuo pipefail

#######################################
# Configuration
#######################################

readonly SCRIPT_NAME="$(basename "$0")"
readonly NOSNAP_PREF="/etc/apt/preferences.d/nosnap.pref"

DRY_RUN="${DRY_RUN:-false}"
AUTO_CONFIRM="${AUTO_CONFIRM:-false}"
INSTALL_FIREFOX="${INSTALL_FIREFOX:-false}"
INSTALL_PHOENIX="${INSTALL_PHOENIX:-false}"

# Populated by setup_colors(); safe empty defaults for non-color paths
RED=''; YELLOW=''; GREEN=''; CYAN=''; BLUE=''; BOLD=''; DIM=''; RESET=''

#######################################
# Colors
#######################################

setup_colors() {
    if [[ -t 1 && "${NO_COLOR:-}" == "" ]]; then
        RED=$'\033[0;31m'
        YELLOW=$'\033[1;33m'
        GREEN=$'\033[0;32m'
        CYAN=$'\033[0;36m'
        BLUE=$'\033[0;34m'
        BOLD=$'\033[1m'
        DIM=$'\033[2m'
        RESET=$'\033[0m'
    fi
}

#######################################
# Logging
#######################################

log() {
    local color="$1" level="$2"
    shift 2
    printf '%s%s [%-5s]%s %s\n' \
        "$color" \
        "$(date '+%Y-%m-%d %H:%M:%S')" \
        "$level" \
        "$RESET" \
        "$*"
}

info()    { log "$CYAN"   "INFO"  "$@"; }
warn()    { log "$YELLOW" "WARN"  "$@"; }
error()   { log "$RED"    "ERROR" "$@"; }
success() { log "$GREEN"  "OK"    "$@"; }

section() {
    printf '\n%s%s━━━  %s  ━━━%s\n\n' "$BOLD" "$BLUE" "$*" "$RESET"
}

#######################################
# Error handling
#######################################

on_error() {
    local exit_code=$?
    local line_no=$1
    error "Script failed at line ${line_no} with exit code ${exit_code}"
    exit "$exit_code"
}

trap 'on_error $LINENO' ERR

#######################################
# Helpers
#######################################

require_root() {
    if [[ "$EUID" -ne 0 ]]; then
        error "This script must be run as root."
        error "Try: sudo ./${SCRIPT_NAME}"
        exit 1
    fi
}

run() {
    if [[ "$DRY_RUN" == "true" ]]; then
        printf '%s[DRY-RUN]%s %s\n' "$DIM" "$RESET" "$*"
    else
        "$@"
    fi
}

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

parse_args() {
    for arg in "$@"; do
        case "$arg" in
            -y|--yes)              AUTO_CONFIRM=true ;;
            --dry-run)             DRY_RUN=true ;;
            --install-firefox)     INSTALL_FIREFOX=true ;;
            --install-phoenix)     INSTALL_PHOENIX=true; INSTALL_FIREFOX=true ;;
            *)
                error "Unknown argument: ${arg}"
                error "Valid: -y/--yes, --dry-run, --install-firefox, --install-phoenix"
                exit 2
                ;;
        esac
    done
}

#######################################
# Validation
#######################################

validate_os() {
    if [[ ! -f /etc/os-release ]]; then
        error "/etc/os-release not found."
        exit 1
    fi

    # shellcheck disable=SC1091
    source /etc/os-release

    if [[ "${ID:-}" != "ubuntu" ]]; then
        warn "This script was designed for Ubuntu. Detected: ${ID:-unknown}"
    fi
}

preflight_checks() {
    local missing=()

    if [[ "$INSTALL_FIREFOX" == "true" || "$INSTALL_PHOENIX" == "true" ]]; then
        command_exists wget || missing+=("wget")
        command_exists gpg  || missing+=("gnupg")
    fi

    if [[ "${#missing[@]}" -gt 0 ]]; then
        error "Required tools are missing: ${missing[*]}"
        error "Install them first: apt-get install ${missing[*]}"
        exit 1
    fi
}

#######################################
# Banner & confirmation
#######################################

print_banner() {
    printf '\n%s%s' "$BOLD" "$BLUE"
    printf '╔══════════════════════════════════════════╗\n'
    printf '║        Snap / Snapd Removal Tool         ║\n'
    printf '║             Ubuntu Systems               ║\n'
    printf '╚══════════════════════════════════════════╝\n'
    printf '%s' "$RESET"

    if [[ "$INSTALL_FIREFOX" == "true" ]]; then
        printf '%s  + Firefox DEB installation enabled%s\n' "$CYAN" "$RESET"
    fi

    if [[ "$INSTALL_PHOENIX" == "true" ]]; then
        printf '%s  + Phoenix installation enabled%s\n' "$CYAN" "$RESET"
    fi

    if [[ "$DRY_RUN" == "true" ]]; then
        printf '%s  ⚙  DRY-RUN mode — no changes will be made%s\n' "$DIM" "$RESET"
    fi

    printf '\n'
}

print_warning_summary() {
    printf '%s%s⚠  WARNING — The following destructive actions will be taken:%s\n\n' \
        "$BOLD" "$YELLOW" "$RESET"

    printf '%s  Snap packages%s\n' "$BOLD" "$RESET"
    printf '    All installed snap packages will be force-removed (--purge)\n\n'

    printf '%s  System services%s  (stopped → disabled → masked)\n' "$BOLD" "$RESET"
    printf '    • snapd.service\n'
    printf '    • snapd.socket\n'
    printf '    • snapd.seeded.service\n\n'

    printf '%s  APT operations%s\n' "$BOLD" "$RESET"
    printf '    • snapd purged via apt-get purge\n'
    printf '    • %sapt autoremove --purge  ← removes ALL orphaned packages system-wide%s\n' \
        "$YELLOW" "$RESET"
    printf '    • snapd and snap held via apt-mark hold\n\n'

    printf '%s  Directories to be permanently deleted%s\n' "$BOLD" "$RESET"
    printf '    • /snap\n'
    printf '    • /var/snap\n'
    printf '    • /var/lib/snapd\n'
    printf '    • /var/cache/snapd\n'
    printf '    • /root/snap\n'
    printf '    • /home/*/snap  (all user home directories)\n\n'

    printf '%s  APT pin file%s\n' "$BOLD" "$RESET"
    printf '    • %s\n' "$NOSNAP_PREF"
    printf '      Blocks snapd from being reinstalled via apt\n\n'

    if [[ "$INSTALL_FIREFOX" == "true" ]]; then
        printf '%s  Firefox DEB installation%s  (--install-firefox)\n' "$BOLD" "$RESET"
        printf '    • GPG key downloaded from packages.mozilla.org and fingerprint verified\n'
        printf '    • /etc/apt/keyrings/packages.mozilla.org.asc written\n'
        printf '    • /etc/apt/sources.list.d/mozilla.sources written\n'
        printf '    • /etc/apt/preferences.d/mozilla written  (pin priority 1000)\n'
        printf '    • apt-get update && apt-get install firefox\n\n'
    fi

    if [[ "$INSTALL_PHOENIX" == "true" ]]; then
        printf '%s  Phoenix installation%s  (--install-phoenix)\n' "$BOLD" "$RESET"
        printf '    • GPG key downloaded from download.opensuse.org and fingerprint displayed\n'
        printf '    • /etc/apt/trusted.gpg.d/home_celenity.gpg written\n'
        printf '    • /etc/apt/sources.list.d/home:celenity.list written\n'
        printf '    • apt-get update && apt-get install phoenix\n'
        printf '    • %s Firefox must be restarted after first run with Phoenix installed%s\n\n' \
            "$YELLOW" "$RESET"
    fi
}

confirm() {
    if [[ "$AUTO_CONFIRM" == "true" || "$DRY_RUN" == "true" ]]; then
        return 0
    fi

    printf '%s%s  Proceed? This cannot be undone. [y/N]: %s' "$BOLD" "$RED" "$RESET"

    local reply
    read -r reply
    printf '\n'

    if [[ ! "$reply" =~ ^[Yy]$ ]]; then
        printf 'Aborted.\n'
        exit 0
    fi
}

#######################################
# Snap removal
#######################################

remove_snap_packages() {
    section "Snap Package Removal"

    if ! command_exists snap; then
        info "snap command not present. Skipping package removal."
        return
    fi

    info "Discovering installed snap packages..."

    mapfile -t snaps < <(
        snap list 2>/dev/null \
            | awk 'NR>1 {print $1}' \
            | sort -u
    )

    if [[ "${#snaps[@]}" -eq 0 ]]; then
        info "No snap packages installed."
        return
    fi

    info "Found ${#snaps[@]} snap package(s). Starting dependency-aware removal..."

    local removed_any=true
    local pass=1

    while [[ "$removed_any" == "true" ]]; do
        removed_any=false

        info "Removal pass #${pass}"

        mapfile -t snaps < <(
            snap list 2>/dev/null \
                | awk 'NR>1 {print $1}' \
                | sort -u
        )

        if [[ "${#snaps[@]}" -eq 0 ]]; then
            success "All snap packages removed."
            break
        fi

        for snap_pkg in "${snaps[@]}"; do
            info "Removing snap: ${snap_pkg}"

            if run snap remove --purge "$snap_pkg"; then
                removed_any=true
            else
                warn "Could not remove ${snap_pkg} in this pass (likely dependency ordering)."
            fi
        done

        pass=$((pass + 1))

        if [[ "$DRY_RUN" == "true" ]]; then
            info "Dry-run mode: stopping after first enumeration pass."
            break
        fi
    done

    mapfile -t remaining < <(
        snap list 2>/dev/null \
            | awk 'NR>1 {print $1}'
    )

    if [[ "${#remaining[@]}" -gt 0 ]]; then
        warn "Some snap packages could not be removed:"
        for pkg in "${remaining[@]}"; do
            printf '    %s• %s%s\n' "$YELLOW" "$pkg" "$RESET"
        done
    else
        success "Snap package removal complete."
    fi
}

#######################################
# Services
#######################################

disable_snapd_services() {
    section "Disabling Snapd Services"

    if ! command_exists systemctl; then
        warn "systemctl not available. Skipping service disable."
        return
    fi

    local services=(
        snapd.service
        snapd.socket
        snapd.seeded.service
    )

    for svc in "${services[@]}"; do
        if systemctl list-unit-files | grep -q "^${svc}"; then
            info "Stopping   ${svc}"
            if ! run systemctl stop "$svc"; then
                warn "Failed to stop ${svc} (may already be stopped)."
            fi

            info "Disabling  ${svc}"
            if ! run systemctl disable "$svc"; then
                warn "Failed to disable ${svc} (may already be disabled)."
            fi

            info "Masking    ${svc}"
            if ! run systemctl mask "$svc"; then
                warn "Failed to mask ${svc}."
            else
                success "${svc} masked."
            fi
        else
            info "${svc} not found, skipping."
        fi
    done
}

#######################################
# APT removal
#######################################

purge_snapd() {
    section "Purging snapd via APT"

    if ! dpkg -s snapd >/dev/null 2>&1; then
        info "snapd package already absent."
        return
    fi

    info "Purging snapd..."

    export DEBIAN_FRONTEND=noninteractive

    run apt-get purge -y snapd

    success "snapd purged."
}

#######################################
# Cleanup
#######################################

remove_directories() {
    section "Removing Snap Directories"

    local dirs=(
        /snap
        /var/snap
        /var/lib/snapd
        /var/cache/snapd
        /root/snap
    )

    for dir in "${dirs[@]}"; do
        if [[ -e "$dir" ]]; then
            info "Removing ${dir}"
            run rm -rf "$dir"
        else
            info "Already absent: ${dir}"
        fi
    done

    for user_snap in /home/*/snap; do
        if [[ -e "$user_snap" ]]; then
            info "Removing ${user_snap}"
            run rm -rf "$user_snap"
        fi
    done

    success "Directory cleanup complete."
}

#######################################
# APT pinning
#######################################

create_nosnap_preferences() {
    section "Creating APT Pin (Block Reinstall)"

    info "Writing ${NOSNAP_PREF}..."

    local content
    content=$(
        cat <<'EOF'
Package: snapd
Pin: release a=*
Pin-Priority: -10
EOF
    )

    if [[ "$DRY_RUN" == "true" ]]; then
        printf '%s[DRY-RUN]%s would write %s\n' "$DIM" "$RESET" "$NOSNAP_PREF"
        return
    fi

    printf '%s\n' "$content" > "$NOSNAP_PREF"
    chmod 644 "$NOSNAP_PREF"

    success "APT pin created: ${NOSNAP_PREF}"
}

#######################################
# Cleanup packages
#######################################

autoremove_packages() {
    section "APT Autoremove"

    warn "apt autoremove --purge will remove ALL orphaned packages system-wide, not just snap-related ones."
    info "Running apt autoremove..."

    export DEBIAN_FRONTEND=noninteractive

    run apt-get autoremove --purge -y

    success "Autoremove complete."
}

#######################################
# Holds
#######################################

hold_snap_packages() {
    section "Holding Packages via apt-mark"

    # "snap" package usually does not exist separately,
    # but keeping this defensive in case of future packaging changes.

    if apt-cache show snap >/dev/null 2>&1; then
        info "Holding snap package..."
        if ! run apt-mark hold snap; then
            warn "Failed to hold snap package."
        else
            success "snap held."
        fi
    fi

    if apt-cache show snapd >/dev/null 2>&1; then
        info "Holding snapd package..."
        if ! run apt-mark hold snapd; then
            warn "Failed to hold snapd package."
        else
            success "snapd held."
        fi
    fi
}

#######################################
# Firefox DEB installation
#######################################

install_firefox_deb() {
    section "Firefox DEB Installation (packages.mozilla.org)"

    local keyring="/etc/apt/keyrings/packages.mozilla.org.asc"
    local sources="/etc/apt/sources.list.d/mozilla.sources"
    local prefs="/etc/apt/preferences.d/mozilla"
    local key_url="https://packages.mozilla.org/apt/repo-signing-key.gpg"
    local expected_fp="35BAA0B33E9EB396F59CA838C0BA5CE6DC6315A3"

    # Already installed?
    if dpkg -s firefox >/dev/null 2>&1 && [[ "$DRY_RUN" != "true" ]]; then
        info "Firefox is already installed. Skipping."
        return 0
    fi

    # Step 1 — Create keyrings directory
    info "Creating /etc/apt/keyrings/..."
    run install -d -m 0755 /etc/apt/keyrings

    # Step 2 — Download signing key
    info "Downloading Mozilla repository signing key..."
    if [[ "$DRY_RUN" == "true" ]]; then
        printf '%s[DRY-RUN]%s would download %s → %s\n' "$DIM" "$RESET" "$key_url" "$keyring"
    else
        if ! wget -q "$key_url" -O- | tee "$keyring" > /dev/null; then
            error "Failed to download Mozilla GPG key."
            error "Check your network connection and that ${key_url} is reachable."
            return 1
        fi
        success "Signing key downloaded: ${keyring}"
    fi

    # Step 3 — Verify GPG fingerprint (hard abort on mismatch — do not trust the key)
    info "Verifying GPG key fingerprint..."
    if [[ "$DRY_RUN" == "true" ]]; then
        printf '%s[DRY-RUN]%s would verify fingerprint against: %s\n' \
            "$DIM" "$RESET" "$expected_fp"
    else
        local actual_fp tmp_gnupg
        tmp_gnupg=$(mktemp -d)
        actual_fp=$(
            GNUPGHOME="$tmp_gnupg" gpg -n -q --import --import-options import-show "$keyring" \
                | awk '/pub/{getline; gsub(/^ +| +$/, ""); print $0; exit}'
        )
        rm -rf "$tmp_gnupg"

        if [[ "$actual_fp" != "$expected_fp" ]]; then
            error "GPG fingerprint mismatch — aborting Firefox installation."
            error "  Expected : ${expected_fp}"
            error "  Actual   : ${actual_fp}"
            error "The downloaded key cannot be trusted. Inspect or remove ${keyring}."
            return 1
        fi

        success "Fingerprint verified: ${actual_fp}"
    fi

    # Step 4 — Write apt sources entry
    info "Writing apt source: ${sources}..."
    if [[ "$DRY_RUN" == "true" ]]; then
        printf '%s[DRY-RUN]%s would write %s\n' "$DIM" "$RESET" "$sources"
    else
        cat > "$sources" <<'EOF'
Types: deb
URIs: https://packages.mozilla.org/apt
Suites: mozilla
Components: main
Signed-By: /etc/apt/keyrings/packages.mozilla.org.asc
EOF
        success "Apt source written: ${sources}"
    fi

    # Step 5 — Pin packages.mozilla.org at priority 1000
    info "Writing APT pin: ${prefs}..."
    if [[ "$DRY_RUN" == "true" ]]; then
        printf '%s[DRY-RUN]%s would write %s\n' "$DIM" "$RESET" "$prefs"
    else
        cat > "$prefs" <<'EOF'
Package: *
Pin: origin packages.mozilla.org
Pin-Priority: 1000
EOF
        success "APT pin written: ${prefs}"
    fi

    # Step 6 — apt-get update
    info "Updating package lists..."
    export DEBIAN_FRONTEND=noninteractive

    if ! run apt-get update; then
        error "apt-get update failed."
        error "Check your network connection and apt source configuration."
        return 1
    fi
    success "Package lists updated."

    # Step 7 — Install Firefox
    info "Installing firefox..."
    if ! run apt-get install -y firefox; then
        error "Firefox installation failed."
        error "Check apt output above for details."
        return 1
    fi

    success "Firefox installed successfully from packages.mozilla.org."
}

#######################################
# Phoenix installation
#######################################

install_phoenix() {
    section "Phoenix Installation (download.opensuse.org)"

    local keyring="/etc/apt/trusted.gpg.d/home_celenity.gpg"
    local sources="/etc/apt/sources.list.d/home:celenity.list"
    local key_url="https://download.opensuse.org/repositories/home:celenity/Debian_Unstable/Release.key"
    local repo_url="https://download.opensuse.org/repositories/home:/celenity/Debian_Unstable/"

    # Already installed?
    if dpkg -s phoenix >/dev/null 2>&1 && [[ "$DRY_RUN" != "true" ]]; then
        info "Phoenix is already installed. Skipping."
        return 0
    fi

    # Step 1 — Download and dearmor signing key
    info "Downloading Phoenix repository signing key..."
    if [[ "$DRY_RUN" == "true" ]]; then
        printf '%s[DRY-RUN]%s would download %s → %s\n' "$DIM" "$RESET" "$key_url" "$keyring"
    else
        if ! wget -q "$key_url" -O- | gpg --dearmor | tee "$keyring" > /dev/null; then
            error "Failed to download or dearmor the Phoenix signing key."
            error "Check your network connection and that ${key_url} is reachable."
            return 1
        fi
        success "Signing key written: ${keyring}"
    fi

    # Step 2 — Display fingerprint for manual verification
    # No hardcoded expected fingerprint is published by the project; display it for awareness.
    info "Retrieving key fingerprint for your review..."
    if [[ "$DRY_RUN" != "true" ]]; then
        local fp tmp_gnupg2
        tmp_gnupg2=$(mktemp -d)
        fp=$(GNUPGHOME="$tmp_gnupg2" gpg --no-default-keyring --keyring "$keyring" \
                 --with-colons --fingerprint 2>/dev/null \
                | awk -F: '/^fpr:/{print $10; exit}') || true
        rm -rf "$tmp_gnupg2"

        if [[ -n "$fp" ]]; then
            printf '\n    %s%sKey fingerprint: %s%s\n' "$BOLD" "$CYAN" "$fp" "$RESET"
            printf '    Verify this against: https://codeberg.org/celenity/Phoenix\n\n'
        else
            warn "Could not extract fingerprint from downloaded key — verify ${keyring} manually."
        fi
    fi

    # Step 3 — Write apt sources entry
    info "Writing apt source: ${sources}..."
    if [[ "$DRY_RUN" == "true" ]]; then
        printf '%s[DRY-RUN]%s would write %s\n' "$DIM" "$RESET" "$sources"
    else
        printf 'deb %s /\n' "$repo_url" > "$sources"
        success "Apt source written: ${sources}"
    fi

    # Step 4 — apt-get update
    info "Updating package lists..."
    export DEBIAN_FRONTEND=noninteractive

    if ! run apt-get update; then
        error "apt-get update failed."
        error "Check your network connection and apt source configuration."
        return 1
    fi
    success "Package lists updated."

    # Step 5 — Install Phoenix
    info "Installing phoenix..."
    if ! run apt-get install -y phoenix; then
        error "Phoenix installation failed."
        error "Check apt output above for details."
        return 1
    fi

    success "Phoenix installed successfully."

    # Prominent post-install restart reminder
    printf '\n%s%s' "$BOLD" "$YELLOW"
    printf '╔══════════════════════════════════════════════════╗\n'
    printf '║  ⚠  ACTION REQUIRED AFTER FIRST FIREFOX LAUNCH  ║\n'
    printf '╠══════════════════════════════════════════════════╣\n'
    printf '║  You MUST restart Firefox after its first run    ║\n'
    printf '║  with Phoenix installed.                         ║\n'
    printf '║                                                  ║\n'
    printf '║  First launch → quit Firefox → relaunch          ║\n'
    printf '║  This ensures all Phoenix changes are applied.   ║\n'
    printf '╚══════════════════════════════════════════════════╝\n'
    printf '%s\n' "$RESET"
}

#######################################
# Summary
#######################################

print_summary() {
    printf '\n%s%s' "$BOLD" "$GREEN"
    printf '╔══════════════════════════════════════════╗\n'
    printf '║         All steps completed successfully ║\n'
    printf '╚══════════════════════════════════════════╝\n'
    printf '%s\n' "$RESET"
    printf '  Snapd has been purged, services masked, directories removed,\n'
    printf '  and APT has been pinned to prevent reinstallation.\n'

    if [[ "$INSTALL_FIREFOX" == "true" ]]; then
        printf '  Firefox has been installed from the official Mozilla DEB repository.\n'
    fi

    if [[ "$INSTALL_PHOENIX" == "true" ]]; then
        printf '  Phoenix has been installed from the celenity OBS repository.\n'
        printf '%s  Remember: restart Firefox after its first launch with Phoenix.%s\n' \
            "$YELLOW" "$RESET"
    fi

    printf '\n'
}

#######################################
# Main
#######################################

main() {
    setup_colors
    parse_args "$@"

    require_root
    validate_os
    preflight_checks

    print_banner
    print_warning_summary
    confirm

    remove_snap_packages
    disable_snapd_services
    purge_snapd
    remove_directories
    create_nosnap_preferences
    autoremove_packages
    hold_snap_packages

    if [[ "$INSTALL_FIREFOX" == "true" ]]; then
        install_firefox_deb
    fi

    if [[ "$INSTALL_PHOENIX" == "true" ]]; then
        install_phoenix
    fi

    print_summary
}

main "$@"

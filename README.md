# remove-snapd.sh

Completely removes Snap and Snapd from Ubuntu systems, pins APT to prevent reinstallation, and optionally installs Firefox from the official Mozilla DEB repository along with the Phoenix configuration overlay.

## Requirements

- Ubuntu (tested on 26.04 LTS)
- Root / sudo
- `wget` and `gpg` — only required for `--install-firefox` / `--install-phoenix`

## Usage

```bash
chmod +x remove-snapd.sh
sudo ./remove-snapd.sh [flags]
```

## Flags

| Flag | Description |
|------|-------------|
| `-y`, `--yes` | Skip the confirmation prompt |
| `--dry-run` | Preview all actions without making any changes |
| `--install-firefox` | Install Firefox from packages.mozilla.org after removal |
| `--install-phoenix` | Install Phoenix after Firefox (implies `--install-firefox`) |

All flags can also be set via environment variables: `AUTO_CONFIRM=true`, `DRY_RUN=true`, `INSTALL_FIREFOX=true`, `INSTALL_PHOENIX=true`. Set `NO_COLOR=1` to disable colored output.

## What it does

1. Removes all installed snap packages (dependency-aware, multi-pass)
2. Stops, disables, and masks `snapd.service`, `snapd.socket`, and `snapd.seeded.service`
3. Purges the `snapd` APT package
4. Deletes residual snap directories (`/snap`, `/var/snap`, `/var/lib/snapd`, `/var/cache/snapd`, `~/snap`)
5. Creates an APT pin at `/etc/apt/preferences.d/nosnap.pref` to block reinstallation
6. Runs `apt autoremove --purge` to clean orphaned packages
7. Holds `snap` and `snapd` via `apt-mark hold`

> **Note:** `apt autoremove --purge` removes all orphaned packages system-wide, not just snap-related ones.

## Firefox installation

When `--install-firefox` is used, the script downloads the Mozilla signing key, **verifies its GPG fingerprint** against a hardcoded expected value before trusting it, adds the `packages.mozilla.org` repository, and installs Firefox.

## Phoenix installation

`--install-phoenix` (implies `--install-firefox`) installs the [Phoenix](https://codeberg.org/celenity/Phoenix) Firefox configuration overlay from the celenity OBS repository. After installation, **restart Firefox once** for all Phoenix settings to take effect.

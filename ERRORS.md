# Error codes and troubleshooting

This document explains the exit codes and error markers surfaced by the
plugin panel, grouped by where they originate.

## Process exit codes (shown as `privilege helper exited (<code>)`)

| Code | Meaning | What to do |
|------|---------|------------|
| 0    | Success. | Nothing. |
| 1    | A command or the backend failed (see stderr for detail). | Read the accompanying message; most map to one of the markers below. |
| 127  | "command not found". Most often the privileged helper `/etc/xray-vpn/backend.sh` does not exist. | On first use the panel auto-installs via `pkexec`; if auto-install was dismissed or failed, provision manually with `sudo bash ~/.config/omarchy/plugins/kryaken.omarchy.vless/backend.sh install && omarchy restart shell`. |
| 126  | The helper exists but is not executable, or a permission problem. | Check permissions: `ls -l /etc/xray-vpn/backend.sh`; it should be `-rwxr-xr-x root root`. |

## Serve markers (returned over the serve helper's JSON channel)

| Marker / text | Meaning | What to do |
|---------------|---------|------------|
| `KRYAKEN_HELPER_MISSING` (`No such file or directory: /etc/xray-vpn/backend.sh`) | The root-owned backend was deleted while the session was running. The panel shows a friendly notice; if auto-install was dismissed, recreate manually. | Recreate with `sudo bash ~/.config/omarchy/plugins/kryaken.omarchy.vless/backend.sh install && omarchy restart shell`. Restarting the shell alone will not restore it. |
| `serve: installed backend missing or is a symlink` | `/etc/xray-vpn/backend.sh` is absent or a symlink (security guard). | Reinstall the plugin so the real root-owned file is restored. |
| `serve: installed backend not owned by root (uid=...)` | The helper's owner is not root. | Reinstall the plugin; ensure the file is owned by root. |
| `serve: installed backend is writable by non-root` | Someone other than root can write the helper (security guard). | Reinstall the plugin and fix permissions to `0755 root:root`. |
| `serve: installed factory missing or is a symlink` | `/etc/xray-vpn/factory.py` is absent or a symlink. | Reinstall the plugin. |
| `serve: installed factory not owned by root` | factory.py is not root-owned. | Reinstall the plugin. |
| `serve: installed factory is writable by non-root` | factory.py is writable by non-root. | Reinstall the plugin. |
| `serve: pinned manifest missing or is a symlink` | `/etc/xray-vpn/manifest.sha256` (the pinned hashes of the installed backend/factory) is absent or a symlink. | Reinstall the plugin. |
| `serve: pinned manifest not owned by root` | The manifest's owner is not root. | Reinstall the plugin. |
| `serve: pinned manifest is writable by non-root` | Someone other than root can write the manifest. | Reinstall the plugin and fix permissions to `0644 root:root`. |
| `serve: installed backend/factory failed integrity check` | One of the installed root-owned artifacts no longer matches its pinned SHA-256 (`manifest.sha256`). The helper refuses to run modified code as root. | Reinstall the plugin so the pinned release bytes are restored. |
| `serve error: <python trace>` | An unexpected error inside the privileged helper. | Re-run the failing action; if it persists, collect the panel log (`journalctl --user -u omarchy-shell`) and report it. |

## Onboarding / dependency hints

When a dependency is missing the panel shows a copy-pasteable install command
(`paru/yay/apt`) rather than failing. The plugin itself never downloads or
executes a remote installer.

## Panel first-install pre-flight (refuse to boot a tampered checkout)

Before the first `pkexec` bootstrap the panel hashes the user-writable plugin
checkout and compares it with the release pins embedded in `Panel.qml`; on a
missing or mismatched `backend.sh`, `factory.py` or `SHA256SUMS.txt` it never
starts the privileged install.

| Marker | Meaning | What to do |
|--------|---------|------------|
| `install blocked: plugin files do not match the released version (reinstall the plugin from the store)` | The checkout does not match the reviewed release (tampered artifact, edited copy, or a missing/mismatched `SHA256SUMS.txt`). The panel refuses to run it as root. | Reinstall from the original source (`KryakeN.Omarchy.Vless`); do not run the mismatched script with `sudo`. |

## Copying an error

Tap the red error banner to copy its full text to the clipboard (a brief
"Copied" confirmation is shown in its place). When the error is dependency
driven (starting with `missing ... packet, click to copy install command`)
the tap instead copies the exact install command, e.g. `yay -S xray-bin`.

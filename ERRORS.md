# Error codes and troubleshooting

This document explains the exit codes and error markers surfaced by the
plugin panel, grouped by where they originate.

## Process exit codes (shown as `privilege helper exited (<code>)`)

| Code | Meaning | What to do |
|------|---------|------------|
| 0    | Success. | Nothing. |
| 1    | A command or the backend failed (see stderr for detail). | Read the accompanying message; most map to one of the markers below. |
| 127  | "command not found". Most often the privileged helper `/etc/xray-vpn/backend.sh` does not exist. | `/etc/xray-vpn/` was removed or the plugin was never installed. The panel never re-creates it (restarting the shell will NOT restore it): provision with `sudo bash ~/.config/omarchy/plugins/kryaken.omarchy.vless/backend.sh install`. |
| 126  | The helper exists but is not executable, or a permission problem. | Check permissions: `ls -l /etc/xray-vpn/backend.sh`; it should be `-rwxr-xr-x root root`. |

## Serve markers (returned over the serve helper's JSON channel)

| Marker / text | Meaning | What to do |
|---------------|---------|------------|
| `KRYAKEN_HELPER_MISSING` (`No such file or directory: /etc/xray-vpn/backend.sh`) | The root-owned backend was deleted while the session was running (or on a fresh install before provisioning). The panel shows a friendly notice instead of the raw error. | Recreate it with `sudo bash ~/.config/omarchy/plugins/kryaken.omarchy.vless/backend.sh install`. Restarting the shell alone will not restore it. |
| `serve: installed backend missing or is a symlink` | `/etc/xray-vpn/backend.sh` is absent or a symlink (security guard). | Reinstall the plugin so the real root-owned file is restored. |
| `serve: installed backend not owned by root (uid=...)` | The helper's owner is not root. | Reinstall the plugin; ensure the file is owned by root. |
| `serve: installed backend is writable by non-root` | Someone other than root can write the helper (security guard). | Reinstall the plugin and fix permissions to `0755 root:root`. |
| `serve: installed factory missing or is a symlink` | `/etc/xray-vpn/factory.py` is absent or a symlink. | Reinstall the plugin. |
| `serve: installed factory not owned by root` | factory.py is not root-owned. | Reinstall the plugin. |
| `serve: installed factory is writable by non-root` | factory.py is writable by non-root. | Reinstall the plugin. |
| `serve error: <python trace>` | An unexpected error inside the privileged helper. | Re-run the failing action; if it persists, collect the panel log (`journalctl --user -u omarchy-shell`) and report it. |

## Onboarding / dependency hints

When a dependency is missing the panel shows a copy-pasteable install command
(`paru/yay/apt`) rather than failing. The plugin itself never downloads or
executes a remote installer.

## Copying an error

Tap the red error banner to copy its full text to the clipboard (a brief
"Copied" confirmation is shown in its place).

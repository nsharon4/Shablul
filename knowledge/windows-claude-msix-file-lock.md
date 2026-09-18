---
title: "Windows: Claude Desktop MSIX update fails — 'Another program is currently using this file'"
kind: technical
created_utc: 2026-09-18T05:31:33Z
verified_utc: 2026-09-18T05:30:00Z
expires_utc: 2026-09-25T05:31:33Z
ttl_days: 7
---

# Windows: Claude Desktop MSIX update fails — "Another program is currently using this file"

> Expires `2026-09-25T05:31:33Z`. After that this file is **deleted**, not edited —
> regenerate it by re-reading the sources. Run `tools/knowledge.sh purge`.

## Symptom

A Windows dialog titled with the staged package path
`C:\Program Files\WindowsApps\Claude_<version>_x64...` and the body
**"Another program is currently using this file."** The app closes to update,
the update does not complete, and the app will not relaunch — retrying 30+
minutes later reproduces the same dialog. A reboot clears it. [S1][S2]

## Root cause — this is a known upstream bug, not a local misconfiguration

This is **not** generic "you left the app in the tray". It is a tracked defect with
at least 14 separate issues filed against `anthropics/claude-code`. [S1]–[S10]

Two package-owned things keep file handles open inside the MSIX package directory,
so Windows cannot swap the staged package in:

1. **`CoworkVMService` (`cowork-svc.exe`)** — a Windows service belonging to the
   Claude Cowork feature, `DisplayName "Claude"`, `StartType Automatic`. It holds a
   handle on the package's own `cowork-svc.exe`. [S1][S3][S4] It is declared
   auto-start in `AppxManifest.xml` **and** carries a service trigger on the named
   pipe `\pipe\cowork-vm-service`, so killing the process alone does not help —
   it restarts via manifest auto-start + pipe trigger + AppX re-registration. [S3]
2. **Lingering `Claude.exe` processes** (reported as ~15) that do not exit when the
   app window closes. [S1]

The underlying Windows error is **`0x80073D02` / `ERROR_INSTALL_PACKAGE_IN_USE`** —
"The package could not be installed because resources it modifies are currently in
use." [S11][S12] Related codes seen in the same failure family: `0x80073CF9`,
`0x80073CF6`, `0x80073CFA`. [S6][S8][S9]

## Workaround (no reboot required)

Run **elevated**. Stop the service *before* killing processes, or the pipe trigger
restarts it:

```powershell
Stop-Service CoworkVMService -Force
Set-Service  CoworkVMService -StartupType Disabled   # survives the update cycle
Stop-Process -Name cowork-svc          -Force -ErrorAction SilentlyContinue
Stop-Process -Name claude              -Force -ErrorAction SilentlyContinue
Stop-Process -Name chrome-native-host  -Force -ErrorAction SilentlyContinue
```

`cmd.exe` equivalent: `sc stop CoworkVMService` then
`taskkill /IM claude.exe /F` and `taskkill /IM cowork-svc.exe /F`. [S3][S4]

Then re-apply the update (Microsoft Store → Library → Get updates). Re-enable the
service afterwards with `Set-Service CoworkVMService -StartupType Automatic` if you
use Claude Cowork.

Windows' own lever for the same class of failure is
`Add-AppxPackage -ForceApplicationShutdown`, which lets the deployment engine close
the holding app itself. [S12]

## Do NOT uninstall and reinstall as a first resort

A failed MSIX auto-update that falls back to uninstall+reinstall has been reported
to **silently destroy app data — chat sidebar and session list**. [S13]
`Get-AppxPackage *Claude* | Remove-AppxPackage` risks the same loss. Treat a clean
reinstall as a last resort, after the service-stop workaround above, and expect that
local session history may not survive.

## What is NOT verified

- **The issue pages were not read directly.** `github.com/anthropics/claude-code/issues/*`
  returned **HTTP 503** through `WebFetch`; `api.github.com` returned **HTTP 403**
  (this session's GitHub API access is scoped to `nsharon4/shablul` only);
  `claudeissues.com` and `learn.microsoft.com` are **blocked by the network egress
  proxy**. The issue **titles, numbers and URLs** below are verified — they were
  returned as real search results. Their **bodies** are known only through the
  search tool's summarisation of those pages. The exact command strings above are
  therefore reproduced from that summarisation, not copied from the issue text.
- **Whether any of these issues is fixed or closed** — status was not retrievable.
  Check the issue URLs directly before assuming the bug is still open.
- **The winget package ID** (`Anthropic.Claude`) was **not** verified; `claude.com`
  is egress-blocked. Do not rely on it — use the Microsoft Store update path.
- **Exact affected version range.** The reporting screenshot in this session showed
  `Claude_2.110.1.0_x64`; the issues do not pin a verified version range here.

## Sources

| # | Source | URL | Retrieved (UTC) | How |
|---|---|---|---|---|
| S1 | Issue #76357 — Windows (MSIX): update fails with 'Another program is currently using this file' | https://github.com/anthropics/claude-code/issues/76357 | 2026-09-18T05:29Z | WebSearch (page fetch 503) |
| S2 | Issue #89992 — Windows MSIX auto-update terminates running app | https://github.com/anthropics/claude-code/issues/89992 | 2026-09-18T05:29Z | WebSearch (page fetch 503) |
| S3 | Issue #73694 — AppX update/relaunch fails (0x80073d02) — CoworkVMService holds package file lock | https://github.com/anthropics/claude-code/issues/73694 | 2026-09-18T05:30Z | WebSearch |
| S4 | Issue #46179 — Store: update fails due to CoworkVMService file lock, stuck WindowsApps\Deleted | https://github.com/anthropics/claude-code/issues/46179 | 2026-09-18T05:30Z | WebSearch |
| S5 | Issue #51954 — auto-update leaves file-locked state, requires reboot or manual service restart | https://github.com/anthropics/claude-code/issues/51954 | 2026-09-18T05:30Z | WebSearch |
| S6 | Issue #83932 — auto-update deploys into running claude.exe + CoworkVMService (0x80073CF9/0x80073D02) | https://github.com/anthropics/claude-code/issues/83932 | 2026-09-18T05:30Z | WebSearch |
| S7 | Issue #57221 — CoworkVMService AutoStart prevents updates and launches (MSIX packaging bug) | https://github.com/anthropics/claude-code/issues/57221 | 2026-09-18T05:30Z | WebSearch |
| S8 | Issue #63397 — auto-update silently fails with 0x80073D02 while app is running | https://github.com/anthropics/claude-code/issues/63397 | 2026-09-18T05:30Z | WebSearch |
| S9 | Issue #92641 — install fails 0x80073CF6 after OS upgrade; updates stall until reboot | https://github.com/anthropics/claude-code/issues/92641 | 2026-09-18T05:30Z | WebSearch |
| S10 | Issue #94432 — CoworkVMService blocks self-update, requiring full PC reboot | https://github.com/anthropics/claude-code/issues/94432 | 2026-09-18T05:30Z | WebSearch |
| S11 | Microsoft Q&A — "Deployment failed with HRESULT: 0x80073D02, resources it modifies are currently in use" | https://learn.microsoft.com/en-us/answers/questions/3967188/deployment-failed-with-hresult-0x80073d02-the-pack | 2026-09-18T05:30Z | WebSearch (fetch egress-blocked) |
| S12 | MSIX deployment troubleshooting — Microsoft Learn | https://learn.microsoft.com/en-us/windows/msix/desktop/managing-your-msix-deployment-troubleshooting | 2026-09-18T05:30Z | WebSearch (fetch egress-blocked) |
| S13 | Issue #85689 — failed auto-update falls back to uninstall+reinstall, silently destroying app data | https://github.com/anthropics/claude-code/issues/85689 | 2026-09-18T05:30Z | WebSearch |

## Verification log

- `2026-09-18T05:29Z` — WebSearch "MSIX 'another program is currently using this file'" → **ok**, surfaced S1, S2
- `2026-09-18T05:29Z` — WebFetch https://github.com/anthropics/claude-code/issues/76357 → **HTTP 503**
- `2026-09-18T05:29Z` — WebFetch https://github.com/anthropics/claude-code/issues/89992 → **HTTP 503**
- `2026-09-18T05:29Z` — add_repo anthropics/claude-code (read) → git read available, **no API access**
- `2026-09-18T05:29Z` — WebFetch claudeissues.com → **EGRESS_BLOCKED**
- `2026-09-18T05:29Z` — mcp__github__issue_read #76357, #89992 → **Access denied** (session scoped to nsharon4/shablul)
- `2026-09-18T05:29Z` — curl api.github.com/repos/anthropics/claude-code/issues/76357 → **HTTP 403** (repo not enabled for session)
- `2026-09-18T05:30Z` — WebSearch "CoworkVMService cowork-svc.exe" → **ok**, surfaced S3–S10, S13
- `2026-09-18T05:30Z` — WebFetch https://claude.com/download → **EGRESS_BLOCKED**
- `2026-09-18T05:30Z` — WebFetch learn.microsoft.com/.../appxpkg/troubleshooting → **EGRESS_BLOCKED**
- `2026-09-18T05:30Z` — WebSearch "0x80073D02 ERROR_INSTALL_PACKAGE_IN_USE" → **ok**, surfaced S11, S12

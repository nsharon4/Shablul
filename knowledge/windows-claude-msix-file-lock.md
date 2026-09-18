---
title: "Windows: Claude Desktop MSIX update fails — 'Another program is currently using this file'"
kind: technical
created_utc: 2026-09-18T05:31:33Z
verified_utc: 2026-09-18T06:36:00Z
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

## TWO DISTINCT FAILURE MODES SHARE THIS DIALOG

The same message — "Another program is currently using this file" — is produced by
two unrelated failures. **Diagnose which one before acting**, because the fix for
mode A does nothing for mode B.

| | **Mode A — update blocked by a file lock** | **Mode B — orphaned AppX container** |
|---|---|---|
| Trigger | clicking Relaunch / auto-update | launching after a crash or a stealth update |
| `Get-AppxPackage` `Status` | may be `Staged` / `NeedsRemediation` | **`Ok`** |
| Version after the failure | a newer package is staged | **unchanged** |
| Handle holder | `CoworkVMService` + `Claude.exe` processes | **none in user mode** |
| Underlying error | `0x80073D02` package in use | **`0x80070020`** sharing violation |
| Fix | stop the service, release handles, update | **sign out or reboot** — see below |

### Deciding between them

```powershell
Get-AppxPackage -Name *Claude* | Select-Object Name,Version,PackageFullName,Status,InstallLocation
```

`Status: Ok` **and** an unchanged `Version` **and** no Claude processes running
means **Mode B**. Stopping services will not help; the holder is not in user mode.

### Mode B — orphaned Silo / Job Object — CONFIRMED ON A REAL MACHINE

**Primary evidence, 2026-09-18, from the affected machine's own event log**
(`Microsoft-Windows-AppModel-Runtime/Admin`) — this is a first-hand reading, not
a secondary source:

```
Id 215  Error  0x80070020: Cannot create the Desktop AppX container for package
                Claude_2.110.1.0_x64__pzs8sxrjxfjjc because an error was
                encountered converting the job.

Id 208  Error  0x80070020: Cannot create the process for package
                Claude_2.110.1.0_x64__pzs8sxrjxfjjc because an error was
                encountered while configuring runtime. [LaunchProcess]
```

"converting the **job**" names the Job Object directly. Corroborating state from
the same machine, same session:

- `Get-AppxPackage`: `Status: Ok`, `Version: 2.110.1.0` (unchanged) — no pending update
- Full process sweep: **every** candidate `ParentAlive: True` — **no orphan exists**
- The only package process is `cowork-svc.exe` parented by `services.exe` (the SCM),
  started *after* the failing launch attempts — not a holder
- `CoworkVMService` had been Disabled and Stopped for the failing attempts, so the
  service is ruled out as the cause

This is the complete signature. Mode B is no longer an inference on this machine.

### Mode B — background

The dialog text is **misleading**; the real error is `0x80070020`
(`ERROR_SHARING_VIOLATION`) raised while creating the Desktop AppX container,
before any app code runs. [S31][S32] The previous version's container is still
mounted along with its app-silo registry hive, and on machines where this was
investigated **no user-mode process held any handle into it** — the leftover
reference is on the Windows side. [S33][S34]

One cause that *is* reachable without a reboot: non-PTY child processes spawned by
`claude.exe` (`node`, `cmd`, `powershell`, `ssh`, MCP servers) inherit the package
identity and stay inside the container. While even one survives, the container is
never destroyed. [S34] So sweep for survivors first:

```powershell
Get-Process | Where-Object { $_.Path -like '*WindowsApps*Claude*' } |
  Select-Object Id,Name,Path
Get-CimInstance Win32_Process |
  Where-Object { $_.CommandLine -like '*WindowsApps*Claude*' } |
  Select-Object ProcessId,ParentProcessId,Name,ExecutablePath | Format-Table -Wrap
```

#### Two traps in the survivor sweep — both hit in the field

Observed 2026-09-18, running both queries back to back on the same machine:

1. **`Get-Process | Where-Object { $_.Path -like ... }` returned nothing while
   `Get-CimInstance Win32_Process` found `cowork-svc.exe` running from the package
   directory.** The `Get-Process` form **missed a process that provably existed**.
   Do not treat its empty result as evidence of absence. (Why it missed it —
   reading `.Path` of a 64-bit process from a 32-bit shell, or the process running
   as LocalSystem — is **inference, not tested.**)
2. **Filtering on `CommandLine -like '*WindowsApps*Claude*'` misses the very
   processes being hunted.** An orphaned `node.exe` running an MCP server has a
   command line that names the script, not the package path. The filter was wrong
   for the job.

A sweep that does not fall into either trap enumerates by name and checks whether
the parent is still alive, from a **64-bit** shell:

```powershell
$alive = (Get-CimInstance Win32_Process).ProcessId
Get-CimInstance Win32_Process |
  Where-Object { $_.Name -match '^(node|cmd|powershell|pwsh|ssh|python|bash|claude|cowork-svc|chrome-native-host)\.exe$' } |
  Select-Object ProcessId, ParentProcessId, Name,
    @{n='ParentAlive'; e={ $_.ParentProcessId -in $alive }},
    CreationDate, ExecutablePath, CommandLine |
  Format-Table -Wrap
```

`ParentAlive: False` on a package-related process is the orphan signature. A
`cowork-svc.exe` whose parent is `services.exe` is the service running normally,
not an orphan — check the parent before killing anything:

```powershell
Get-CimInstance Win32_Process -Filter "ProcessId=<parent pid>" | Select-Object ProcessId,Name,ExecutablePath
```

Confirm the diagnosis from the event log — `AppModel-Runtime` IDs **215 / 208**: [S31][S35]

```powershell
Get-WinEvent -LogName 'Microsoft-Windows-AppModel-Runtime/Admin' -MaxEvents 40 |
  Where-Object { $_.Id -in 215,208 } |
  Select-Object TimeCreated,Id,LevelDisplayName,Message | Format-List
```

If no survivor is found — as in the confirmed case above — the documented recovery
is **signing out of Windows or rebooting**; nothing short of that clears the
orphaned container. [S31][S33] Signing out is the lighter option and is reported to
be sufficient. [S31] (*That a logoff tears down the session's job objects is the
obvious mechanism but was **not** verified here; only the empirical "logoff or
reboot recovers" is sourced.*)

Expect recurrence: this is an open upstream defect with roughly twenty separate
issues filed, not a one-off local fault.

## Root cause of Mode A — a known upstream bug, not a local misconfiguration

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

Then re-apply the update by **launching Claude** — see the distribution note below.
**Not** via the Microsoft Store. Re-enable the
service afterwards with `Set-Service CoworkVMService -StartupType Automatic` if you
use Claude Cowork.

Windows' own lever for the same class of failure is
`Add-AppxPackage -ForceApplicationShutdown`, which lets the deployment engine close
the holding app itself. [S12]

## Field report: `Set-Service -StartupType Disabled` fails with "Access is denied"

Observed on a real machine, 2026-09-18: in the same elevated PowerShell block,
`Stop-Service CoworkVMService -Force` **succeeded** while
`Set-Service CoworkVMService -StartupType Disabled` **failed** with
`PermissionDenied ... CouldNotSetService`.

**Elevation confirmed by direct observation**, 2026-09-18: the PowerShell window
title read `Administrator: Windows PowerShell (x86)` while `Stop-Service` succeeded
and `Set-Service` was denied in that same session. A non-elevated shell would have
failed the stop as well, so elevation is ruled out as the cause.

That split — stop allowed, reconfigure
denied — is the signature of a service whose SCM security descriptor grants
`SERVICE_STOP` but not `SERVICE_CHANGE_CONFIG`. The MSIX-installed
`CoworkVMService` carries a descriptor that does not grant Administrators
`SERVICE_CHANGE_CONFIG`, so SCM refuses the change regardless of elevation. [S14][S15]
The same missing right is why the service cannot configure its own SCM recovery
actions, reported separately as "Access is denied". [S16][S17]

That failure has a direct consequence for the update: because the service cannot
disarm its own auto-restart policy before stopping, a slow stop during package
servicing lets SCM restart it mid-update, re-locking the files the updater is
replacing. [S15]

### Registry route (bypasses the SCM DACL)

`Start` is a `REG_DWORD` under `HKLM\SYSTEM\CurrentControlSet\Services\<name>`:

| Value | Meaning |
|---|---|
| 0 | Boot |
| 1 | System |
| 2 | **Automatic** |
| 3 | **Demand / Manual** |
| 4 | **Disabled** |

[S18][S19]

> **Confirmed in the field 2026-09-18:** writing `4` produced
> `Get-Service CoworkVMService` → `Status: Stopped, StartType: Disabled`, with no
> `claude`, `cowork-svc` or `chrome-native-host` processes left running.
>
> **Correction recorded.** A search-engine summary of the community workaround
> stated "value 3 represents Disabled ... 4 for Manual". That is **wrong and
> inverted**: `3` is Demand/Manual, `4` is Disabled. Setting `3` would leave the
> service demand-startable — and `CoworkVMService` has a named-pipe start trigger,
> so it would still come back. Use `4`.

```powershell
# record the original value first
(Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\CoworkVMService').Start
Set-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Services\CoworkVMService' -Name Start -Value 4
```

Restore with `-Value 2` (Automatic) afterwards. Note that AppX re-registration can
rewrite the service config back from `AppxManifest.xml`, so a disable is not
guaranteed to survive the update. [S7]

### Use a 64-bit shell

The observed session was `Windows PowerShell (x86)`. Two WOW64 effects apply to a
32-bit process on 64-bit Windows:

- **Registry redirection** targets `HKLM\Software` → `HKLM\Software\Wow6432Node`.
  `HKLM\SYSTEM` is **not** in the redirected set. [S22][S23] **Confirmed
  empirically 2026-09-18:** a `Start` write issued from `Windows PowerShell (x86)`
  was reflected in SCM's own view — `Get-Service` then reported
  `StartType: Disabled` — so the 32-bit write reached the real key.
- **File system redirection** sends `C:\Windows\System32` to `C:\Windows\SysWOW64`,
  so `sc.exe` invoked from a 32-bit shell is the 32-bit build. Use
  `C:\Windows\Sysnative\sc.exe` to reach the 64-bit one.

Simplest mitigation: run the whole procedure from 64-bit `Windows PowerShell`
(Start menu entry **without** "(x86)"), which removes the question entirely.

### Hazard: never write `Start` from an undefined variable

A restore snippet of the form
`Set-ItemProperty ... -Name Start -Value $orig` is only safe in the **same**
shell session that captured `$orig`. Pasted into a fresh window, `$orig` is
`$null`. **RESOLVED by direct observation, 2026-09-18.** The command ran with no error,
and a later read-back in the same environment returned `Original Start = 0`.
`Set-ItemProperty -Name Start -Value $null` on this REG_DWORD **writes `0`** —
PowerShell coerces `$null` to `0` (`[int]$null` is `0` [S24]). It is not a
parameter-binder no-op. The original `2` was destroyed by that write.

`Start = 0` is `SERVICE_BOOT_START`, which is **valid only for driver services**,
not for a Win32 service like `CoworkVMService`. [S25][S26] It is an invalid
configuration for this service even though the running system tolerates it (the
subsequent `Start-Service` succeeded, so nothing was bricked).

**Rule: always write the literal, always pass `-Type DWord`, always read back.**

### Pin the expected value to the stage

A bare "read it back, expect 2" instruction is ambiguous once the procedure has
more than one write in it — the correct value depends on where you are. State the
stage with the expectation:

| Stage | `Start` | `Get-Service` StartType |
|---|---|---|
| Diagnosis, before any change | `2` | Automatic |
| After the disable block, before the package update | `4` | Disabled |
| After restore | `2` | Automatic |

Observed 2026-09-18: `Original Start = 0` → `New Start = 4` → `Stopped / Disabled`
→ independent read-back `4`. Consistent throughout.

```powershell
$key = 'HKLM:\SYSTEM\CurrentControlSet\Services\CoworkVMService'
(Get-ItemProperty $key).Start                       # read BEFORE
Set-ItemProperty -Path $key -Name Start -Value 2 -Type DWord   # 2 = Automatic
(Get-ItemProperty $key).Start                       # read AFTER
```

### Caveat

Disabling `CoworkVMService` disables the Claude Cowork feature. Issue #77618
reports the service being *found* in a Disabled state as its own failure mode, so
this is a temporary measure for the update window, not a permanent setting. [S20]

## How the update is actually delivered — NOT the Microsoft Store

**Correction.** Earlier guidance in this note pointed at
Microsoft Store → Library → Get updates. That is **wrong for this app.**

Claude Desktop for Windows is distributed as a **sideloaded, developer-signed
MSIX package**, not through the Microsoft Store. [S27] It therefore never appears
in the Store's Library, and a Library search for it correctly returns nothing —
confirmed on the affected machine 2026-09-18.

Updates come from an **in-app self-updater**: the app quits itself, swaps its MSIX
package, and relaunches, with a check roughly every 6 hours. [S27][S28] The failure
mode in this note is precisely that path — the updater downloads and **stages** the
new version, then registration is deferred because the running app holds file
locks, so the update never completes. [S27]

**So the step after releasing the lock is simply to launch Claude**, not to visit
the Store.

Inspect the package state with the `Appx` module, from a 64-bit shell:

```powershell
Get-AppxPackage -Name *Claude* | Select-Object Name,Version,PackageFullName,Status,InstallLocation
```

A `Status` of `Staged` or `NeedsRemediation` rather than `Ok` indicates a package
that registered incompletely. [S29][S30]

Anthropic moved the Windows installer from the older Squirrel `.exe` format to MSIX
around February 2026, alongside shipping Cowork. [S29]

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
- **The `Start` value table and the SCM DACL explanation** come from search-engine
  summarisation. Direct fetch of `learn.microsoft.com`, `winreg-kb.readthedocs.io`
  (both **EGRESS_BLOCKED**) and `gist.github.com` (**HTTP 503**) all failed. The
  0-4 mapping was confirmed by two independent searches agreeing; the inverted
  claim from a third was rejected.
- **Whether the `Appx` module misbehaves in 32-bit PowerShell on 64-bit Windows**
  was searched for and **not answered** by any source reached. Treat it as unknown;
  the recommendation to use a 64-bit shell is precaution, not a documented defect.
- **The official distribution/update documentation was not read directly.**
  `support.claude.com` and `downloads.claude.ai` are both **EGRESS_BLOCKED**. The
  sideloaded-MSIX and self-updater claims rest on search summarisation of upstream
  issues, corroborated by the machine-side observation that Claude is absent from
  the Store Library.
- **The actual security descriptor of `CoworkVMService` was not read.** Nobody has
  run `sc.exe sdshow CoworkVMService` here. The DACL explanation is inference
  consistent with the observed stop-ok / configure-denied split, not a direct read.
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
| S14 | Issue #57371 — provide a way to disable the bundled CoworkVMService | https://github.com/anthropics/claude-code/issues/57371 | 2026-09-18T05:38Z | WebSearch |
| S15 | Issue #92092 — CoworkVMService fails to configure/disarm SCM recovery actions ("Access is denied") | https://github.com/anthropics/claude-code/issues/92092 | 2026-09-18T05:38Z | WebSearch |
| S16 | Issue #93633 — CoworkVMService cannot set its own SCM recovery actions ("Access is denied") | https://github.com/anthropics/claude-code/issues/93633 | 2026-09-18T05:38Z | WebSearch |
| S17 | Issue #92182 — packaged service lifecycle corrupts MSIX package ACLs | https://github.com/anthropics/claude-code/issues/92182 | 2026-09-18T05:38Z | WebSearch |
| S18 | HKLM\SYSTEM\CurrentControlSet\Services Registry Tree — Microsoft Learn | https://learn.microsoft.com/en-us/windows-hardware/drivers/install/hklm-system-currentcontrolset-services-registry-tree | 2026-09-18T05:39Z | WebSearch (fetch egress-blocked) |
| S19 | winreg-kb — Services and drivers | https://winreg-kb.readthedocs.io/en/latest/sources/system-keys/Services-and-drivers.html | 2026-09-18T05:39Z | WebSearch (fetch egress-blocked) |
| S20 | Issue #77618 — CoworkVMService found in Disabled state | https://github.com/anthropics/claude-code/issues/77618 | 2026-09-18T05:38Z | WebSearch |
| S21 | Issue #91736 — cowork-svc.exe in an SCM restart loop, only reboot recovers (0x80070020) | https://github.com/anthropics/claude-code/issues/91736 | 2026-09-18T05:38Z | WebSearch |
| S22 | Registry Redirector — Microsoft Learn | https://learn.microsoft.com/en-us/windows/win32/winprog64/registry-redirector | 2026-09-18T05:44Z | WebSearch (fetch egress-blocked) |
| S23 | Registry Keys Affected by WOW64 — Microsoft Learn | https://learn.microsoft.com/en-us/windows/win32/winprog64/shared-registry-keys | 2026-09-18T05:44Z | WebSearch (fetch egress-blocked) |
| S24 | PowerShell int conversion: `[int]$null` is 0 | https://powershellfaqs.com/powershell-cannot-convert-value-to-type-system-int32/ | 2026-09-18T05:51Z | WebSearch |
| S25 | CreateServiceA — SERVICE_BOOT_START valid only for driver services | https://learn.microsoft.com/en-us/windows/win32/api/Winsvc/nf-winsvc-createservicea | 2026-09-18T05:51Z | WebSearch (fetch egress-blocked) |
| S26 | Service Startup — Microsoft Learn | https://learn.microsoft.com/en-us/windows/win32/services/service-startup | 2026-09-18T05:51Z | WebSearch (fetch egress-blocked) |
| S27 | Issue #63397 — MSIX auto-update silently fails 0x80073D02 while app is running (sideloaded, dev-signed MSIX; self-update mechanism) | https://github.com/anthropics/claude-code/issues/63397 | 2026-09-18T06:08Z | WebSearch |
| S28 | Issue #92246 — desktop app self-updates and restarts over a running session | https://github.com/anthropics/claude-code/issues/92246 | 2026-09-18T06:08Z | WebSearch |
| S29 | Issue #47877 — installation broken, MSIX stuck in Staged state; Squirrel→MSIX transition ~Feb 2026 | https://github.com/anthropics/claude-code/issues/47877 | 2026-09-18T06:08Z | WebSearch |
| S30 | Deploy Claude Desktop for Windows — Claude Help Center | https://support.claude.com/en/articles/12622703-deploy-claude-desktop-for-windows | 2026-09-18T06:08Z | WebSearch (fetch egress-blocked) |
| S31 | Issue #53247 — orphaned Silo / Job Object after crash, only logoff or reboot recovers (0x80070020, AppModel-Runtime 215/208) | https://github.com/anthropics/claude-code/issues/53247 | 2026-09-18T06:18Z | WebSearch |
| S32 | Issue #92202 — fails to launch, 0x80070020 when creating the Desktop AppX container | https://github.com/anthropics/claude-code/issues/92202 | 2026-09-18T06:18Z | WebSearch |
| S33 | Issue #95266 — old app container stays mounted with no process holding it | https://github.com/anthropics/claude-code/issues/95266 | 2026-09-18T06:18Z | WebSearch |
| S34 | Issue #92167 — non-PTY children keep the AppX container and app-silo hive mounted | https://github.com/anthropics/claude-code/issues/92167 | 2026-09-18T06:18Z | WebSearch |
| S35 | Issue #92961 — "Another program..." after a crash; no pending update, no usermode handle holder, package cleanly registered | https://github.com/anthropics/claude-code/issues/92961 | 2026-09-18T06:18Z | WebSearch |
| S36 | Issue #73107 — container silo pinned by an orphaned elevated Claude Code child process | https://github.com/anthropics/claude-code/issues/73107 | 2026-09-18T06:18Z | WebSearch |
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
- `2026-09-18T05:38Z` — WebSearch "CoworkVMService Set-Service Access is denied" → **ok**, surfaced S14, S16, S20, S21
- `2026-09-18T05:38Z` — WebSearch "MSIX packaged service SCM DACL access denied" → **ok**, surfaced S15, S17
- `2026-09-18T05:39Z` — WebSearch service `Start` REG_DWORD values → **ok**, two independent confirmations of 4=Disabled; one summary claiming 3=Disabled **rejected as wrong**
- `2026-09-18T05:39Z` — WebFetch winreg-kb.readthedocs.io → **EGRESS_BLOCKED**
- `2026-09-18T05:39Z` — WebFetch gist.github.com/jeremyjohn/133697b2... → **HTTP 503**
- `2026-09-18T05:44Z` — user screenshot: title bar `Administrator: Windows PowerShell (x86)`, Stop-Service clean, Set-Service denied → **elevation confirmed**, DACL inference upgraded
- `2026-09-18T05:44Z` — WebSearch WOW64 registry redirection scope → **ok**, HKLM\Software redirected; HKLM\SYSTEM not in the redirected set
- `2026-09-18T05:44Z` — WebSearch Appx module under 32-bit PowerShell → **no source answered the question**; left UNVERIFIED
- `2026-09-18T05:51Z` — WebSearch `Set-ItemProperty -Value $null` on REG_DWORD → **inconclusive**; `[int]$null` = 0 confirmed, binder behaviour not documented
- `2026-09-18T05:51Z` — WebSearch service Start=0 semantics → **ok**, SERVICE_BOOT_START is driver-only (S25, S26)
- `2026-09-18T05:55Z` — user screenshot: `Original Start = 0`, `New Start = 4`, `CoworkVMService Stopped Disabled`, Get-Process empty → **`-Value $null` writes 0 CONFIRMED**; **32-bit write to HKLM\SYSTEM reaches the real key CONFIRMED**; disable-and-stop procedure verified working
- `2026-09-18T06:02Z` — user read-back returned `4` at the post-disable stage, matching the disable block; earlier "expect 2" guidance was stage-ambiguous and is now pinned per stage in this note
- `2026-09-18T06:08Z` — user screenshot: Store Library search "Cla" returns only ChatGPT Classic, **no Claude** → corroborates sideloaded, non-Store distribution
- `2026-09-18T06:08Z` — WebSearch Claude Desktop MSIX update mechanism → **ok**, sideloaded dev-signed MSIX + in-app self-updater (~6h checks), S27–S29
- `2026-09-18T06:09Z` — WebFetch support.claude.com → **EGRESS_BLOCKED**
- `2026-09-18T06:09Z` — WebFetch downloads.claude.ai → **EGRESS_BLOCKED**
- `2026-09-18T06:18Z` — user output: `Status: Ok`, `Version: 2.110.1.0` unchanged, no Claude processes, launch still fails → **re-diagnosed as Mode B (orphaned container), not Mode A (file lock)**
- `2026-09-18T06:18Z` — WebSearch issue #92961 → **ok**, matches this signature exactly (crash, no pending update, no usermode holder)
- `2026-09-18T06:18Z` — WebSearch 0x80070020 orphaned Silo/Job → **ok**, S31–S34, S36; documented recovery is logoff or reboot
- `2026-09-18T06:28Z` — user output: `Get-Process` path filter returned nothing while CIM found `cowork-svc.exe` in the package dir → **`Get-Process` sweep proven unreliable here**; CommandLine filter also identified as unable to match orphaned MCP children. Sweep recorded as inconclusive, not negative.
- `2026-09-18T06:28Z` — user output: `RESTORED: 2`, service started → CoworkVMService returned to Automatic
- `2026-09-18T06:36Z` — user event log, read first-hand: **AppModel-Runtime 215 + 208, `0x80070020`, "converting the job"**, package `Claude_2.110.1.0_x64__pzs8sxrjxfjjc` → **Mode B CONFIRMED**, no longer inference
- `2026-09-18T06:36Z` — user process sweep: all candidates `ParentAlive: True`; only package process is `cowork-svc.exe` parented by `services.exe` (PID 2020), started after the failing launches → **no orphaned holder; service ruled out**

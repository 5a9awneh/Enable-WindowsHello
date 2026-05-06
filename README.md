# Enable-WindowsHello

<!-- BADGES:START -->
[![License](https://img.shields.io/github/license/5a9awneh/Enable-WindowsHello)](LICENSE) [![PowerShell](https://img.shields.io/badge/PowerShell-5.1%2B-blue?style=flat&logo=powershell)](https://learn.microsoft.com/en-us/powershell/) [![Windows](https://img.shields.io/badge/Windows-0078D6?style=flat&logo=windows&logoColor=white)](https://www.microsoft.com/windows) [![Last Commit](https://img.shields.io/github/last-commit/5a9awneh/Enable-WindowsHello)](https://github.com/5a9awneh/Enable-WindowsHello/commits/main) [![Tests](https://img.shields.io/badge/tests-56%20passing-success?style=flat)](https://github.com/5a9awneh/Enable-WindowsHello) [![Status](https://img.shields.io/badge/status-production%20ready-brightgreen?style=flat)](https://github.com/5a9awneh/Enable-WindowsHello) [![Runs Locally](https://img.shields.io/badge/runs_locally-privacy--first-green?style=flat)](https://github.com/5a9awneh/Enable-WindowsHello) [![Human in the Loop](https://img.shields.io/badge/human--in--the--loop-%E2%9C%93-brightgreen?style=flat)](https://github.com/5a9awneh/Enable-WindowsHello)
<!-- BADGES:END -->

Fix Windows Hello (PIN + Fingerprint) provisioning on Entra ID joined devices where Intune's cert-trust WHfB policy blocks enrollment.

## 🚫 The Problem

On Intune-managed, Entra ID joined Windows devices, a certificate-trust Windows Hello for Business (WHfB) policy can silently block Hello provisioning. The device shows no PIN or fingerprint option in **Settings > Sign-in options**, and `dsregcmd /status` never reports `PreReqResult: WillProvision`.

### 🔍 Root Cause

The WHfB provisioning engine reads `UseCertificateForOnPremAuth` from the **per-user HKCU** policy path — not from HKLM. Intune pushes `cert-trust = 1` to HKCU via per-user CSP, which blocks provisioning even when HKLM says `0`. This HKCU override is invisible in Group Policy Editor and undocumented in most troubleshooting guides.

## 💡 The Fix

This script neutralizes the cert-trust gate by writing `UseCertificateForOnPremAuth = 0` to all three policy layers:

| Layer | Registry Path | Why |
|---|---|---|
| **HKLM GP** | `HKLM:\SOFTWARE\Policies\Microsoft\PassportForWork` | ADMX-backed policy (gpedit equivalent) |
| **HKCU Per-User** | `HKCU:\SOFTWARE\Policies\Microsoft\PassportForWork` | **The actual breakthrough** — where the engine reads the value |
| **MDM/CSP Tenant** | `HKLM:\SOFTWARE\Microsoft\Policies\PassportForWork\{TenantGUID}\...` | Overrides Intune-pushed values during CXH provisioning |

It also enables convenience PIN, biometrics, and domain PIN logon, then opens **Settings > Sign-in options** for immediate in-session enrollment — no sign-out required.

## 🎛️ Modes

| Mode | What it does |
|---|---|
| **Apply** | Full fix: preflight checks → registry backup → neutralize cert-trust → enable PIN/biometrics → open Settings for enrollment → verify NGC provisioning |
| **Rollback** | Restore registry from a previous backup (`.reg` files). Supports multiple backup snapshots |
| **Reset** | Remove all script-written values and let Intune re-push defaults. Optionally clears the NGC container and triggers MDM sync |
| **Status** | Read-only system check: Entra join, PRT, TPM, WinBio, all registry values, provisioning verdict |

## 🗺️ How It Works

```mermaid
flowchart TD
    Start([Run script]) --> Menu{Mode?}

    Menu -->|Apply| PF[Preflight checks]
    Menu -->|Rollback| RB[Select backup snapshot]
    Menu -->|Reset| RS[Remove script values]
    Menu -->|Status| ST[Read-only system check]

    PF --> PF1{Entra joined?\nPRT valid?\nTPM ready?}
    PF1 -->|❌ Fail| Abort([Abort with guidance])
    PF1 -->|✅ Pass| BAK[Registry backup\n.reg exports to TEMP]

    BAK --> W1[Write HKLM GP layer\nUseCertificateForOnPremAuth=0]
    W1 --> W2[Write HKCU per-user layer\nUseCertificateForOnPremAuth=0]
    W2 --> W3[Write MDM/CSP tenant layer\nOverride Intune push]
    W3 --> PIN[Enable PIN + Biometrics\n+ Domain PIN logon]
    PIN --> VER{Post-write\nverification}
    VER -->|❌ Values reverted| AutoRB[Auto-rollback prompt]
    VER -->|✅ Confirmed| Settings[Open Settings → Sign-in options]
    Settings --> NGC[Poll NGC container\nfor provisioning]
    NGC --> Done([✅ Hello ready])

    RB --> RB2[Restore .reg files]
    RB2 --> SO1[Optional sign-out countdown]

    RS --> RS2[Remove all script keys]
    RS2 --> NGC2[Optional NGC clear\n+ MDM sync]
    NGC2 --> SO2[Optional sign-out countdown]

    ST --> ST2[Report: Entra join, PRT,\nTPM, WinBio, registry values,\nprovisioning verdict]

    style PF1 fill:#7a5500,color:#fff
    style VER fill:#7a5500,color:#fff
    style Done fill:#2d6a2d,color:#fff
    style Abort fill:#8b1a1a,color:#fff
    style AutoRB fill:#8b1a1a,color:#fff
```

## �️ Sample Output

**Interactive menu** (when run without `-Mode`):

```
  Enable-WindowsHello -- Windows Hello Provisioning Tool

  1. Apply fix     Neutralize policy + enable Hello
  2. Rollback      Restore from backup (.reg files)
  3. Reset         Remove script changes (no backup)
  4. Status        Show current system & registry state

Select [1-4]:
```

**Status mode** (`-Mode Status`):

```
[INFO] ═══ Enable-WindowsHello -- STATUS CHECK ═══
[OK]   Entra ID Joined : YES
[OK]   AzureAd PRT     : Valid
[OK]   NGC Seeded      : YES
[OK]   TPM 2.0 Ready   : YES
[OK]   WinBio Service  : Running
       PreReqResult    : N/A (only visible during provisioning)

       Registry values:
       HKLM  UseCertificateForOnPremAuth  : 0  [OK]
       HKCU  UseCertificateForOnPremAuth  : 0  [OK - breakthrough]
       MDM   UseCertificateForOnPremAuth  : 0  [OK]
       HKLM  Enabled                      : 1  [OK]
       HKLM  UseCloudTrustForOnPremAuth   : 1  [OK]

[OK]   VERDICT: Hello is provisioned and all registry values are correctly set.
[INFO] ═══ Status check completed ═══
```

## �🚀 Quick Start

### Option 1: Double-click

Run `RUN.cmd` — it auto-elevates to Administrator and shows the interactive menu.

### Option 2: PowerShell

```powershell
# Interactive menu
.\Enable-WindowsHello.ps1

# Direct mode
.\Enable-WindowsHello.ps1 -Mode Status
.\Enable-WindowsHello.ps1 -Mode Apply
.\Enable-WindowsHello.ps1 -Mode Rollback
.\Enable-WindowsHello.ps1 -Mode Reset
```

> **Requires:** Administrator elevation, Windows 10/11, Entra ID joined device.

## 🛡️ Safety Features

- 💾 **Registry backup** before any writes (timestamped `.reg` exports in `%TEMP%`)
- ✅ **Post-write verification** — every `Set-RegValue` is followed by `Test-RegValue`
- ↩️ **Auto-rollback prompt** if verification detects values were reverted by Intune/MDM
- 📝 **Timestamped log** saved to `%TEMP%\EnableHello_*.log`
- ⚡ **No sign-out required** for Apply mode — HKCU override takes effect immediately
- ⏱️ **Rollback** and **Reset** offer a sign-out prompt with a 10-second cancellable countdown

## 🔎 Preflight Checks (Apply Mode)

Before making any changes, the script verifies:

- Entra ID join status (`AzureAdJoined: YES`)
- Primary Refresh Token validity (`AzureAdPrt: YES`)
- TPM 2.0 readiness (via WHfB event log)
- WinBio service status (auto-starts if stopped)
- NGC container state (detects prior provisioning)

## 🧪 Testing

The project includes a [Pester 5](https://pester.dev/) test suite with 56 tests.

```powershell
# Mock tests only (safe anywhere, no admin needed)
Invoke-Pester .\Enable-WindowsHello.Tests.ps1 -ExcludeTag 'Live' -Output Detailed

# Live tests (runs Status mode on real system, requires admin)
Invoke-Pester .\Enable-WindowsHello.Tests.ps1 -Tag 'Live' -Output Detailed

# All tests
Invoke-Pester .\Enable-WindowsHello.Tests.ps1 -Output Detailed
```

Or use `RUN-TESTS.cmd`:

```
RUN-TESTS.cmd          # mock only (default)
RUN-TESTS.cmd live     # live only
RUN-TESTS.cmd all      # both
```

### 📊 Test Coverage

- **47 mock tests**: function unit tests (Write-Log, Set-RegValue, Test-RegValue, Get-TenantGuid, Invoke-Rollback), registry coverage completeness, backup/rollback symmetry, preflight checks, safety features, interactive menu, HKCU cert-trust breakthrough validation
- **9 live tests**: real Status mode execution, system state reporting, registry reads, verdict output, log file creation

## 📁 Files

| File | Purpose |
|---|---|
| `Enable-WindowsHello.ps1` | Main script (4 modes) |
| `Enable-WindowsHello.Tests.ps1` | Pester 5 test suite (56 tests) |
| `RUN.cmd` | Double-click launcher with auto-elevation |
| `RUN-TESTS.cmd` | Test runner (mock / live / all) |
| `README.md` | Project documentation |
| `LICENSE` | MIT license |

## ⚙️ Requirements

- Windows 10/11
- PowerShell 5.1+
- Administrator privileges
- Entra ID (Azure AD) joined device
- Intune-enrolled (for MDM/CSP layer)

## 🖥️ Tested On

- Windows 11, Entra ID joined, Intune enrolled, ST Micro TPM 2.0

## 📄 License

MIT — see [LICENSE](LICENSE). Attribution required.

#Requires -RunAsAdministrator
param(
    [ValidateSet('Apply', 'Rollback', 'Reset', 'Status')]
    [string]$Mode
)
<#
.SYNOPSIS
    Enable Windows Hello (PIN + Fingerprint) on Entra ID joined devices
    where Intune cert-trust WHFB policy blocks provisioning.
.DESCRIPTION
    The WHfB engine evaluates UseCertificateForOnPremAuth from the per-user
    HKCU policy path, NOT from HKLM.  This script writes the override to
    both HKLM (GP + MDM) and HKCU to ensure the cert-trust gate is cleared.
.PARAMETER Mode
    Apply    - Run the fix (default, interactive menu if omitted).
    Rollback - Restore registry from the most recent backup (.reg files).
    Reset    - Remove all script-written values; lets Intune re-push defaults.
    Status   - Show current system state, registry values, and provisioning verdict.
.NOTES
    Tested on: Windows 11, Entra ID joined, Intune enrolled, ST Micro TPM 2.0
    Run as: Administrator
#>

# ── Config ────────────────────────────────────────────────────────────────────
$LogFile = "$env:TEMP\EnableHello_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"
$BackupDir = "$env:TEMP\EnableHello_Backup_$(Get-Date -Format 'yyyyMMdd_HHmmss')"
$script:CriticalFailure = $false

# ── Logging ───────────────────────────────────────────────────────────────────
function Write-Log {
    param([string]$Message, [ValidateSet('INFO', 'WARN', 'ERROR', 'OK')]$Level = 'INFO')
    $colors = @{ INFO = 'Cyan'; WARN = 'Yellow'; ERROR = 'Red'; OK = 'Green' }
    $entry = "[$(Get-Date -Format 'HH:mm:ss')] [$Level] $Message"
    Add-Content -Path $LogFile -Value $entry
    Write-Host $entry -ForegroundColor $colors[$Level]
}

function Exit-Script {
    param([int]$Code, [string]$Reason)
    Write-Log $Reason $(if ($Code -eq 0) { 'OK' } else { 'ERROR' })
    Write-Log "Log saved to: $LogFile" 'INFO'
    exit $Code
}

# ── Helper: Set registry key, create path if missing ─────────────────────────
function Set-RegValue {
    param($Path, $Name, $Value, $Type = 'DWord')
    try {
        if (!(Test-Path $Path)) { New-Item $Path -Force | Out-Null }
        Set-ItemProperty -Path $Path -Name $Name -Value $Value -Type $Type -Force
        Write-Log "  SET $Path\$Name = $Value" 'INFO'
    }
    catch {
        Write-Log "  FAILED $Path\$Name : $_" 'ERROR'
        $script:CriticalFailure = $true
    }
}

# ── Helper: Verify a registry value matches expected ─────────────────────────
function Test-RegValue {
    param($Path, $Name, $Expected)
    try {
        $actual = (Get-ItemProperty -Path $Path -Name $Name -EA Stop).$Name
        if ($actual -eq $Expected) {
            Write-Log "  VERIFIED $Path\$Name = $actual" 'OK'
            return $true
        }
        else {
            Write-Log "  MISMATCH $Path\$Name -- expected $Expected, got $actual (another process may be overwriting)" 'ERROR'
            $script:CriticalFailure = $true
            return $false
        }
    }
    catch {
        Write-Log "  VERIFY FAILED $Path\$Name : $_" 'ERROR'
        $script:CriticalFailure = $true
        return $false
    }
}

# ══════════════════════════════════════════════════════════════════════════════

# ── Shared: import .reg files from a backup folder ────────────────────────────
function Invoke-Rollback {
    param([string]$BackupPath)
    $regFiles = Get-ChildItem $BackupPath -Filter "*.reg" -EA SilentlyContinue
    if (-not $regFiles) {
        Write-Log "Backup folder contains no .reg files -- rollback skipped." 'ERROR'
        return $false
    }
    $failures = 0
    foreach ($regFile in $regFiles) {
        Write-Log "  Importing $($regFile.Name)..." 'INFO'
        $null = reg import $regFile.FullName 2>&1
        if ($LASTEXITCODE -eq 0) {
            Write-Log "  Restored $($regFile.Name)" 'OK'
        }
        else {
            Write-Log "  FAILED to import $($regFile.Name)" 'ERROR'
            $failures++
        }
    }
    if ($failures -eq 0) {
        Write-Log "All $($regFiles.Count) registry backups restored successfully." 'OK'
        return $true
    }
    else {
        Write-Log "$failures of $($regFiles.Count) imports failed. Check log for details." 'ERROR'
        return $false
    }
}

# ── Shared: sign-out prompt (used by Rollback/Reset only) ─────────────────────
function Invoke-SignOutPrompt {
    param([string]$Label)
    Write-Host ""
    Write-Host "  A sign-out is recommended so restored/cleared policies take effect." -ForegroundColor Cyan
    $response = Read-Host "  Sign out now? [y/N]"
    if ($response -match '^[Yy]$') {
        Write-Log "User chose to sign out." 'INFO'
        Write-Log "═══ $Label completed ═══" 'OK'
        Write-Log "Log saved to: $LogFile" 'INFO'
        for ($i = 10; $i -gt 0; $i--) {
            Write-Host "  Signing out in $i seconds... (Ctrl+C to cancel)" -ForegroundColor Yellow
            Start-Sleep 1
        }
        shutdown.exe /l
    }
    else {
        Write-Log "Sign-out skipped by user." 'INFO'
        Write-Log "═══ $Label completed ═══" 'OK'
        Write-Log "Log saved to: $LogFile" 'INFO'
    }
}

# ── Shared: discover Entra tenant GUID from MDM registry or dsregcmd ─────────
function Get-TenantGuid {
    param([string[]]$DsregOutput)
    $mdmPfwRoot = "HKLM:\SOFTWARE\Microsoft\Policies\PassportForWork"
    $guid = $null
    if (Test-Path $mdmPfwRoot) {
        $guid = (Get-ChildItem $mdmPfwRoot -EA SilentlyContinue |
            Where-Object { $_.PSChildName -match '^[0-9a-f]{8}-([0-9a-f]{4}-){3}[0-9a-f]{12}$' } |
            Select-Object -First 1).PSChildName
    }
    if (-not $guid -and $DsregOutput) {
        $guid = ($DsregOutput | Select-String 'TenantId\s*:\s*(\S+)' |
            ForEach-Object { $_.Matches[0].Groups[1].Value } | Select-Object -First 1)
    }
    return $guid
}

# ── Interactive menu (when -Mode not specified) ───────────────────────────────
if (-not $Mode) {
    Write-Host ""
    Write-Host "  Enable-WindowsHello -- Windows Hello Provisioning Tool" -ForegroundColor Cyan
    Write-Host "  1. Apply fix     Neutralize policy + enable Hello" -ForegroundColor Cyan
    Write-Host "  2. Rollback      Restore from backup (.reg files)" -ForegroundColor Cyan
    Write-Host "  3. Reset         Remove script changes (no backup)" -ForegroundColor Cyan
    Write-Host "  4. Status        Show current system & registry state" -ForegroundColor Cyan
    Write-Host "  Q. Quit" -ForegroundColor Cyan
    Write-Host ""
    $choice = Read-Host "  Choose [1/2/3/4/Q]"
    switch ($choice) {
        '1' { $Mode = 'Apply' }
        '2' { $Mode = 'Rollback' }
        '3' { $Mode = 'Reset' }
        '4' { $Mode = 'Status' }
        { $_ -match '^[Qq]$' } { Write-Host "  Exiting."; exit 0 }
        default { Write-Host "  Invalid choice. Exiting." -ForegroundColor Red; exit 1 }
    }
}

# ── ROLLBACK MODE ─────────────────────────────────────────────────────────────
if ($Mode -eq 'Rollback') {
    Write-Log "═══ Enable-WindowsHello -- ROLLBACK MODE ═══" 'INFO'
    Write-Log "Log: $LogFile" 'INFO'

    $allBackups = Get-ChildItem "$env:TEMP\EnableHello_Backup_*" -Directory -EA SilentlyContinue |
    Sort-Object Name -Descending

    if (-not $allBackups) {
        Exit-Script 1 "No EnableHello backup folder found in $env:TEMP. Nothing to restore."
    }

    if ($allBackups.Count -eq 1) {
        $selectedBackup = $allBackups[0]
    }
    else {
        Write-Host ""
        Write-Host "  Found $($allBackups.Count) backups (newest first):" -ForegroundColor Cyan
        for ($i = 0; $i -lt $allBackups.Count; $i++) {
            $ts = $allBackups[$i].Name -replace 'EnableHello_Backup_', ''
            Write-Host "    $($i + 1). $ts  ($($allBackups[$i].FullName))" -ForegroundColor Cyan
        }
        Write-Host ""
        $pick = Read-Host "  Choose backup [1-$($allBackups.Count)] (default: 1 = latest)"
        if ([string]::IsNullOrWhiteSpace($pick)) { $pick = '1' }
        $idx = 0
        if (-not [int]::TryParse($pick, [ref]$idx) -or $idx -lt 1 -or $idx -gt $allBackups.Count) {
            Write-Host "  Invalid choice. Exiting." -ForegroundColor Red; exit 1
        }
        $selectedBackup = $allBackups[$idx - 1]
    }

    Write-Log "Using backup: $($selectedBackup.FullName)" 'INFO'
    $null = Invoke-Rollback $selectedBackup.FullName

    Invoke-SignOutPrompt "Rollback"
    exit 0
}

# ── RESET MODE ────────────────────────────────────────────────────────────────
if ($Mode -eq 'Reset') {
    Write-Log "═══ Enable-WindowsHello -- RESET MODE ═══" 'INFO'
    Write-Log "Log: $LogFile" 'INFO'
    Write-Log "Removing all script-written registry values (lets Intune re-push defaults)..." 'INFO'

    # Values written by Step 1 (GP path)
    $resetValues = @(
        @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\PassportForWork"; Name = "Enabled" }
        @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\PassportForWork"; Name = "UseCertificateForOnPremAuth" }
        @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\PassportForWork"; Name = "RequireSecurityDevice" }
        @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\PassportForWork"; Name = "DisablePostLogonProvisioning" }
        @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\PassportForWork"; Name = "UseCloudTrustForOnPremAuth" }
        # Values written by Step 1 (HKCU -- the critical cert-trust override)
        @{ Path = "HKCU:\SOFTWARE\Policies\Microsoft\PassportForWork"; Name = "Enabled" }
        @{ Path = "HKCU:\SOFTWARE\Policies\Microsoft\PassportForWork"; Name = "UseCertificateForOnPremAuth" }
        @{ Path = "HKCU:\SOFTWARE\Policies\Microsoft\PassportForWork"; Name = "DisablePostLogonProvisioning" }
        # Values written by Step 2
        @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\System"; Name = "AllowDomainPINLogon" }
        @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System"; Name = "AllowDomainPINLogon" }
        @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Biometrics"; Name = "Enabled" }
        @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Biometrics\Credential Provider"; Name = "Enabled" }
        @{ Path = "HKLM:\SOFTWARE\Microsoft\PolicyManager\default\Settings\AllowSignInOptions"; Name = "value" }
    )

    # Also discover and reset MDM/CSP tenant-path overrides (written by Step 1)
    $tGuid = Get-TenantGuid
    if ($tGuid) {
        $mdmPol = "HKLM:\SOFTWARE\Microsoft\Policies\PassportForWork\$tGuid\Device\Policies"
        $resetValues += @(
            @{ Path = $mdmPol; Name = "UsePassportForWork" }
            @{ Path = $mdmPol; Name = "UseCertificateForOnPremAuth" }
        )
    }

    $removed = 0; $skipped = 0; $failed = 0
    foreach ($rv in $resetValues) {
        try {
            $exists = Get-ItemProperty -Path $rv.Path -Name $rv.Name -EA SilentlyContinue
            if ($null -ne $exists) {
                Remove-ItemProperty -Path $rv.Path -Name $rv.Name -Force -EA Stop
                Write-Log "  REMOVED $($rv.Path)\$($rv.Name)" 'OK'
                $removed++
            }
            else {
                Write-Log "  SKIPPED $($rv.Path)\$($rv.Name) (not present)" 'INFO'
                $skipped++
            }
        }
        catch {
            Write-Log "  FAILED $($rv.Path)\$($rv.Name) : $_" 'ERROR'
            $failed++
        }
    }

    Write-Log "Reset summary: $removed removed, $skipped already absent, $failed failed." $(if ($failed -gt 0) { 'ERROR' } else { 'OK' })

    # Offer to clear NGC container if still seeded
    $dsregReset = dsregcmd /status
    $ngcStillSeeded = [bool]($dsregReset | Select-String 'NgcSet\s*:\s*YES')
    if ($ngcStillSeeded) {
        Write-Host ""
        Write-Host "  NGC container is still seeded (PIN/fingerprint/face enrolled)." -ForegroundColor Yellow
        $clearNgc = Read-Host "  Clear Hello container too? Wipes PIN/fingerprint/face. [y/N]"
        if ($clearNgc -match '^[Yy]$') {
            $null = certutil.exe -deleteHelloContainer 2>&1
            if ($LASTEXITCODE -eq 0) {
                Write-Log "NGC container cleared (certutil -deleteHelloContainer)." 'OK'
            }
            else {
                Write-Log "certutil -deleteHelloContainer failed (exit code $LASTEXITCODE)." 'ERROR'
            }
        }
        else {
            Write-Log "NGC container left intact (user declined)." 'INFO'
        }
    }
    else {
        Write-Log "NGC container already empty -- nothing to clear." 'INFO'
    }

    # Trigger Intune MDM sync so policies are re-pushed
    Write-Log "Triggering Intune MDM sync..." 'INFO'
    $syncTask = Get-ScheduledTask -TaskPath '\Microsoft\Windows\EnterpriseMgmt\*' -TaskName 'PushLaunch' -EA SilentlyContinue
    if ($syncTask) {
        $syncTask | Start-ScheduledTask -EA SilentlyContinue
        Write-Log "Intune sync triggered via PushLaunch scheduled task. Policies will re-apply shortly." 'OK'
    }
    else {
        Write-Log "PushLaunch task not found -- trigger sync manually: Settings > Accounts > Access work or school > Sync." 'WARN'
    }

    Invoke-SignOutPrompt "Reset"
    exit 0
}

# ── STATUS MODE ───────────────────────────────────────────────────────────────
if ($Mode -eq 'Status') {
    Write-Log "═══ Enable-WindowsHello -- STATUS CHECK ═══" 'INFO'
    Write-Log "Log: $LogFile" 'INFO'

    # Device info
    $os = Get-CimInstance Win32_OperatingSystem
    Write-Log "Computer        : $env:COMPUTERNAME" 'INFO'
    Write-Log "OS              : $($os.Caption) Build $($os.BuildNumber)" 'INFO'

    # dsregcmd (single call, reuse throughout)
    $dsreg = dsregcmd /status

    $entraJoined = [bool]($dsreg | Select-String "AzureAdJoined\s*:\s*YES")
    $prtValid = [bool]($dsreg | Select-String "AzureAdPrt\s*:\s*YES")
    $ngcSeeded = [bool]($dsreg | Select-String 'NgcSet\s*:\s*YES')
    $preReq = ($dsreg | Select-String 'PreReqResult\s*:\s*(\S+)' |
        ForEach-Object { $_.Matches[0].Groups[1].Value }) -join ''
    $willProv = $preReq -eq 'WillProvision'

    Write-Log "Entra ID Joined : $(if ($entraJoined) { 'YES' } else { 'NO' })" $(if ($entraJoined) { 'OK' } else { 'ERROR' })
    Write-Log "AzureAd PRT     : $(if ($prtValid) { 'Valid' } else { 'Invalid/Missing' })" $(if ($prtValid) { 'OK' } else { 'ERROR' })
    Write-Log "NGC Seeded      : $(if ($ngcSeeded) { 'YES (Hello enrolled)' } else { 'NO' })" $(if ($ngcSeeded) { 'OK' } else { 'WARN' })
    Write-Log "PreReqResult    : $(if ($preReq) { $preReq } else { 'N/A (only visible during provisioning)' })" $(if ($willProv) { 'OK' } elseif ($preReq) { 'WARN' } else { 'INFO' })

    # Tenant GUID
    $tenantGuid = Get-TenantGuid -DsregOutput $dsreg
    Write-Log "Tenant GUID     : $(if ($tenantGuid) { $tenantGuid } else { '(not found)' })" $(if ($tenantGuid) { 'INFO' } else { 'WARN' })

    # TPM
    $tpmReady = Get-WinEvent -LogName "Microsoft-Windows-HelloForBusiness/Operational" -MaxEvents 10 -EA SilentlyContinue |
    Where-Object { $_.Id -eq 5000 -and $_.Message -match "Is Ready: true" }
    Write-Log "TPM 2.0 Ready   : $(if ($tpmReady) { 'YES' } else { 'Not confirmed (WHFB log)' })" $(if ($tpmReady) { 'OK' } else { 'WARN' })

    # WinBio
    $wbio = Get-Service WbioSrvc -EA SilentlyContinue
    Write-Log "WinBio Service  : $(if ($wbio) { $wbio.Status } else { 'Not found' })" $(if ($wbio -and $wbio.Status -eq 'Running') { 'OK' } else { 'WARN' })

    # Registry: HKLM GP path
    Write-Host ""
    Write-Log "--- Registry: HKLM GP Path ---" 'INFO'
    $gpPath = "HKLM:\SOFTWARE\Policies\Microsoft\PassportForWork"
    foreach ($name in @('Enabled', 'UseCertificateForOnPremAuth', 'RequireSecurityDevice',
            'DisablePostLogonProvisioning', 'UseCloudTrustForOnPremAuth')) {
        $val = (Get-ItemProperty -Path $gpPath -Name $name -EA SilentlyContinue).$name
        $display = if ($null -ne $val) { $val } else { '(not set)' }
        Write-Log "  $name = $display" 'INFO'
    }

    # Registry: HKCU per-user path (the critical one)
    Write-Log "--- Registry: HKCU Per-User Path (cert-trust source) ---" 'INFO'
    $hkcuPath = "HKCU:\SOFTWARE\Policies\Microsoft\PassportForWork"
    foreach ($name in @('Enabled', 'UseCertificateForOnPremAuth', 'DisablePostLogonProvisioning')) {
        $val = (Get-ItemProperty -Path $hkcuPath -Name $name -EA SilentlyContinue).$name
        $display = if ($null -ne $val) { $val } else { '(not set)' }
        $level = 'INFO'
        if ($name -eq 'UseCertificateForOnPremAuth' -and $val -eq 1) { $level = 'ERROR' }
        Write-Log "  $name = $display" $level
    }

    # Registry: MDM/CSP tenant path
    if ($tenantGuid) {
        Write-Log "--- Registry: MDM/CSP Tenant Path ---" 'INFO'
        $mdmPath = "HKLM:\SOFTWARE\Microsoft\Policies\PassportForWork\$tenantGuid\Device\Policies"
        foreach ($name in @('UsePassportForWork', 'UseCertificateForOnPremAuth')) {
            $val = (Get-ItemProperty -Path $mdmPath -Name $name -EA SilentlyContinue).$name
            $display = if ($null -ne $val) { $val } else { '(not set)' }
            Write-Log "  $name = $display" 'INFO'
        }
    }

    # Registry: PIN & biometrics
    Write-Log "--- Registry: PIN & Biometrics ---" 'INFO'
    $pinBioKeys = @(
        @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\System"; Name = "AllowDomainPINLogon" }
        @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System"; Name = "AllowDomainPINLogon" }
        @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Biometrics"; Name = "Enabled" }
        @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Biometrics\Credential Provider"; Name = "Enabled" }
        @{ Path = "HKLM:\SOFTWARE\Microsoft\PolicyManager\default\Settings\AllowSignInOptions"; Name = "value" }
    )
    foreach ($k in $pinBioKeys) {
        $val = (Get-ItemProperty -Path $k.Path -Name $k.Name -EA SilentlyContinue).$($k.Name)
        $display = if ($null -ne $val) { $val } else { '(not set)' }
        Write-Log "  $($k.Path)\$($k.Name) = $display" 'INFO'
    }

    # Check for active cert-trust blocker in HKCU
    $hkcuCertTrust = (Get-ItemProperty -Path "HKCU:\SOFTWARE\Policies\Microsoft\PassportForWork" -Name 'UseCertificateForOnPremAuth' -EA SilentlyContinue).UseCertificateForOnPremAuth
    $certTrustBlocking = ($hkcuCertTrust -eq 1)

    # Verdict
    Write-Host ""
    if (-not $entraJoined) {
        Write-Log "VERDICT: Device is not Entra ID joined. Script is not applicable." 'ERROR'
    }
    elseif ($ngcSeeded) {
        Write-Log "VERDICT: Hello is provisioned and working (NGC seeded). No action needed." 'OK'
    }
    elseif ($willProv) {
        Write-Log "VERDICT: Ready to provision. Run Apply mode or set up PIN in Settings > Sign-in options." 'OK'
    }
    elseif ($certTrustBlocking) {
        Write-Log "VERDICT: HKCU UseCertificateForOnPremAuth=1 is blocking provisioning. Run Apply mode to fix." 'WARN'
    }
    else {
        Write-Log "VERDICT: Hello not yet provisioned. Run Apply mode to enable." 'WARN'
    }

    Write-Log "═══ Status check completed ═══" 'OK'
    Write-Log "Log saved to: $LogFile" 'INFO'
    exit 0
}

# ── APPLY MODE ────────────────────────────────────────────────────────────────
Write-Log "═══ Enable-WindowsHello -- APPLY MODE ═══" 'INFO'
Write-Log "Log: $LogFile" 'INFO'

# ── PREFLIGHT ─────────────────────────────────────────────────────────────────
Write-Log "--- Pre-flight checks ---" 'INFO'

# Entra joined check
$dsreg = dsregcmd /status
$entraJoined = [bool]($dsreg | Select-String "AzureAdJoined\s*:\s*YES")
$prtValid = [bool]($dsreg | Select-String "AzureAdPrt\s*:\s*YES")

if (-not $entraJoined) { Exit-Script 1 "Device is not Entra ID joined. Script cannot proceed." }
Write-Log "Entra ID joined: YES" 'OK'

if (-not $prtValid) {
    Write-Log "AzureAdPrt is invalid/missing. Sign in to Windows with your Entra account first." 'ERROR'
    Exit-Script 1 "Valid PRT required for Hello provisioning."
}
Write-Log "AzureAdPrt: Valid" 'OK'

# TPM check via WHFB event log (Get-Tpm unreliable in restricted envs)
$tpmReady = Get-WinEvent -LogName "Microsoft-Windows-HelloForBusiness/Operational" -MaxEvents 10 -EA SilentlyContinue |
Where-Object { $_.Id -eq 5000 -and $_.Message -match "Is Ready: true" }
if (-not $tpmReady) {
    Write-Log "TPM not confirmed ready via WHFB log -- proceeding anyway, may fail later." 'WARN'
}
else {
    Write-Log "TPM 2.0: Ready" 'OK'
}

# WinBio service check
$wbio = Get-Service WbioSrvc -EA SilentlyContinue
if ($wbio) {
    if ($wbio.Status -ne 'Running') {
        Write-Log "WinBio service is $($wbio.Status). Attempting to start..." 'WARN'
        try {
            Start-Service WbioSrvc -EA Stop
            Write-Log "WinBio service started." 'OK'
        }
        catch {
            Write-Log "Could not start WinBio service: $_. Fingerprint enrollment may fail." 'WARN'
        }
    }
    else {
        Write-Log "WinBio service: Running" 'OK'
    }
}
else {
    Write-Log "WinBio service not found -- fingerprint hardware may not be present." 'WARN'
}

# NGC container check via dsregcmd (Get-ChildItem on NGC folder blocked by ACL even for admins)
$ngcSeeded = [bool]($dsreg | Select-String 'NgcSet\s*:\s*YES')
if ($ngcSeeded) {
    Write-Log "NGC container already populated with user key material -- Hello was previously provisioned." 'OK'
    Write-Log "If PIN/Fingerprint is still unavailable in Settings, check for policy revert." 'WARN'
}

# ── STEP 1: Back up & neutralize PassportForWork cert-trust policy ────────────
Write-Log "--- Step 1: Back up and neutralize PassportForWork cert-trust policy ---" 'INFO'
$pfwPath = "HKLM:\SOFTWARE\Policies\Microsoft\PassportForWork"

# Registry backup before changes
New-Item $BackupDir -ItemType Directory -Force | Out-Null
$backupKeys = @(
    @{ Key = "HKLM\SOFTWARE\Policies\Microsoft\PassportForWork"; File = "PassportForWork.reg" }
    @{ Key = "HKLM\SOFTWARE\Microsoft\Policies\PassportForWork"; File = "PassportForWork_MDM.reg" }
    @{ Key = "HKCU\SOFTWARE\Policies\Microsoft\PassportForWork"; File = "PassportForWork_HKCU.reg" }
    @{ Key = "HKLM\SOFTWARE\Policies\Microsoft\Biometrics"; File = "Biometrics.reg" }
    @{ Key = "HKLM\SOFTWARE\Policies\Microsoft\Windows\System"; File = "WindowsSystem.reg" }
    @{ Key = "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System"; File = "CurrentVersionPoliciesSystem.reg" }
    @{ Key = "HKLM\SOFTWARE\Microsoft\PolicyManager\default\Settings\AllowSignInOptions"; File = "AllowSignInOptions.reg" }
)
foreach ($bk in $backupKeys) {
    $bkFile = Join-Path $BackupDir $bk.File
    $null = reg export $bk.Key $bkFile /y 2>&1
    if ($LASTEXITCODE -eq 0) {
        Write-Log "  Backed up $($bk.Key) -> $bkFile" 'INFO'
    }
    else {
        Write-Log "  Backup skipped for $($bk.Key) (may not exist yet)" 'WARN'
    }
}
Write-Log "Registry backup saved to: $BackupDir" 'INFO'

# Targeted writes -- GP path (ADMX-backed policies)
# Enabled=1 keeps WHFB active (required for PIN on Entra ID joined devices).
# UseCertificateForOnPremAuth=0 disables cert-trust so CXH doesn't wait for certs.
Set-RegValue $pfwPath "Enabled"                      1
Set-RegValue $pfwPath "UseCertificateForOnPremAuth"   0
Set-RegValue $pfwPath "RequireSecurityDevice"         0
Set-RegValue $pfwPath "DisablePostLogonProvisioning"  0
Set-RegValue $pfwPath "UseCloudTrustForOnPremAuth"    1
Write-Log "GP path: WHFB enabled, cert-trust disabled, cloud-trust enabled." 'OK'

# CRITICAL: HKCU per-user path -- the WHfB provisioning engine reads
# UseCertificateForOnPremAuth from here, NOT from HKLM.  Intune pushes
# cert-trust=1 to HKCU via per-user CSP, which blocks provisioning even
# when HKLM says 0.  This is the actual breakthrough fix.
$hkcuPfwPath = "HKCU:\SOFTWARE\Policies\Microsoft\PassportForWork"
Set-RegValue $hkcuPfwPath "Enabled"                      1
Set-RegValue $hkcuPfwPath "UseCertificateForOnPremAuth"   0
Set-RegValue $hkcuPfwPath "DisablePostLogonProvisioning"  0
Write-Log "HKCU path: cert-trust disabled (per-user override applied)." 'OK'

# MDM/CSP tenant path -- overrides Intune-pushed values during CXH provisioning.
$mdmPfwRoot = "HKLM:\SOFTWARE\Microsoft\Policies\PassportForWork"
$tenantGuid = Get-TenantGuid -DsregOutput $dsreg

if ($tenantGuid) {
    $mdmPoliciesPath = "$mdmPfwRoot\$tenantGuid\Device\Policies"
    Write-Log "  Tenant GUID: $tenantGuid" 'INFO'
    Set-RegValue $mdmPoliciesPath "UsePassportForWork"          1
    Set-RegValue $mdmPoliciesPath "UseCertificateForOnPremAuth" 0
    Write-Log "MDM/CSP path: WHFB enabled, cert-trust disabled." 'OK'
}
else {
    Write-Log "Could not discover tenant GUID -- MDM path overrides skipped." 'WARN'
    Write-Log "GP path writes should still be effective." 'INFO'
}

# Verify Step 1 writes
Write-Log "  Verifying Step 1 registry writes..." 'INFO'
$null = Test-RegValue $pfwPath "Enabled" 1
$null = Test-RegValue $pfwPath "UseCertificateForOnPremAuth" 0
$null = Test-RegValue $pfwPath "RequireSecurityDevice" 0
$null = Test-RegValue $pfwPath "DisablePostLogonProvisioning" 0
$null = Test-RegValue $pfwPath "UseCloudTrustForOnPremAuth" 1
$null = Test-RegValue $hkcuPfwPath "Enabled" 1
$null = Test-RegValue $hkcuPfwPath "UseCertificateForOnPremAuth" 0
$null = Test-RegValue $hkcuPfwPath "DisablePostLogonProvisioning" 0
if ($tenantGuid) {
    $null = Test-RegValue $mdmPoliciesPath "UsePassportForWork" 1
    $null = Test-RegValue $mdmPoliciesPath "UseCertificateForOnPremAuth" 0
}

# Quick sanity: dsregcmd should now say WillProvision
$preCheck = dsregcmd /status 2>&1
if ($preCheck | Select-String 'PreReqResult\s*:\s*WillProvision') {
    Write-Log "dsregcmd PreReqResult: WillProvision -- cert-trust gate cleared!" 'OK'
}
else {
    Write-Log "dsregcmd PreReqResult is NOT WillProvision. HKCU override may need a sign-out cycle." 'WARN'
}

if ($script:CriticalFailure) {
    Write-Log "Step 1 verification failed -- values may have been reverted by Intune/MDM." 'ERROR'
    Write-Log "Try running this script immediately after reboot, before MDM sync triggers." 'WARN'
}

# ── STEP 2: Enable convenience PIN + biometrics via registry (gpedit equivalent)
Write-Log "--- Step 2: Enable convenience PIN and biometrics ---" 'INFO'
Set-RegValue "HKLM:\SOFTWARE\Policies\Microsoft\Windows\System"                          "AllowDomainPINLogon" 1
Set-RegValue "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System"           "AllowDomainPINLogon" 1
Set-RegValue "HKLM:\SOFTWARE\Policies\Microsoft\Biometrics"                               "Enabled"            1
Set-RegValue "HKLM:\SOFTWARE\Policies\Microsoft\Biometrics\Credential Provider"           "Enabled"            1
Set-RegValue "HKLM:\SOFTWARE\Microsoft\PolicyManager\default\Settings\AllowSignInOptions" "value"              1
Write-Log "Convenience PIN and biometrics keys set." 'OK'

# Verify Step 2 writes
Write-Log "  Verifying Step 2 registry writes..." 'INFO'
$null = Test-RegValue "HKLM:\SOFTWARE\Policies\Microsoft\Windows\System"                          "AllowDomainPINLogon" 1
$null = Test-RegValue "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System"           "AllowDomainPINLogon" 1
$null = Test-RegValue "HKLM:\SOFTWARE\Policies\Microsoft\Biometrics"                               "Enabled"            1
$null = Test-RegValue "HKLM:\SOFTWARE\Policies\Microsoft\Biometrics\Credential Provider"           "Enabled"            1
$null = Test-RegValue "HKLM:\SOFTWARE\Microsoft\PolicyManager\default\Settings\AllowSignInOptions" "value"              1

if ($script:CriticalFailure) {
    Write-Log "Step 2 verification failed -- one or more convenience PIN/biometrics keys did not persist." 'ERROR'
}

# Auto-rollback check after registry writes
if ($script:CriticalFailure) {
    Write-Host ""
    Write-Host "  Registry verification failed. Values may have been reverted by Intune/MDM." -ForegroundColor Red
    Write-Host "  R = Rollback (restore backup and exit)" -ForegroundColor Red
    Write-Host "  C = Continue anyway (proceed to Step 3)" -ForegroundColor Red
    Write-Host ""
    $failChoice = Read-Host "  Choose [R/C]"
    if ($failChoice -match '^[Rr]$') {
        Write-Log "User chose auto-rollback after verification failure." 'WARN'
        $null = Invoke-Rollback $BackupDir
        Invoke-SignOutPrompt "Auto-Rollback"
        exit 1
    }
    Write-Log "User chose to continue despite verification failure." 'WARN'
    $script:CriticalFailure = $false
}

# ── STEP 3: In-session Hello enrollment via Settings ──────────────────────────
# No sign-out required.  The HKCU override takes effect immediately, and
# dsregcmd confirms WillProvision in-session.  Opening Settings before
# Intune MDM sync can re-push policies is the key timing window.
Write-Log "--- Step 3: In-session Hello enrollment via Settings ---" 'INFO'

if (-not $ngcSeeded) {
    # Clear stale provisioning state so enrollment starts clean
    Write-Log "  Clearing Hello container to force fresh enrollment..." 'INFO'
    $null = certutil.exe -deleteHelloContainer 2>&1
    Write-Log "  certutil -deleteHelloContainer completed (exit code $LASTEXITCODE)." $(if ($LASTEXITCODE -eq 0) { 'OK' } else { 'WARN' })
}

# Open Settings > Sign-in options for in-session setup (runs immediately
# after registry writes, before Intune MDM sync can re-push policies).
Write-Log "  Opening Settings > Sign-in options..." 'INFO'
Start-Process "ms-settings:signinoptions"

Write-Host ""
Write-Host "  Settings > Sign-in options has been opened." -ForegroundColor Green
Write-Host "  1. Click PIN (Windows Hello) > Set up" -ForegroundColor Green
Write-Host "     Verify your identity, then create and confirm your PIN." -ForegroundColor Green
Write-Host "  2. Click Fingerprint recognition > Set up" -ForegroundColor Green
Write-Host "     (available after PIN is created)" -ForegroundColor Green
Write-Host ""
Read-Host "  Press Enter after completing Hello setup in Settings"

# ── STEP 4: Verify provisioning ──────────────────────────────────────────────
Write-Log "--- Step 4: Verifying Hello provisioning ---" 'INFO'
$dsregPost = dsregcmd /status
$ngcNow = [bool]($dsregPost | Select-String 'NgcSet\s*:\s*YES')

if ($ngcNow) {
    Write-Log "NGC container is seeded -- Hello provisioning confirmed!" 'OK'
    Write-Host ""
    Write-Host "  Windows Hello is set up! PIN and/or biometrics are ready." -ForegroundColor Green
    Write-Host ""
}
else {
    Write-Log "NGC container still not seeded after Settings interaction." 'WARN'
    Write-Host ""
    Write-Host "  NGC not yet seeded. Possible causes:" -ForegroundColor Yellow
    Write-Host "    - PIN setup was not completed in Settings" -ForegroundColor Yellow
    Write-Host "    - Policy still blocking (sign out and sign in may help)" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "  Retry: Settings > Accounts > Sign-in options > PIN > Set up" -ForegroundColor Cyan
    Write-Host ""
}

Write-Log "═══ Apply completed ═══" 'OK'
Write-Log "Log saved to: $LogFile" 'INFO'

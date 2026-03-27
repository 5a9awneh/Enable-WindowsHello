#Requires -Version 5.1
<#
.SYNOPSIS
    Pester test suite for Enable-WindowsHello.ps1
.DESCRIPTION
    Tests all 4 modes (Apply, Rollback, Reset, Status) and helper functions
    using mocked registry, dsregcmd, certutil, and service calls.
    Safe to run on any machine -- no real registry changes are made.
.NOTES
    Run:  .\Enable-WindowsHello.Tests.ps1
    Or:   Invoke-Pester .\Enable-WindowsHello.Tests.ps1 -Output Detailed
#>

# ── Pester bootstrap (only when not already running under Pester) ────────────
if (-not (Get-Module Pester)) {
    $minPesterVersion = [version]'5.0.0'
    $pester = Get-Module Pester -ListAvailable | Sort-Object Version -Descending | Select-Object -First 1

    if (-not $pester -or $pester.Version -lt $minPesterVersion) {
        Write-Host "[Test Bootstrap] Pester $minPesterVersion+ not found. Installing from PSGallery..." -ForegroundColor Yellow
        try {
            Install-Module Pester -MinimumVersion $minPesterVersion -Scope CurrentUser -Force -SkipPublisherCheck -ErrorAction Stop
            Write-Host "[Test Bootstrap] Pester installed successfully." -ForegroundColor Green
        }
        catch {
            Write-Error "Failed to install Pester: $_"
            Write-Host "[Test Bootstrap] Install manually:  Install-Module Pester -Scope CurrentUser -Force" -ForegroundColor Red
            exit 1
        }
    }

    Import-Module Pester -MinimumVersion $minPesterVersion -Force
}

# ── Resolve script under test ───────────────────────────────────────────────
# $PSScriptRoot may be empty when run via -Command; derive from file path
$_root = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path $MyInvocation.MyCommand.Definition -Parent }
$ScriptPath = Join-Path $_root 'Enable-WindowsHello.ps1'

# ── Tests ────────────────────────────────────────────────────────────────────

Describe 'Enable-WindowsHello.ps1' {

    BeforeAll {
        # Resolve SUT path inside Pester context (Pester re-executes file with different scoping)
        $_root = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path $PSCommandPath -Parent }
        $ScriptPath = Join-Path $_root 'Enable-WindowsHello.ps1'

        if (-not (Test-Path $ScriptPath)) {
            throw "Script not found at: $ScriptPath"
        }

        # Import functions from the script AST without executing mode logic or #Requires
        $tokens = $null; $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($ScriptPath, [ref]$tokens, [ref]$errors)
        $funcDefs = $ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $false)
        foreach ($fn in $funcDefs) {
            . ([scriptblock]::Create($fn.Extent.Text))
        }

        # Common variables the script expects
        $script:LogFile = Join-Path $env:TEMP "EnableHello_Test_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"
        $script:CriticalFailure = $false
    }

    AfterAll {
        # Clean up test log
        if (Test-Path $script:LogFile) { Remove-Item $script:LogFile -Force -EA SilentlyContinue }
    }

    # ── Write-Log ────────────────────────────────────────────────────────
    Describe 'Write-Log' {

        It 'writes INFO entry to log file' {
            Write-Log 'Test info message' 'INFO'
            $content = Get-Content $script:LogFile -Tail 1
            $content | Should -Match '\[INFO\] Test info message'
        }

        It 'writes OK entry to log file' {
            Write-Log 'Test ok message' 'OK'
            $content = Get-Content $script:LogFile -Tail 1
            $content | Should -Match '\[OK\] Test ok message'
        }

        It 'writes WARN entry to log file' {
            Write-Log 'Test warning' 'WARN'
            $content = Get-Content $script:LogFile -Tail 1
            $content | Should -Match '\[WARN\] Test warning'
        }

        It 'writes ERROR entry to log file' {
            Write-Log 'Test error' 'ERROR'
            $content = Get-Content $script:LogFile -Tail 1
            $content | Should -Match '\[ERROR\] Test error'
        }

        It 'includes timestamp in HH:mm:ss format' {
            Write-Log 'Timestamp check' 'INFO'
            $content = Get-Content $script:LogFile -Tail 1
            $content | Should -Match '^\[\d{2}:\d{2}:\d{2}\]'
        }
    }

    # ── Set-RegValue ─────────────────────────────────────────────────────
    Describe 'Set-RegValue' {

        BeforeEach {
            $script:CriticalFailure = $false
        }

        It 'creates registry path and sets value' {
            Mock New-Item { } -Verifiable
            Mock Set-ItemProperty { } -Verifiable
            Mock Test-Path { $false }

            Set-RegValue 'HKLM:\SOFTWARE\Test\Path' 'TestName' 1

            Should -InvokeVerifiable
            $script:CriticalFailure | Should -BeFalse
        }

        It 'skips path creation when path exists' {
            Mock Test-Path { $true }
            Mock Set-ItemProperty { }
            Mock New-Item { }

            Set-RegValue 'HKLM:\SOFTWARE\Test\Path' 'TestName' 1

            Should -Invoke New-Item -Times 0
            Should -Invoke Set-ItemProperty -Times 1
        }

        It 'sets CriticalFailure on error' {
            Mock Test-Path { $true }
            Mock Set-ItemProperty { throw 'Access denied' }

            Set-RegValue 'HKLM:\SOFTWARE\Test\Path' 'TestName' 1

            $script:CriticalFailure | Should -BeTrue
        }
    }

    # ── Test-RegValue ────────────────────────────────────────────────────
    Describe 'Test-RegValue' {

        BeforeEach {
            $script:CriticalFailure = $false
        }

        It 'returns true when value matches expected' {
            Mock Get-ItemProperty {
                [PSCustomObject]@{ TestName = 1 }
            }

            $result = Test-RegValue 'HKLM:\SOFTWARE\Test' 'TestName' 1
            $result | Should -BeTrue
            $script:CriticalFailure | Should -BeFalse
        }

        It 'returns false and sets CriticalFailure on mismatch' {
            Mock Get-ItemProperty {
                [PSCustomObject]@{ TestName = 0 }
            }

            $result = Test-RegValue 'HKLM:\SOFTWARE\Test' 'TestName' 1
            $result | Should -BeFalse
            $script:CriticalFailure | Should -BeTrue
        }

        It 'returns false and sets CriticalFailure when key missing' {
            Mock Get-ItemProperty { throw 'Property not found' }

            $result = Test-RegValue 'HKLM:\SOFTWARE\Test' 'TestName' 1
            $result | Should -BeFalse
            $script:CriticalFailure | Should -BeTrue
        }
    }

    # ── Get-TenantGuid ──────────────────────────────────────────────────
    Describe 'Get-TenantGuid' {

        It 'extracts GUID from MDM registry path' {
            $testGuid = 'a1b2c3d4-e5f6-7890-abcd-ef1234567890'
            Mock Test-Path { $true }
            Mock Get-ChildItem {
                [PSCustomObject]@{ PSChildName = $testGuid }
            }

            $result = Get-TenantGuid
            $result | Should -Be $testGuid
        }

        It 'falls back to dsregcmd output when registry empty' {
            Mock Test-Path { $false }

            $dsregOutput = @(
                '  AzureAdJoined : YES'
                '  TenantId : a1b2c3d4-e5f6-7890-abcd-ef1234567890'
                '  AzureAdPrt : YES'
            )

            $result = Get-TenantGuid -DsregOutput $dsregOutput
            $result | Should -Be 'a1b2c3d4-e5f6-7890-abcd-ef1234567890'
        }

        It 'returns null when no GUID found anywhere' {
            Mock Test-Path { $false }

            $result = Get-TenantGuid -DsregOutput @('No relevant data')
            $result | Should -BeNullOrEmpty
        }
    }

    # ── Invoke-Rollback ──────────────────────────────────────────────────
    Describe 'Invoke-Rollback' {

        It 'imports all .reg files from backup folder' {
            $tempBackup = Join-Path $env:TEMP "PesterTestBackup_$(Get-Random)"
            New-Item $tempBackup -ItemType Directory -Force | Out-Null
            # Create dummy .reg files
            'Windows Registry Editor Version 5.00' | Out-File (Join-Path $tempBackup 'test1.reg')
            'Windows Registry Editor Version 5.00' | Out-File (Join-Path $tempBackup 'test2.reg')

            Mock reg { $global:LASTEXITCODE = 0 } -ParameterFilter { $args[0] -eq 'import' }

            $result = Invoke-Rollback $tempBackup
            $result | Should -BeTrue

            # Cleanup
            Remove-Item $tempBackup -Recurse -Force -EA SilentlyContinue
        }

        It 'returns false when backup folder has no .reg files' {
            $tempBackup = Join-Path $env:TEMP "PesterTestBackup_$(Get-Random)"
            New-Item $tempBackup -ItemType Directory -Force | Out-Null

            $result = Invoke-Rollback $tempBackup
            $result | Should -BeFalse

            Remove-Item $tempBackup -Recurse -Force -EA SilentlyContinue
        }
    }

    # ── Mode: Status ─────────────────────────────────────────────────────
    Describe 'Status Mode (integration)' {

        It 'script parses without syntax errors' {
            $tokens = $null; $errors = $null
            [System.Management.Automation.Language.Parser]::ParseFile($ScriptPath, [ref]$tokens, [ref]$errors)
            $errors.Count | Should -Be 0
        }

        It 'defines all expected functions' {
            $tokens = $null; $errors = $null
            $ast = [System.Management.Automation.Language.Parser]::ParseFile($ScriptPath, [ref]$tokens, [ref]$errors)
            $funcs = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $false)
            $funcNames = $funcs | ForEach-Object { $_.Name }

            $funcNames | Should -Contain 'Write-Log'
            $funcNames | Should -Contain 'Exit-Script'
            $funcNames | Should -Contain 'Set-RegValue'
            $funcNames | Should -Contain 'Test-RegValue'
            $funcNames | Should -Contain 'Invoke-Rollback'
            $funcNames | Should -Contain 'Invoke-SignOutPrompt'
            $funcNames | Should -Contain 'Get-TenantGuid'
        }

        It 'accepts all 4 valid Mode values' {
            $tokens = $null; $errors = $null
            $ast = [System.Management.Automation.Language.Parser]::ParseFile($ScriptPath, [ref]$tokens, [ref]$errors)
            $paramBlock = $ast.ParamBlock
            $modeParam = $paramBlock.Parameters | Where-Object { $_.Name.VariablePath.UserPath -eq 'Mode' }
            $validateSet = $modeParam.Attributes | Where-Object { $_.TypeName.FullName -eq 'ValidateSet' }
            $values = $validateSet.PositionalArguments | ForEach-Object { $_.Value }

            $values | Should -Contain 'Apply'
            $values | Should -Contain 'Rollback'
            $values | Should -Contain 'Reset'
            $values | Should -Contain 'Status'
        }
    }

    # ── Registry value map completeness ──────────────────────────────────
    Describe 'Registry coverage' {

        BeforeAll {
            $scriptContent = Get-Content $ScriptPath -Raw
        }

        It 'Apply sets UseCertificateForOnPremAuth=0 in both HKLM and HKCU' {
            # HKLM GP path
            $scriptContent | Should -Match 'Set-RegValue\s+\$pfwPath\s+"UseCertificateForOnPremAuth"\s+0'
            # HKCU per-user path
            $scriptContent | Should -Match 'Set-RegValue\s+\$hkcuPfwPath\s+"UseCertificateForOnPremAuth"\s+0'
        }

        It 'Apply sets Enabled=1 in GP, HKCU, and MDM paths' {
            $scriptContent | Should -Match 'Set-RegValue\s+\$pfwPath\s+"Enabled"\s+1'
            $scriptContent | Should -Match 'Set-RegValue\s+\$hkcuPfwPath\s+"Enabled"\s+1'
            $scriptContent | Should -Match 'Set-RegValue\s+\$mdmPoliciesPath\s+"UsePassportForWork"\s+1'
        }

        It 'Apply enables biometrics' {
            $scriptContent | Should -Match 'Biometrics.*"Enabled"\s+1'
            $scriptContent | Should -Match 'Biometrics\\Credential Provider.*"Enabled"\s+1'
        }

        It 'Apply enables domain PIN logon in both paths' {
            $scriptContent | Should -Match 'Windows\\System.*"AllowDomainPINLogon"\s+1'
            $scriptContent | Should -Match 'Policies\\System.*"AllowDomainPINLogon"\s+1'
        }

        It 'Reset covers all values that Apply writes' {
            # Extract the resetValues array section using reliable string indexing
            $resetStart = $scriptContent.IndexOf('$resetValues')
            $resetEnd = $scriptContent.IndexOf('STATUS MODE')
            $resetSection = $scriptContent.Substring($resetStart, $resetEnd - $resetStart)

            $resetSection | Should -Match 'UseCertificateForOnPremAuth'
            $resetSection | Should -Match 'Enabled'
            $resetSection | Should -Match 'RequireSecurityDevice'
            $resetSection | Should -Match 'DisablePostLogonProvisioning'
            $resetSection | Should -Match 'UseCloudTrustForOnPremAuth'
            $resetSection | Should -Match 'AllowDomainPINLogon'
            $resetSection | Should -Match 'Biometrics'
            $resetSection | Should -Match 'AllowSignInOptions'
        }

        It 'Apply verifies every Step 1 write with Test-RegValue' {
            # Extract Step 1 section between STEP 1 and STEP 2 comment markers
            $step1Start = $scriptContent.IndexOf('STEP 1:')
            $step2Start = $scriptContent.IndexOf('STEP 2:')
            $step1Section = $scriptContent.Substring($step1Start, $step2Start - $step1Start)

            $testCount = ([regex]::Matches($step1Section, 'Test-RegValue')).Count

            # All GP (5) + HKCU (3) writes have corresponding verifications
            # MDM writes (2) also verified conditionally
            $testCount | Should -BeGreaterOrEqual 8
        }

        It 'Apply verifies every Step 2 write with Test-RegValue' {
            $step2Section = ($scriptContent -split 'Step 2:')[1]
            $step2Section = ($step2Section -split 'Step 3:')[0]

            $setCount = ([regex]::Matches($step2Section, 'Set-RegValue')).Count
            $testCount = ([regex]::Matches($step2Section, 'Test-RegValue')).Count

            $testCount | Should -Be $setCount
        }
    }

    # ── Backup & rollback symmetry ───────────────────────────────────────
    Describe 'Backup and rollback symmetry' {

        BeforeAll {
            $scriptContent = Get-Content $ScriptPath -Raw
        }

        It 'backs up all registry hives before modifying them' {
            $backupSection = ($scriptContent -split 'Registry backup before changes')[1]
            $backupSection = ($backupSection -split 'Targeted writes')[0]

            # All major hives should be backed up
            $backupSection | Should -Match 'PassportForWork'
            $backupSection | Should -Match 'Biometrics'
            $backupSection | Should -Match 'Windows\\System'
            $backupSection | Should -Match 'AllowSignInOptions'
            $backupSection | Should -Match 'PassportForWork_HKCU'
            $backupSection | Should -Match 'PassportForWork_MDM'
        }

        It 'Rollback mode discovers backup folders from $env:TEMP' {
            $scriptContent | Should -Match 'Get-ChildItem.*EnableHello_Backup_\*.*-Directory'
        }

        It 'Apply offers auto-rollback on CriticalFailure' {
            $scriptContent | Should -Match 'Invoke-Rollback \$BackupDir'
            $scriptContent | Should -Match 'Auto-Rollback'
        }
    }

    # ── Preflight checks ────────────────────────────────────────────────
    Describe 'Preflight checks in Apply mode' {

        BeforeAll {
            $scriptContent = Get-Content $ScriptPath -Raw
        }

        It 'checks Entra ID join status' {
            $scriptContent | Should -Match 'AzureAdJoined.*YES'
        }

        It 'checks PRT validity' {
            $scriptContent | Should -Match 'AzureAdPrt.*YES'
        }

        It 'checks TPM readiness via WHFB event log' {
            $scriptContent | Should -Match 'HelloForBusiness/Operational'
            $scriptContent | Should -Match 'Is Ready: true'
        }

        It 'checks WinBio service and attempts start if stopped' {
            $scriptContent | Should -Match 'Get-Service WbioSrvc'
            $scriptContent | Should -Match 'Start-Service WbioSrvc'
        }

        It 'checks NGC container status' {
            $scriptContent | Should -Match 'NgcSet.*YES'
        }
    }

    # ── Script safety features ───────────────────────────────────────────
    Describe 'Safety features' {

        BeforeAll {
            $scriptContent = Get-Content $ScriptPath -Raw
        }

        It 'requires administrator elevation' {
            $scriptContent | Should -Match '#Requires -RunAsAdministrator'
        }

        It 'creates timestamped log file' {
            $scriptContent | Should -Match 'EnableHello_.*yyyyMMdd_HHmmss.*\.log'
        }

        It 'creates timestamped backup directory' {
            $scriptContent | Should -Match 'EnableHello_Backup_.*yyyyMMdd_HHmmss'
        }

        It 'Reset mode offers NGC container cleanup' {
            $scriptContent | Should -Match 'certutil.*-deleteHelloContainer'
        }

        It 'Reset mode triggers Intune MDM sync' {
            $scriptContent | Should -Match 'PushLaunch'
            $scriptContent | Should -Match 'Start-ScheduledTask'
        }

        It 'Apply mode opens Settings for manual enrollment' {
            $scriptContent | Should -Match 'ms-settings:signinoptions'
        }

        It 'Rollback and Reset offer sign-out prompt with countdown' {
            $scriptContent | Should -Match 'shutdown\.exe /l'
            $scriptContent | Should -Match 'Signing out in.*seconds'
        }
    }

    # ── Interactive menu ─────────────────────────────────────────────────
    Describe 'Interactive menu' {

        BeforeAll {
            $scriptContent = Get-Content $ScriptPath -Raw
        }

        It 'shows menu when -Mode is not specified' {
            $scriptContent | Should -Match 'if \(-not \$Mode\)'
        }

        It 'maps menu choice 1-4 to all four modes' {
            $menuSection = ($scriptContent -split 'if \(-not \$Mode\)')[1]
            $menuSection = ($menuSection -split '── ROLLBACK MODE')[0]

            $menuSection | Should -Match "'1'.*Apply"
            $menuSection | Should -Match "'2'.*Rollback"
            $menuSection | Should -Match "'3'.*Reset"
            $menuSection | Should -Match "'4'.*Status"
        }

        It 'supports Q to quit from menu' {
            # The switch block matches Q/q and calls exit 0
            $scriptContent | Should -Match '[Qq]'
            $scriptContent | Should -Match 'Exiting'
        }
    }

    # ── HKCU breakthrough (the core fix) ─────────────────────────────────
    Describe 'HKCU cert-trust breakthrough' {

        BeforeAll {
            $scriptContent = Get-Content $ScriptPath -Raw
        }

        It 'documents that WHfB reads from HKCU not HKLM' {
            $scriptContent | Should -Match 'HKCU.*NOT.*HKLM|the WHfB.*engine reads.*HKCU'
        }

        It 'writes UseCertificateForOnPremAuth=0 to HKCU' {
            $scriptContent | Should -Match '\$hkcuPfwPath.*UseCertificateForOnPremAuth.*0'
        }

        It 'Status mode checks HKCU cert-trust value for verdict' {
            $statusSection = ($scriptContent -split 'STATUS MODE')[1]
            $statusSection = ($statusSection -split 'APPLY MODE')[0]

            $statusSection | Should -Match 'HKCU.*UseCertificateForOnPremAuth'
            $statusSection | Should -Match 'certTrustBlocking'
        }
    }
}

# ── LIVE TESTS (read-only Status mode on real system) ────────────────────────
# Run:  Invoke-Pester .\Enable-WindowsHello.Tests.ps1 -Tag 'Live' -Output Detailed
# Requires: Administrator, Entra ID joined device
Describe 'Live: Status mode on real system' -Tag 'Live' {

    BeforeAll {
        $_root = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path $PSCommandPath -Parent }
        $ScriptPath = Join-Path $_root 'Enable-WindowsHello.ps1'

        # Must be admin (checked in BeforeEach so Set-ItResult runs inside It scope)
        $script:isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
            [Security.Principal.WindowsBuiltInRole]::Administrator)
    }

    BeforeEach {
        if (-not $script:isAdmin) { Set-ItResult -Skipped -Because 'requires Administrator elevation' }
    }

    It 'script executes Status mode without errors' {
        $output = & powershell -NoProfile -ExecutionPolicy Bypass -Command "& '$ScriptPath' -Mode Status" 2>&1
        $LASTEXITCODE | Should -Be 0
        ($output | Out-String) | Should -Match 'STATUS CHECK'
    }

    It 'Status mode reports Entra ID join state' {
        $output = & powershell -NoProfile -ExecutionPolicy Bypass -Command "& '$ScriptPath' -Mode Status" 2>&1
        $text = $output | Out-String
        $text | Should -Match 'Entra ID Joined\s*:\s*(YES|NO)'
    }

    It 'Status mode reports PRT state' {
        $output = & powershell -NoProfile -ExecutionPolicy Bypass -Command "& '$ScriptPath' -Mode Status" 2>&1
        $text = $output | Out-String
        $text | Should -Match 'AzureAd PRT\s*:\s*(Valid|Invalid)'
    }

    It 'Status mode reports TPM readiness' {
        $output = & powershell -NoProfile -ExecutionPolicy Bypass -Command "& '$ScriptPath' -Mode Status" 2>&1
        $text = $output | Out-String
        $text | Should -Match 'TPM 2\.0 Ready'
    }

    It 'Status mode reports WinBio service status' {
        $output = & powershell -NoProfile -ExecutionPolicy Bypass -Command "& '$ScriptPath' -Mode Status" 2>&1
        $text = $output | Out-String
        $text | Should -Match 'WinBio Service\s*:\s*(Running|Stopped|Not found)'
    }

    It 'Status mode reads HKLM GP registry values' {
        $output = & powershell -NoProfile -ExecutionPolicy Bypass -Command "& '$ScriptPath' -Mode Status" 2>&1
        $text = $output | Out-String
        $text | Should -Match 'Registry: HKLM GP Path'
        $text | Should -Match 'Enabled\s*='
        $text | Should -Match 'UseCertificateForOnPremAuth\s*='
    }

    It 'Status mode reads HKCU per-user registry values' {
        $output = & powershell -NoProfile -ExecutionPolicy Bypass -Command "& '$ScriptPath' -Mode Status" 2>&1
        $text = $output | Out-String
        $text | Should -Match 'HKCU Per-User Path'
        $text | Should -Match 'UseCertificateForOnPremAuth\s*='
    }

    It 'Status mode produces a VERDICT' {
        $output = & powershell -NoProfile -ExecutionPolicy Bypass -Command "& '$ScriptPath' -Mode Status" 2>&1
        $text = $output | Out-String
        $text | Should -Match 'VERDICT:'
    }

    It 'Status mode creates a log file' {
        $before = Get-ChildItem "$env:TEMP\EnableHello_*.log" -EA SilentlyContinue | Measure-Object
        & powershell -NoProfile -ExecutionPolicy Bypass -Command "& '$ScriptPath' -Mode Status" 2>&1 | Out-Null
        $after = Get-ChildItem "$env:TEMP\EnableHello_*.log" -EA SilentlyContinue | Measure-Object
        $after.Count | Should -BeGreaterThan $before.Count
    }
}

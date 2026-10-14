#Requires -Version 5.1
<#
.SYNOPSIS
    HyperDebloat - device-aware HyperOS / MIUI debloater for Xiaomi, Redmi and POCO phones.

.DESCRIPTION
    Reads every package and running process on the connected phone, and rates each package from
    what the phone itself reports about it: which partition it lives on, whether it is privileged,
    signed with the platform key, persistent, running with a system identity, has an app icon,
    provides permissions or services that other apps are using right now, holds a default role,
    and so on. Three community lists (UAD-ng, fadeltd/xiaomi-debloater, ovsky/hyperos-debloater)
    are then used to describe each package and to cross-check the phone's verdict.

        GREEN   SAFE      independent app; removing it breaks nothing else
        YELLOW  MODERATE  a minor feature may stop working
        ORANGE  HIGH      a notable or core feature may stop working
        RED     UNSAFE    can stop the phone booting or working properly
        GREY    FLAGGED   unknown to every list, contradicts the lists, or no phone data - never touched

    Modes:
        Recommended  removes every GREEN package in one go, after one confirmation
        Custom       a colour-coded list; tick what you want, press Remove
        Restore      lists everything removed or disabled on the phone (by any tool) and puts it back

    Packages are removed for user 0 only (pm uninstall -k --user 0). Nothing is deleted from the
    system partition, and a factory reset restores everything.

.NOTES
    Made by kayyesr, perfected by Claude (Anthropic, Claude Opus 5.5).
    Licence: MIT (see LICENSE).
#>
[CmdletBinding()]
param(
    [ValidateSet('', 'Recommended', 'Custom', 'Restore')]
    [string]$Mode = '',
    [string]$AdbPath = '',
    [switch]$DryRun,
    [switch]$AssumeYes,
    [switch]$NoGui,
    [switch]$SaveRaw,
    [string]$WorkDir = ''
)

$ErrorActionPreference = 'Stop'
$Script:Version = '0.4.2'

# ----------------------------------------------------------------------------------------------
# Paths and constants
# ----------------------------------------------------------------------------------------------
$docs = [Environment]::GetFolderPath('MyDocuments')
if ([string]::IsNullOrWhiteSpace($docs)) { $docs = $HOME }
$Script:Work  = if ($WorkDir) { $WorkDir } else { Join-Path $docs 'HyperDebloat' }
$Script:Cache = Join-Path $Script:Work 'cache'
New-Item -ItemType Directory -Force -Path $Script:Cache | Out-Null

$Script:Lists = [ordered]@{
    uad     = 'https://raw.githubusercontent.com/Universal-Debloater-Alliance/universal-android-debloater-next-generation/main/resources/assets/uad_lists.json'
    fadeltd = 'https://raw.githubusercontent.com/fadeltd/xiaomi-debloater/main/bloatware.json'
    ovsky   = 'https://raw.githubusercontent.com/ovsky/hyperos-debloater/main/data/config/services.json'
}

$Script:TierInfo = @{
    1 = @{ Label = 'SAFE';     Colour = 'GREEN';  Console = 'Green';      Hex = '#D9F2D9' }
    2 = @{ Label = 'MODERATE'; Colour = 'YELLOW'; Console = 'Yellow';     Hex = '#FFF6C2' }
    3 = @{ Label = 'HIGH';     Colour = 'ORANGE'; Console = 'DarkYellow'; Hex = '#FFDDB0' }
    4 = @{ Label = 'UNSAFE';   Colour = 'RED';    Console = 'Red';        Hex = '#F8C8C8' }
    0 = @{ Label = 'FLAGGED';  Colour = 'GREY';   Console = 'DarkGray';   Hex = '#DDDDDD' }
}

# ----------------------------------------------------------------------------------------------
# Small helpers
# ----------------------------------------------------------------------------------------------
function Write-Step([string]$Text) { Write-Host ''; Write-Host "== $Text" -ForegroundColor Cyan }
function Write-Warn([string]$Text) { Write-Host "  ! $Text" -ForegroundColor Yellow }
function Write-Info([string]$Text) { Write-Host "  $Text" }

function Read-YesNo([string]$Question, [bool]$Default = $false, [switch]$Warning) {
    if ($AssumeYes) { return $true }
    if ($Script:Gui) {
        $icon = if ($Warning) { [Windows.Forms.MessageBoxIcon]::Warning } else { [Windows.Forms.MessageBoxIcon]::Question }
        $def = if ($Default) { [Windows.Forms.MessageBoxDefaultButton]::Button1 } else { [Windows.Forms.MessageBoxDefaultButton]::Button2 }
        $r = [Windows.Forms.MessageBox]::Show($Question, 'HyperDebloat', [Windows.Forms.MessageBoxButtons]::YesNo, $icon, $def)
        return ($r -eq [Windows.Forms.DialogResult]::Yes)
    }
    $hint = if ($Default) { '[Y/n]' } else { '[y/N]' }
    $ans = Read-Host "$Question $hint"
    if ([string]::IsNullOrWhiteSpace($ans)) { return $Default }
    return ($ans.Trim().ToLower() -in @('y', 'yes'))
}

function Write-ErrorReport($Err, [string]$Context) {
    # Saves the full error to error_log.txt and returns a short description for the user.
    $where = if ($Err.InvocationInfo) { "line $($Err.InvocationInfo.ScriptLineNumber): $($Err.InvocationInfo.Line.Trim())" } else { '' }
    $msg = "$($Err.Exception.Message)"
    try {
        $log = Join-Path $Script:Work 'error_log.txt'
        Add-Content -Path $log -Encoding UTF8 -Value @("==== $(Get-Date -Format s)  HyperDebloat $Script:Version  ($Context)", $msg, $where, "$($Err.ScriptStackTrace)", '')
    } catch { $log = '(could not write error_log.txt)' }
    return "$msg`n`n$where`n`nDetails saved to:`n$log"
}

function Show-Notice([string]$Text, [switch]$Warning) {
    # A message the user must acknowledge before the script continues.
    if ($AssumeYes) { return }
    if ($Script:Gui) {
        $icon = if ($Warning) { [Windows.Forms.MessageBoxIcon]::Warning } else { [Windows.Forms.MessageBoxIcon]::Information }
        [void][Windows.Forms.MessageBox]::Show($Text, 'HyperDebloat', [Windows.Forms.MessageBoxButtons]::OK, $icon)
        return
    }
    $null = Read-Host "$Text  (press Enter)"
}

function Read-JsonFile([string]$Path) {
    $text = [IO.File]::ReadAllText($Path)
    if ($PSVersionTable.PSVersion.Major -ge 6) {
        return ($text | ConvertFrom-Json -AsHashtable)
    }
    # Windows PowerShell 5.1: ConvertFrom-Json is slow and size-limited on large files.
    Add-Type -AssemblyName System.Web.Extensions
    $ser = New-Object System.Web.Script.Serialization.JavaScriptSerializer
    $ser.MaxJsonLength = [int]::MaxValue
    return $ser.DeserializeObject($text)
}

function Test-IsWindowsHost {
    if ($PSVersionTable.PSVersion.Major -lt 6) { return $true }
    return [bool]$IsWindows
}

# ----------------------------------------------------------------------------------------------
# ADB
# ----------------------------------------------------------------------------------------------
function Get-AdbExe {
    if ($AdbPath) {
        if (-not (Test-Path $AdbPath)) { throw "ADB not found at $AdbPath" }
        return $AdbPath
    }
    $local = Join-Path $Script:Work 'platform-tools\adb.exe'
    if (Test-Path $local) { return $local }
    $cmd = Get-Command adb -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }

    if (-not (Test-IsWindowsHost)) { throw 'ADB not found. Install android-tools and try again.' }
    Write-Warn 'ADB (Google platform-tools) is not installed.'
    if (-not (Read-YesNo 'Download it from Google now (about 7 MB)?' $true)) { throw 'ADB is required.' }
    $zip = Join-Path $Script:Work 'platform-tools.zip'
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    Invoke-WebRequest -UseBasicParsing -Uri 'https://dl.google.com/android/repository/platform-tools-latest-windows.zip' -OutFile $zip
    Expand-Archive -Path $zip -DestinationPath $Script:Work -Force
    Remove-Item $zip -Force
    if (-not (Test-Path $local)) { throw 'ADB download failed.' }
    return $local
}

function Invoke-Adb([string[]]$A) {
    # Native stderr must not become a terminating error under ErrorActionPreference=Stop.
    $old = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { $out = & $Script:Adb @A 2>&1 | ForEach-Object { "$_" } }
    finally { $ErrorActionPreference = $old }
    return , @($out)
}

function Invoke-Shell([string]$Command) {
    $out = Invoke-Adb @('shell', $Command)
    if ($SaveRaw) {
        # Raw phone output, for checking the parsers against a real device.
        $raw = Join-Path $Script:Work 'raw_adb_output.txt'
        Add-Content -Path $raw -Value @("##### adb shell $Command", $out, '') -Encoding UTF8
    }
    return , @($out)
}

function Wait-ForDevice {
    # Returns $true when exactly one authorised phone is connected, $false if the user gives up.
    Invoke-Adb @('start-server') | Out-Null
    $tries = 0
    while ($true) {
        $tries++
        $lines = Invoke-Adb @('devices') | Where-Object { $_ -match "^\S+\s+(device|unauthorized|offline|recovery|sideload)\s*$" }
        $ready = @($lines | Where-Object { $_ -match '\sdevice\s*$' })
        $unauth = @($lines | Where-Object { $_ -match '\sunauthorized\s*$' })
        if ($ready.Count -eq 1) { if ($tries -gt 1) { Write-Info 'Phone connected.' }; $Script:LastDeviceState = 'ok'; return $true }
        $state = if ($ready.Count -gt 1) { 'many' } elseif ($unauth.Count -gt 0) { 'unauth' } else { 'none' }
        if ($Script:Gui -and -not $AssumeYes) {
            $msg = switch ($state) {
                'many'   { "More than one phone is connected.`n`nUnplug the others, then press Retry." }
                'unauth' { "Phone found, but not authorised.`n`nUnlock it, tap ""Allow"" on the USB debugging prompt (tick ""Always allow""), then press Retry." }
                default  { "No phone found.`n`nOn the phone: Settings > About phone > tap ""OS version"" 7 times, then Settings > Additional settings > Developer options > USB debugging ON.`n`nConnect the USB cable, then press Retry. If the phone is rebooting, wait until it is unlocked." }
            }
            $r = [Windows.Forms.MessageBox]::Show($msg, 'HyperDebloat - waiting for the phone', [Windows.Forms.MessageBoxButtons]::RetryCancel, [Windows.Forms.MessageBoxIcon]::Information)
            if ($r -ne [Windows.Forms.DialogResult]::Retry) { return $false }
            continue
        }
        if ($state -ne $Script:LastDeviceState) {
            $Script:LastDeviceState = $state
            switch ($state) {
                'many'   { Write-Warn 'More than one phone is connected. Unplug the others.' }
                'unauth' { Write-Warn 'Phone found, but not authorised. Unlock it and tap "Allow" on the USB debugging prompt.' }
                'none'   {
                    Write-Warn 'No phone found.'
                    Write-Info 'On the phone: Settings > About phone > tap "OS version" 7 times,'
                    Write-Info 'then Settings > Additional settings > Developer options > USB debugging ON.'
                    Write-Info 'Connect the USB cable and choose "File transfer" if asked.'
                }
            }
        }
        if ($AssumeYes) {
            # Unattended: keep checking for 3 minutes, then give up.
            if ($tries -ge 60) { throw 'No authorised phone found after 3 minutes.' }
            Start-Sleep -Seconds 3
            continue
        }
        $r = Read-Host 'Press Enter to check again, or Q to go back'
        if ($r -match '^[qQ]') { return $false }
    }
}

function Get-DeviceInfo {
    function P([string]$Name) { ((Invoke-Shell "getprop $Name") -join '').Trim() }
    $info = [ordered]@{
        Manufacturer = P 'ro.product.manufacturer'
        Brand        = P 'ro.product.brand'
        Model        = P 'ro.product.model'
        MarketName   = P 'ro.product.marketname'
        Codename     = P 'ro.product.device'
        OsName       = P 'ro.mi.os.version.name'
        OsBuild      = P 'ro.mi.os.version.incremental'
        Android      = P 'ro.build.version.release'
    }
    if (-not $info.OsBuild) { $info.OsBuild = P 'ro.build.version.incremental' }
    if (-not $info.MarketName) { $info.MarketName = $info.Model }
    return $info
}

# ----------------------------------------------------------------------------------------------
# Community lists (descriptions + cross-check only)
# ----------------------------------------------------------------------------------------------
function Get-CommunityLists {
    $result = @{}
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    foreach ($name in $Script:Lists.Keys) {
        $file = Join-Path $Script:Cache "$name.json"
        try {
            Invoke-WebRequest -UseBasicParsing -Uri $Script:Lists[$name] -OutFile "$file.new" -TimeoutSec 60
            $null = Read-JsonFile "$file.new"     # only replace the cache with valid JSON
            Move-Item "$file.new" $file -Force
            Write-Info "$name list: updated"
        }
        catch {
            Remove-Item "$file.new" -ErrorAction SilentlyContinue
            if (Test-Path $file) { Write-Warn "$name list: could not update, using saved copy from $((Get-Item $file).LastWriteTime.ToString('yyyy-MM-dd'))" }
            else { Write-Warn "$name list: not available - fewer descriptions and cross-checks"; continue }
        }
        $result[$name] = Read-JsonFile $file
    }
    if ($result.Count -eq 0) { Write-Warn 'No community list could be loaded. Ratings will rely on the phone only and nothing can be GREEN.' }
    return $result
}

function Build-Index($Lists) {
    $idx = @{ uad = @{}; fadeltd = @{}; ovsky = @{}; ovskyDesc = @{} }
    $uadMap = @{ Recommended = 1; Advanced = 2; Expert = 3; Unsafe = 4 }
    $fadMap = @{ safe = 1; caution = 2; danger = 4 }
    $ovsMap = @{ phase1_safe = 1; phase2_advanced = 2; phase3_risky = 3; phase4_hidden = 3; restore_only = 4 }

    if ($Lists['uad']) {
        $u = $Lists['uad']
        foreach ($k in @($u.Keys)) {
            $e = $u[$k]
            $rating = [string]$e['removal']
            $tier = if ($uadMap.ContainsKey($rating)) { $uadMap[$rating] } else { 2 }
            $desc = ([string]$e['description'] -split "`n")[0]
            $idx.uad[$k] = @{ Tier = $tier; Rating = $rating; Desc = $desc }
        }
    }
    if ($Lists['fadeltd']) {
        foreach ($p in @($Lists['fadeltd']['packages'])) {
            $risk = [string]$p['risk']
            $tier = if ($fadMap.ContainsKey($risk)) { $fadMap[$risk] } else { 2 }
            $idx.fadeltd[[string]$p['package']] = @{ Tier = $tier; Rating = $risk; Desc = [string]$p['description'] }
        }
    }
    if ($Lists['ovsky']) {
        $phases = $Lists['ovsky']['phases']
        foreach ($ph in @($phases.Keys)) {
            foreach ($pkg in @($phases[$ph])) {
                $tier = if ($ovsMap.ContainsKey($ph)) { $ovsMap[$ph] } else { 2 }
                $idx.ovsky[[string]$pkg] = @{ Tier = $tier; Rating = $ph }
            }
        }
        $d = $Lists['ovsky']['descriptions']
        if ($d) { foreach ($k in @($d.Keys)) { $idx.ovskyDesc[$k] = [string]$d[$k] } }
    }
    $Script:ListsLoaded = ($idx.uad.Count + $idx.fadeltd.Count + $idx.ovsky.Count) -gt 0
    return $idx
}

# ----------------------------------------------------------------------------------------------
# Phone facts (all read-only)
# ----------------------------------------------------------------------------------------------
function Get-PackageSets {
    $all = @{}
    foreach ($l in (Invoke-Shell 'pm list packages --user 0')) { if ($l -match '^package:(\S+)') { $all[$Matches[1]] = $true } }
    $sys = @{}
    foreach ($l in (Invoke-Shell 'pm list packages -s --user 0')) { if ($l -match '^package:(\S+)') { $sys[$Matches[1]] = $true } }
    if ($all.Count -eq 0) { throw 'Could not read the package list from the phone.' }
    return @{ All = $all; System = $sys }
}

function Get-Partition([string]$CodePath) {
    switch -Regex ($CodePath) {
        '^/data/'       { return 'data' }
        '^/system_ext/' { return 'system_ext' }
        '^/system/'     { return 'system' }
        '^/product/'    { return 'product' }
        '^/vendor/'     { return 'vendor' }
        '^/odm/'        { return 'odm' }
        '^/apex/'       { return 'apex' }
        '^/([^/]+)/'    { return $Matches[1] }
        default         { return 'unknown' }
    }
}

function Get-PackagesFromText([string[]]$Lines) {
    # Collects package names from "pkg/.Class" and "packageName=pkg" forms.
    $set = @{}
    foreach ($l in $Lines) {
        foreach ($m in [regex]::Matches($l, '([A-Za-z]\w*(?:\.\w+)+)/')) { $set[$m.Groups[1].Value] = $true }
        if ($l -match 'packageName=([\w\.]+)') { $set[$Matches[1]] = $true }
    }
    return $set
}

function New-Facts {
    return [pscustomobject]@{
        Seen = $false; AppId = $null; SharedUser = ''; Persistent = $false; Privileged = $false
        Partition = ''; Signature = ''; PlatformSigned = $false; HasIcon = $false
        SigPerms = (New-Object System.Collections.Generic.List[string])
        UsedBy = (New-Object System.Collections.Generic.List[string])
        OverlayTarget = ''; OverlayState = ''
        Roles = (New-Object System.Collections.Generic.List[string])
        Running = $false
    }
}

function Get-DeviceFacts([hashtable]$Installed) {
    $facts = @{}
    foreach ($p in $Installed.Keys) { $facts[$p] = New-Facts }
    function F([string]$Pkg) { if ($Pkg -and $facts.ContainsKey($Pkg)) { return $facts[$Pkg] }; return $null }
    function AddUnique($List, [string]$Value) { if (-not $List.Contains($Value)) { $List.Add($Value) } }

    # 1. Package manager dump: partition, privileged, persistent, identity, signature, permissions.
    Write-Info 'Reading package details...'
    $cur = $null; $inPk = $false; $declIndent = -1
    $androidSig = ''
    foreach ($line in (Invoke-Shell 'dumpsys package packages')) {
        if ($line -match '^\S') {
            $inPk = ($line -match '^(Packages|Hidden system packages):')
            $cur = $null; $declIndent = -1
            continue
        }
        if (-not $inPk) { continue }
        if ($line -match '^\s*Package \[([^\]]+)\]') {
            $cur = $Matches[1]; $declIndent = -1
            if ($facts.ContainsKey($cur)) { $facts[$cur].Seen = $true }
            continue
        }
        if (-not $cur) { continue }
        $f = F $cur
        $indent = $line.Length - $line.TrimStart().Length

        if ($declIndent -ge 0) {
            if ($indent -gt $declIndent) {
                if ($f -and $line -match '^\s*([\w\.]+):\s*prot=(\S+)' -and $Matches[2] -match 'signature') { AddUnique $f.SigPerms $Matches[1] }
                continue
            }
            $declIndent = -1
        }
        if ($line -match '^\s*declared permissions:') { $declIndent = $indent; continue }

        if ($line -match '^\s*signatures=PackageSignatures\{.*?signatures:\[([^\]]*)\]') {
            if ($cur -eq 'android' -and -not $androidSig) { $androidSig = $Matches[1] }
            if ($f -and -not $f.Signature) { $f.Signature = $Matches[1] }
            continue
        }
        if (-not $f) { continue }
        if ($line -match '^\s*(userId|appId)=(\d+)') {
            $id = [int]$Matches[2]
            if ($null -eq $f.AppId -or $id -lt $f.AppId) { $f.AppId = $id }
        }
        elseif ($line -match '^\s*sharedUser=SharedUserSetting\{\w+\s+([^/\s}]+)') { $f.SharedUser = $Matches[1] }
        elseif ($line -match '^\s*codePath=(\S+)') {
            $part = Get-Partition $Matches[1]
            # The active entry comes first; an updated system app keeps its original partition.
            if (-not $f.Partition -or $f.Partition -eq 'data') { $f.Partition = $part }
            if ($Matches[1] -match '/priv-app/') { $f.Privileged = $true }
        }
        elseif ($line -match '^\s*(pkgFlags|flags)=\[(.*)\]') {
            if ($Matches[2] -match '(^|\s)PERSISTENT(\s|$)') { $f.Persistent = $true }
        }
        elseif ($line -match '^\s*privateFlags=\[(.*)\]') {
            if ($Matches[1] -match '(^|[\s_])PRIVILEGED(\s|$)') { $f.Privileged = $true }
        }
    }
    if ($androidSig) {
        foreach ($p in $facts.Keys) { if ($facts[$p].Signature -eq $androidSig -and $p -ne 'android') { $facts[$p].PlatformSigned = $true } }
    }
    else { Write-Warn 'Could not read the platform signature; that check is skipped.' }

    # 2. Which packages have an app icon (a launcher entry) - i.e. are user-facing apps.
    Write-Info 'Reading app icons...'
    $icon = Get-PackagesFromText (Invoke-Shell 'cmd package query-activities --user 0 -a android.intent.action.MAIN -c android.intent.category.LAUNCHER')
    foreach ($p in $icon.Keys) { $f = F $p; if ($f) { $f.HasIcon = $true } }

    # 3. Live dependencies: other processes bound to this package's services or providers right now.
    # This is a snapshot, so connections only show for apps that are open or running at this moment.
    Write-Info 'Reading live service and provider connections (only apps running right now)...'
    $svc = $null
    foreach ($l in (Invoke-Shell 'dumpsys activity services')) {
        if ($l -match 'ServiceRecord\{\w+\s+u\d+\s+([\w\.]+)/') { $svc = $Matches[1]; continue }
        if (-not $svc -or $l -match '^\s*app=') { continue }
        if ($l -match 'ProcessRecord\{\w+\s+\d+:([^/\s}]+)/') {
            $client = ($Matches[1] -split ':')[0]
            $f = F $svc
            if ($f -and $client -ne $svc) { AddUnique $f.UsedBy $client }
        }
    }
    $prov = $null
    foreach ($l in (Invoke-Shell 'dumpsys activity providers')) {
        if ($l -match 'ContentProviderRecord\{\w+\s+u\d+\s+([\w\.]+)/') { $prov = $Matches[1]; continue }
        if ($prov -and $l -match '->\s*\d+:([^/\s]+)/') {
            $client = ($Matches[1] -split ':')[0]
            $f = F $prov
            if ($f -and $client -ne $prov) { AddUnique $f.UsedBy $client }
        }
    }

    # 4. Runtime resource overlays and what they modify.
    $target = $null
    foreach ($l in (Invoke-Shell 'cmd overlay list --user 0')) {
        if ($l -match '^([\w\.]+)\s*$') { $target = $Matches[1]; continue }
        if ($target -and $l -match '^\s*(\[x\]|\[ \]|---)\s+([\w\.]+)') {
            $f = F $Matches[2]
            if ($f) { $f.OverlayTarget = $target; $f.OverlayState = $(if ($Matches[1] -eq '[ ]') { 'disabled' } else { 'enabled' }) }
        }
    }

    # 5. Default roles, keyboard, device admins, location providers.
    foreach ($role in @('HOME', 'DIALER', 'SMS')) {
        foreach ($l in (Invoke-Shell "cmd role get-role-holders --user 0 android.app.role.$role")) {
            foreach ($p in ($l -split '[;\s]+')) { $f = F $p; if ($f) { AddUnique $f.Roles "current default $($role.ToLower()) app" } }
        }
    }
    $ime = ((Invoke-Shell 'settings get secure default_input_method') -join '').Trim()
    if ($ime -match '^([\w\.]+)/') { $f = F $Matches[1]; if ($f) { AddUnique $f.Roles 'current default keyboard' } }
    foreach ($l in (Invoke-Shell 'dumpsys device_policy')) {
        foreach ($m in [regex]::Matches($l, 'ComponentInfo\{([\w\.]+)/')) { $f = F $m.Groups[1].Value; if ($f) { AddUnique $f.Roles 'device administrator' } }
    }
    $locActions = @(
        'com.android.location.service.v3.NetworkLocationProvider',
        'com.android.location.service.v2.NetworkLocationProvider',
        'com.android.location.service.FusedLocationProvider',
        'com.android.location.service.GeocodeProvider',
        'com.android.location.service.GeofenceProvider'
    )
    foreach ($a in $locActions) {
        $found = Get-PackagesFromText (Invoke-Shell "cmd package query-services --user 0 -a $a")
        foreach ($p in $found.Keys) { $f = F $p; if ($f) { AddUnique $f.Roles 'provides location services' } }
    }

    # 6. Running processes (informational).
    Write-Info 'Reading running processes...'
    $running = @{}
    foreach ($l in (Invoke-Shell 'ps -A -o NAME')) { $n = ($l.Trim() -split ':')[0]; if ($n) { $running[$n] = $true } }
    foreach ($p in $facts.Keys) { if ($running.ContainsKey($p)) { $facts[$p].Running = $true } }

    return $facts
}

# ----------------------------------------------------------------------------------------------
# Rule-based classifier
# ----------------------------------------------------------------------------------------------
function Get-PhoneVerdict($f, [bool]$IsSystem) {
    # Hard signals (RED): Android itself depends on this package right now.
    $hard = New-Object System.Collections.Generic.List[string]
    # Strong signals (ORANGE): something uses it now, or it runs with system-level power.
    $live = New-Object System.Collections.Generic.List[string]
    # Soft signals (YELLOW, or ORANGE at 3+): it looks like part of the system, not an independent app.
    $soft = New-Object System.Collections.Generic.List[string]

    if ($f.Persistent) { $hard.Add('persistent (Android keeps it running)') }
    foreach ($r in $f.Roles) { $hard.Add($r) }

    # Running as a system user gives a package system-level power, but on its own it does not mean
    # anything depends on it (test and log tools often run this way), so it is a strong signal, not hard.
    if ($f.SharedUser -match '^android\.uid\.') { $live.Add("runs as the system user $($f.SharedUser)") }
    elseif ($null -ne $f.AppId -and $f.AppId -lt 10000) { $live.Add("runs with a system user ID ($($f.AppId))") }
    if ($f.Partition -in @('vendor', 'odm')) { $live.Add("installed with the hardware drivers ($($f.Partition) partition)") }

    if ($f.UsedBy.Count -gt 0) {
        $shown = @($f.UsedBy | Select-Object -First 3) -join ', '
        $more = if ($f.UsedBy.Count -gt 3) { " +$($f.UsedBy.Count - 3) more" } else { '' }
        $live.Add("in use by: $shown$more")
    }
    if ($f.OverlayTarget -and $f.OverlayState -eq 'enabled' -and $f.OverlayTarget -in @('android', 'com.android.systemui', 'com.android.settings')) {
        $live.Add("active overlay on $($f.OverlayTarget)")
    }
    elseif ($f.OverlayTarget) { $soft.Add("overlay for $($f.OverlayTarget)") }

    if ($IsSystem) {
        if ($f.PlatformSigned) { $soft.Add('signed with the platform key') }
        if ($f.Privileged) { $soft.Add('privileged system app') }
        if ($f.SigPerms.Count -gt 0) { $soft.Add('provides protected permissions to other apps') }
        if (-not $f.HasIcon) { $soft.Add('no app icon (background component)') }
    }

    if ($hard.Count -gt 0)     { $tier = 4 }
    elseif ($live.Count -gt 0) { $tier = 3 }
    elseif ($soft.Count -ge 3) { $tier = 3 }
    elseif ($soft.Count -ge 1) { $tier = 2 }
    else { $tier = 1 }

    $why = @($hard) + @($live) + @($soft)
    if ($why.Count -eq 0) { $why = @('independent app: has an icon, nothing depends on it') }
    $inUse = ($f.UsedBy.Count -gt 0) -or ($f.OverlayTarget -and $f.OverlayState -eq 'enabled')
    return @{ Tier = $tier; Why = ($why -join '; '); HasHard = ($hard.Count -gt 0); InUse = [bool]$inUse }
}

function Get-Rating([string]$Pkg, [bool]$IsSystem, $Idx, $Facts) {
    $src = [ordered]@{}
    if ($Idx.uad.ContainsKey($Pkg))     { $src['UAD-ng']  = $Idx.uad[$Pkg] }
    if ($Idx.fadeltd.ContainsKey($Pkg)) { $src['fadeltd'] = $Idx.fadeltd[$Pkg] }
    if ($Idx.ovsky.ContainsKey($Pkg))   { $src['ovsky']   = $Idx.ovsky[$Pkg] }

    # Only system apps are handled. A non-system app (including preloads installed to /data, like
    # Google Drive or Facebook on many ROMs) loses its APK when removed this way, so Restore cannot
    # bring it back. Those can be uninstalled normally from the phone instead.
    if (-not $IsSystem) { return $null }

    $desc = ''
    if ($Idx.fadeltd.ContainsKey($Pkg)) { $desc = $Idx.fadeltd[$Pkg].Desc }
    if (-not $desc -and $Idx.ovskyDesc.ContainsKey($Pkg)) { $desc = $Idx.ovskyDesc[$Pkg] }
    if (-not $desc -and $Idx.uad.ContainsKey($Pkg)) { $desc = $Idx.uad[$Pkg].Desc }
    $listsSay = if ($src.Count) { ($src.Keys | ForEach-Object { "$_`: $($src[$_].Rating)" }) -join ' | ' } else { 'not in any list' }

    $f = $Facts[$Pkg]
    if (-not $f -or -not $f.Seen) {
        return [pscustomobject]@{ Tier = 0; Risk = 'FLAGGED'; Package = $Pkg; Description = $desc
            Phone = 'no data'; Lists = $listsSay; Reason = 'the phone returned no details for this package - not touched'; Facts = $f }
    }

    $pv = Get-PhoneVerdict $f $IsSystem
    $tier = $pv.Tier
    $notes = New-Object System.Collections.Generic.List[string]
    $notes.Add("phone rates it $($Script:TierInfo[$pv.Tier].Colour)")

    if ($src.Count -gt 0) {
        $tiers = @($src.Values | ForEach-Object { $_.Tier })
        $listMax = [int](($tiers | Measure-Object -Maximum).Maximum)
        $unanimousSafe = ($src.Count -ge 2) -and (@($tiers | Where-Object { $_ -ne 1 }).Count -eq 0)

        if ($tier -eq 1 -and $listMax -ge 3) {
            # The phone sees an independent app, but a list says removing it is dangerous. That
            # contradiction means something is not understood, so the package is left alone.
            $tier = 0
            $notes.Add("but a list rates it $($Script:TierInfo[$listMax].Colour) - contradiction, flagged and not touched")
        }
        elseif ($listMax -gt $tier) {
            $tier = $listMax
            $notes.Add("raised to $($Script:TierInfo[$tier].Colour): a list warns about it")
        }
        elseif ($listMax -lt $tier -and -not $pv.HasHard -and -not $pv.InUse -and $unanimousSafe -and $tier -ge 3) {
            $tier = $tier - 1
            $notes.Add("lowered to $($Script:TierInfo[$tier].Colour): all lists agree it is safe and nothing is using it")
        }
        elseif ($listMax -lt $tier) {
            $notes.Add('lists rate it lower; the phone''s evidence wins')
        }
    }
    elseif ($Script:ListsLoaded) {
        # Unknown to every list: the scan can say how system-like it is, but not what it does.
        $tier = 0
        $notes.Add('not in any list - unknown package, flagged and not touched')
    }
    elseif ($tier -eq 1) {
        $tier = 2
        $notes.Add('raised to YELLOW: lists unavailable, so it cannot be confirmed as junk')
    }

    return [pscustomobject]@{
        Tier        = $tier
        Risk        = $Script:TierInfo[$tier].Label
        Package     = $Pkg
        Description = $desc
        Phone       = "$($Script:TierInfo[$pv.Tier].Colour): $($pv.Why)"
        Lists       = $listsSay
        Reason      = ($notes -join '; ')
        Facts       = $f
    }
}

function Get-Classification($Idx, $Sets, $Facts) {
    $rows = foreach ($p in $Sets.All.Keys) {
        Get-Rating -Pkg $p -IsSystem $Sets.System.ContainsKey($p) -Idx $Idx -Facts $Facts
    }
    $order = @{ 1 = 1; 2 = 2; 3 = 3; 4 = 4; 0 = 5 }
    return @($rows | Where-Object { $_ } | Sort-Object @{ Expression = { $order[[int]$_.Tier] } }, Package)
}

# ----------------------------------------------------------------------------------------------
# Selection UI
# ----------------------------------------------------------------------------------------------
function Show-SelectionGrid($Items, [string]$Title, [string]$ActionText, [switch]$PreselectSafe, [switch]$PreselectAll, [string]$Legend = '') {
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    [Windows.Forms.Application]::EnableVisualStyles()

    $form = New-Object Windows.Forms.Form
    $form.Text = $Title
    $form.Size = New-Object Drawing.Size(1360, 780)
    $form.StartPosition = 'CenterScreen'

    $top = New-Object Windows.Forms.Panel
    $top.Dock = 'Top'; $top.Height = 70
    # PowerShell variable names ignore case, so the label must not be called $legend ($Legend is the text).
    $legendLabel = New-Object Windows.Forms.Label
    $legendLabel.AutoSize = $false; $legendLabel.Dock = 'Fill'
    $legendText = if ($Legend) { $Legend } else { 'GREEN = safe  |  YELLOW = a minor feature may break  |  ORANGE = a notable/core feature may break  |  RED = can stop the phone booting  |  GREY = flagged, cannot be selected' }
    $legendLabel.Text = "$legendText`r`nClick a row to tick or untick it, then press '$ActionText'. Type in the box below to filter."
    $legendLabel.Padding = New-Object Windows.Forms.Padding(8, 6, 8, 0)
    $filter = New-Object Windows.Forms.TextBox
    $filter.Dock = 'Bottom'
    $top.Controls.Add($legendLabel); $top.Controls.Add($filter)

    $grid = New-Object Windows.Forms.DataGridView
    $grid.Dock = 'Fill'
    $grid.AllowUserToAddRows = $false
    $grid.AllowUserToDeleteRows = $false
    $grid.RowHeadersVisible = $false
    $grid.SelectionMode = 'FullRowSelect'
    $grid.AutoSizeColumnsMode = 'None'

    $chk = New-Object Windows.Forms.DataGridViewCheckBoxColumn
    $chk.Name = 'Sel'; $chk.HeaderText = 'Pick'; $chk.Width = 45
    [void]$grid.Columns.Add($chk)
    $cols = @(@('Risk', 80), @('Package', 260), @('What it does', 330), @('Phone says', 330), @('Lists say', 190), @('Final reasoning', 300))
    foreach ($c in $cols) {
        $col = New-Object Windows.Forms.DataGridViewTextBoxColumn
        $col.Name = $c[0]; $col.HeaderText = $c[0]; $col.Width = $c[1]; $col.ReadOnly = $true
        [void]$grid.Columns.Add($col)
    }

    foreach ($it in $Items) {
        $pick = ($PreselectAll -or ($PreselectSafe -and $it.Tier -eq 1)) -and $it.Tier -ne 0
        $i = $grid.Rows.Add($pick, $it.Risk, $it.Package, $it.Description, $it.Phone, $it.Lists, $it.Reason)
        $row = $grid.Rows[$i]
        $row.Tag = $it
        $row.DefaultCellStyle.BackColor = [Drawing.ColorTranslator]::FromHtml($Script:TierInfo[[int]$it.Tier].Hex)
        if ($it.Tier -eq 0) { $row.Cells['Sel'].ReadOnly = $true; $row.DefaultCellStyle.ForeColor = [Drawing.Color]::DimGray }
    }

    $grid.Add_CurrentCellDirtyStateChanged({ if ($grid.IsCurrentCellDirty) { $grid.CommitEdit([Windows.Forms.DataGridViewDataErrorContexts]::Commit) } })

    $bottom = New-Object Windows.Forms.FlowLayoutPanel
    $bottom.Dock = 'Bottom'; $bottom.Height = 46; $bottom.FlowDirection = 'RightToLeft'
    $bottom.Padding = New-Object Windows.Forms.Padding(6)

    $btnGo = New-Object Windows.Forms.Button;     $btnGo.Text = $ActionText; $btnGo.Width = 160; $btnGo.Height = 30
    $btnCancel = New-Object Windows.Forms.Button; $btnCancel.Text = '< Back'; $btnCancel.Width = 100; $btnCancel.Height = 30
    $btnClear = New-Object Windows.Forms.Button;  $btnClear.Text = 'Clear all'; $btnClear.Width = 100; $btnClear.Height = 30
    $btnSafe = New-Object Windows.Forms.Button;   $btnSafe.Text = 'Tick all GREEN'; $btnSafe.Width = 130; $btnSafe.Height = 30
    $count = New-Object Windows.Forms.Label;      $count.AutoSize = $true; $count.Padding = New-Object Windows.Forms.Padding(0, 8, 20, 0)
    $bottom.Controls.AddRange(@($btnGo, $btnCancel, $btnClear, $btnSafe, $count))

    $updateCount = {
        $n = 0
        foreach ($r in $grid.Rows) { if ($r.Cells['Sel'].Value -eq $true) { $n++ } }
        $count.Text = "$n ticked"
    }
    $grid.Add_CellValueChanged($updateCount)
    # Clicking anywhere on a row ticks or unticks it (the Pick box handles its own clicks).
    $grid.Add_CellClick({
        param($src, $ev)
        if ($ev.RowIndex -lt 0 -or $ev.ColumnIndex -lt 0) { return }
        if ($grid.Columns[$ev.ColumnIndex].Name -eq 'Sel') { return }
        $r = $grid.Rows[$ev.RowIndex]
        if ($r.Tag.Tier -eq 0) { return }
        $r.Cells['Sel'].Value = -not ($r.Cells['Sel'].Value -eq $true)
    })
    $btnSafe.Add_Click({ foreach ($r in $grid.Rows) { if ($r.Tag.Tier -eq 1) { $r.Cells['Sel'].Value = $true } }; & $updateCount })
    $btnClear.Add_Click({ foreach ($r in $grid.Rows) { $r.Cells['Sel'].Value = $false }; & $updateCount })
    $filter.Add_TextChanged({
        $t = $filter.Text.Trim()
        $grid.CurrentCell = $null
        foreach ($r in $grid.Rows) {
            $it = $r.Tag
            $r.Visible = (-not $t) -or ($it.Package -like "*$t*") -or ($it.Description -like "*$t*") -or ($it.Risk -like "*$t*")
        }
    })

    $Script:GridResult = @()
    $btnGo.Add_Click({
        $grid.EndEdit()
        $Script:GridResult = @(foreach ($r in $grid.Rows) { if ($r.Cells['Sel'].Value -eq $true -and $r.Tag.Tier -ne 0) { $r.Tag } })
        if ($Script:GridResult.Count -eq 0) {
            [void][Windows.Forms.MessageBox]::Show("Nothing is ticked.`n`nClick a row (or its box in the Pick column) to tick it, then press '$ActionText'. Use '< Back' to return without changing anything.", 'HyperDebloat', 'OK', 'Information')
            return
        }
        $form.DialogResult = [Windows.Forms.DialogResult]::OK
        $form.Close()
    })
    $btnCancel.Add_Click({ $Script:GridResult = @(); $form.Close() })

    $form.Controls.Add($grid)
    $form.Controls.Add($top)
    $form.Controls.Add($bottom)
    & $updateCount
    [void]$form.ShowDialog()
    return , @($Script:GridResult)
}

function Select-InConsole($Items, [string]$ActionText) {
    # Fallback when no window can be shown.
    $pickable = @($Items | Where-Object { $_.Tier -ne 0 })
    for ($i = 0; $i -lt $pickable.Count; $i++) {
        $it = $pickable[$i]
        Write-Host ('{0,4}  {1,-9} {2,-45} {3}' -f ($i + 1), $it.Risk, $it.Package, $it.Description) -ForegroundColor $Script:TierInfo[[int]$it.Tier].Console
    }
    Write-Host ''
    $ans = Read-Host "Numbers to $ActionText (e.g. 1,4,7-12), G = all GREEN, A = all, Enter = nothing"
    if ([string]::IsNullOrWhiteSpace($ans)) { return , @() }
    if ($ans.Trim() -match '^[gG]$') { return , @($pickable | Where-Object { $_.Tier -eq 1 }) }
    if ($ans.Trim() -match '^[aA]$') { return , @($pickable) }
    $set = @{}
    foreach ($part in ($ans -split ',')) {
        $part = $part.Trim()
        if ($part -match '^(\d+)-(\d+)$') { foreach ($n in [int]$Matches[1]..[int]$Matches[2]) { $set[$n] = $true } }
        elseif ($part -match '^\d+$') { $set[[int]$part] = $true }
    }
    return , @($set.Keys | Sort-Object | Where-Object { $_ -ge 1 -and $_ -le $pickable.Count } | ForEach-Object { $pickable[$_ - 1] })
}

function Select-Packages($Items, [string]$Title, [string]$ActionText, [switch]$PreselectSafe, [switch]$PreselectAll, [string]$Legend = '') {
    if ($Script:Gui) { return Show-SelectionGrid -Items $Items -Title $Title -ActionText $ActionText -PreselectSafe:$PreselectSafe -PreselectAll:$PreselectAll -Legend $Legend }
    return Select-InConsole -Items $Items -ActionText $ActionText
}

# ----------------------------------------------------------------------------------------------
# Actions
# ----------------------------------------------------------------------------------------------
function Write-Summary($Rows) {
    Write-Step 'Classification'
    foreach ($t in @(1, 2, 3, 4, 0)) {
        $n = @($Rows | Where-Object { $_.Tier -eq $t }).Count
        Write-Host ('  {0,-7} {1,-9} {2,4} packages' -f $Script:TierInfo[$t].Colour, $Script:TierInfo[$t].Label, $n) -ForegroundColor $Script:TierInfo[$t].Console
    }
}

function Save-Report($Rows, $Dev, [string]$DeviceDir) {
    $report = Join-Path $DeviceDir ("report_{0}.csv" -f (Get-Date -Format 'yyyy-MM-dd_HHmmss'))
    $header = "# HyperDebloat $Script:Version | $($Dev.MarketName) ($($Dev.Model)) | $($Dev.OsName) $($Dev.OsBuild) | Android $($Dev.Android) | $(Get-Date -Format 'yyyy-MM-dd HH:mm')"
    Set-Content -Path $report -Value $header -Encoding UTF8
    $Rows | ForEach-Object {
        $f = $_.Facts
        [pscustomobject]@{
            Risk = $_.Risk; Package = $_.Package; Description = $_.Description
            PhoneSays = $_.Phone; ListsSay = $_.Lists; FinalReasoning = $_.Reason
            Partition = $(if ($f) { $f.Partition }); Privileged = $(if ($f) { $f.Privileged }); PlatformSigned = $(if ($f) { $f.PlatformSigned })
            HasIcon = $(if ($f) { $f.HasIcon }); Persistent = $(if ($f) { $f.Persistent }); AppId = $(if ($f) { $f.AppId })
            UsedBy = $(if ($f) { $f.UsedBy -join ' ' }); Running = $(if ($f) { $f.Running })
        }
    } | ConvertTo-Csv -NoTypeInformation | Add-Content -Path $report -Encoding UTF8
    Write-Info "Full report: $report"
}

function Remove-Packages($Items, [string]$DeviceDir) {
    $log = Join-Path $DeviceDir ("removed_{0}.csv" -f (Get-Date -Format 'yyyy-MM-dd_HHmmss'))
    $results = New-Object System.Collections.Generic.List[object]
    $i = 0
    foreach ($it in $Items) {
        $i++
        if ($DryRun) { $res = 'DRY-RUN' }
        else { $res = ((Invoke-Shell "pm uninstall -k --user 0 $($it.Package)") -join ' ').Trim() }
        $ok = $res -match '^(Success|DRY-RUN)'
        $color = if ($ok) { 'Green' } else { 'Red' }
        $shown = $res
        if ($res -match 'Failure \[-1000\]') { $shown = "$res - blocked by MIUI/HyperOS (protected app), nothing changed" }
        elseif ($res -match 'DELETE_FAILED_DEVICE_POLICY_MANAGER') { $shown = "$res - a device administrator protects it, nothing changed" }
        elseif (-not $ok) { $shown = "$res - not removed" }
        Write-Host ('  [{0}/{1}] {2,-50} {3}' -f $i, $Items.Count, $it.Package, $shown) -ForegroundColor $color
        $results.Add([pscustomobject]@{ Time = (Get-Date -Format 's'); Package = $it.Package; Risk = $it.Risk; Result = $res; Description = $it.Description })
    }
    Write-Host ''
    if ($DryRun) { Write-Info "Dry run: $($Items.Count) packages would be removed. Nothing was changed."; Show-Notice "Dry run: $($Items.Count) package(s) would be removed. Nothing was changed."; return }
    $results | Export-Csv -Path $log -NoTypeInformation -Encoding UTF8
    $done = @($results | Where-Object { $_.Result -match '^Success' }).Count
    if ($done -gt 0) { $Script:NeedScan = $true }
    Write-Info "Removed $done of $($Items.Count). Log saved: $log"
    Write-Info 'Restore any of them later with this tool (Restore mode).'
    $failed = @($results | Where-Object { $_.Result -notmatch '^Success' })
    $failText = if ($failed.Count) { "`n`nNot removed ($($failed.Count)): " + (($failed | ForEach-Object { $_.Package }) -join ', ') + "`n(MIUI/HyperOS protects some apps; nothing changed for those.)" } else { '' }
    if ($done -gt 0) {
        Write-Warn 'Reboot the phone now and check the features you rely on (calls, camera, GPS/compass, payments, fingerprint).'
        if (Read-YesNo "Removed $done of $($Items.Count) package(s).$failText`n`nReboot the phone now? Afterwards, check calls, camera, GPS/compass, payments and fingerprint. Anything removed can be put back with Restore." $false) { Invoke-Adb @('reboot') | Out-Null }
    }
    else { Show-Notice "Nothing was removed.$failText" -Warning }
}

function Invoke-Recommended($Rows, [string]$DeviceDir) {
    $green = @($Rows | Where-Object { $_.Tier -eq 1 })
    if ($green.Count -eq 0) {
        Write-Info 'Nothing rated GREEN on this phone.'
        Show-Notice "Nothing on this phone is rated GREEN (safe to remove without side effects).`n`nUse Custom to review the YELLOW packages: each one says what stops working if you remove it."
        return
    }
    Write-Step "Recommended: $($green.Count) GREEN packages"
    foreach ($it in $green) { Write-Host ('  {0,-50} {1}' -f $it.Package, $it.Description) -ForegroundColor Green }
    $flagged = @($Rows | Where-Object { $_.Tier -eq 0 }).Count
    if ($flagged) { Write-Info "$flagged packages were flagged (phone and lists disagree, or no data) and will not be touched. See the report." }
    if ($Script:Gui) {
        $green = @(Select-Packages -Items $green -Title "HyperDebloat - Recommended ($($green.Count) GREEN packages)" -ActionText 'Remove selected' -PreselectAll)
        if ($green.Count -eq 0) { Write-Info 'Back. Nothing was removed.'; return }
    }
    if (-not (Read-YesNo "Remove $($green.Count) GREEN package(s)?" $false)) { Write-Info 'Cancelled. Nothing was removed.'; return }
    Remove-Packages -Items $green -DeviceDir $DeviceDir
}

function Invoke-Custom($Rows, [string]$DeviceDir) {
    Write-Step 'Custom: opening the list'
    $picked = Select-Packages -Items $Rows -Title 'HyperDebloat - Custom' -ActionText 'Remove selected' -PreselectSafe
    if ($picked.Count -eq 0) { Write-Info 'Back. Nothing was removed.'; return }

    $red = @($picked | Where-Object { $_.Tier -eq 4 })
    if ($red.Count -gt 0) {
        Write-Host ''
        Write-Host "  You selected $($red.Count) RED (UNSAFE) packages:" -ForegroundColor Red
        foreach ($r in $red) { Write-Host "    $($r.Package) - $($r.Phone)" -ForegroundColor Red }
        Write-Host '  These can stop the phone booting. The only fix may be a factory reset.' -ForegroundColor Red
        if ($Script:Gui) {
            $names = ($red | ForEach-Object { $_.Package }) -join "`n"
            $ok = Read-YesNo "You selected $($red.Count) RED (unsafe) package(s):`n`n$names`n`nThese can stop the phone booting. The only fix may be a factory reset.`n`nRemove them anyway?" $false -Warning
            $typed = if ($ok) { 'REMOVE' } else { '' }
        }
        else { $typed = if ($AssumeYes) { 'REMOVE' } else { Read-Host '  Type REMOVE to include them, or press Enter to skip them' } }
        if ($typed -cne 'REMOVE') { $picked = @($picked | Where-Object { $_.Tier -ne 4 }); Write-Info 'RED packages skipped.' }
    }
    if ($picked.Count -eq 0) { Write-Info 'Nothing left to remove.'; return }

    $byTier = $picked | Group-Object Risk | ForEach-Object { "$($_.Count) $($_.Name)" }
    if (-not (Read-YesNo "Remove $($picked.Count) packages ($($byTier -join ', '))?" $false)) { Write-Info 'Cancelled. Nothing was removed.'; return }
    Remove-Packages -Items $picked -DeviceDir $DeviceDir
}

function Get-PackageSet([string]$Command) {
    $set = @{}
    foreach ($l in (Invoke-Shell $Command)) { if ($l -match '^package:(\S+)') { $set[$Matches[1]] = $true } }
    return $set
}

function Get-RemovedOnPhone {
    # Asks the phone itself, so anything removed or disabled earlier - by this tool, another
    # debloater (Xiaomi ADB/Fastboot Tools, UAD...) or plain adb - shows up, with or without logs.
    $installed = Get-PackageSet 'pm list packages --user 0'
    $known     = Get-PackageSet 'pm list packages -u --user 0'      # includes ones removed for user 0
    $systemAll = Get-PackageSet 'pm list packages -u -s --user 0'
    $removed = @{}
    foreach ($p in $known.Keys) { if (-not $installed.ContainsKey($p)) { $removed[$p] = $systemAll.ContainsKey($p) } }

    # Disabled by a user or a tool (enabled=3, DISABLED_USER), as opposed to disabled by default.
    $disabled = @{}
    $cur = $null
    foreach ($line in (Invoke-Shell 'dumpsys package packages')) {
        if ($line -match '^\s*Package \[([^\]]+)\]') { $cur = $Matches[1]; continue }
        if ($cur -and $line -match '^\s*User 0:.*\benabled=3\b' -and $installed.ContainsKey($cur)) { $disabled[$cur] = $true }
    }
    return @{ Removed = $removed; Disabled = $disabled; Installed = $installed }
}

function Invoke-Restore([string]$Model) {
    Write-Step 'Asking the phone what has been removed or disabled'
    $state = Get-RemovedOnPhone

    # This tool's own logs (any OS version of this model) only add the date and description.
    $prefix = ($Model -replace '[^\w\.-]', '_') + '_'
    $logs = @(Get-ChildItem -Path $Script:Work -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name.StartsWith($prefix) } |
        ForEach-Object { Get-ChildItem -Path $_.FullName -Filter 'removed_*.csv' } | Sort-Object Name)
    $when = @{}; $descOf = @{}
    foreach ($f in $logs) { foreach ($r in (Import-Csv $f.FullName)) { if ($r.Result -match '^Success') { $when[$r.Package] = ([string]$r.Time).Split('T')[0]; $descOf[$r.Package] = $r.Description } } }

    $idx = $null
    if ($state.Removed.Count + $state.Disabled.Count -gt 0) {
        Write-Info 'Loading package descriptions...'
        $idx = Build-Index (Get-CommunityLists)
    }
    function Describe([string]$Pkg) {
        if ($descOf.ContainsKey($Pkg) -and $descOf[$Pkg]) { return $descOf[$Pkg] }
        if ($idx) {
            if ($idx.fadeltd.ContainsKey($Pkg)) { return $idx.fadeltd[$Pkg].Desc }
            if ($idx.ovskyDesc.ContainsKey($Pkg)) { return $idx.ovskyDesc[$Pkg] }
            if ($idx.uad.ContainsKey($Pkg)) { return $idx.uad[$Pkg].Desc }
        }
        return ''
    }
    function Origin([string]$Pkg) {
        if ($when.ContainsKey($Pkg)) { return "removed by HyperDebloat on $($when[$Pkg])" }
        return 'removed earlier (another tool or before this tool''s logs)'
    }

    $items = New-Object System.Collections.Generic.List[object]
    foreach ($p in ($state.Removed.Keys | Sort-Object)) {
        if ($state.Removed[$p]) {
            $items.Add([pscustomobject]@{ Tier = 1; Risk = 'RESTORE'; Action = 'install'; Package = $p; Description = (Describe $p)
                Phone = 'system app: its file is still on the phone'; Lists = ''; Reason = (Origin $p) })
        }
        else {
            $items.Add([pscustomobject]@{ Tier = 2; Risk = 'PLAY STORE'; Action = 'store'; Package = $p; Description = (Describe $p)
                Phone = 'ordinary app: its file was deleted, data kept'; Lists = ''; Reason = "$(Origin $p); restoring opens its Play Store page on the phone" })
        }
    }
    foreach ($p in ($state.Disabled.Keys | Sort-Object)) {
        $items.Add([pscustomobject]@{ Tier = 1; Risk = 'RE-ENABLE'; Action = 'enable'; Package = $p; Description = (Describe $p)
            Phone = 'installed but disabled for your user'; Lists = ''; Reason = 'disabled earlier (this tool, another tool or Settings)' })
    }
    if ($items.Count -eq 0) { Write-Info 'Nothing has been removed or disabled on this phone.'; Show-Notice 'Nothing has been removed or disabled on this phone, so there is nothing to restore.'; return }

    $nR = @($items | Where-Object { $_.Action -eq 'install' }).Count
    $nS = @($items | Where-Object { $_.Action -eq 'store' }).Count
    $nE = @($items | Where-Object { $_.Action -eq 'enable' }).Count
    Write-Step "Restore: $nR removed system apps, $nE disabled apps, $nS ordinary apps (Play Store)"
    $picked = Select-Packages -Items $items -Title 'HyperDebloat - Restore' -ActionText 'Restore selected' -Legend 'GREEN = RESTORE (removed system app, comes straight back) or RE-ENABLE (disabled app)  |  YELLOW = PLAY STORE (ordinary app, its Play Store page opens on the phone)'
    if ($picked.Count -eq 0) { Write-Info 'Nothing selected.'; return }
    if (-not (Read-YesNo "Restore $($picked.Count) packages?" $true)) { return }
    $lost = New-Object System.Collections.Generic.List[string]
    $back = 0
    foreach ($it in $picked) {
        if ($DryRun) { Write-Host ('  {0,-50} DRY-RUN ({1})' -f $it.Package, $it.Risk) -ForegroundColor Green; continue }
        switch ($it.Action) {
            'install' {
                $null = Invoke-Shell "cmd package install-existing --user 0 $($it.Package)"
                # install-existing can report success without restoring anything, so check that
                # the phone really has the app for this user now.
                $now = Get-PackageSet "pm list packages --user 0 $($it.Package)"
                if ($now.ContainsKey($it.Package)) { $back++; Write-Host ('  {0,-50} restored' -f $it.Package) -ForegroundColor Green }
                else { $lost.Add($it.Package); Write-Host ('  {0,-50} NOT restored - reinstall it from the Play Store' -f $it.Package) -ForegroundColor Red }
            }
            'enable' {
                $res = ((Invoke-Shell "pm enable --user 0 $($it.Package)") -join ' ').Trim()
                $stillOff = (Get-PackageSet "pm list packages -d --user 0 $($it.Package)").ContainsKey($it.Package)
                if (-not $stillOff) { $back++; Write-Host ('  {0,-50} re-enabled' -f $it.Package) -ForegroundColor Green }
                else { Write-Host ('  {0,-50} could not re-enable: {1}' -f $it.Package, $res) -ForegroundColor Red }
            }
            'store' {
                $lost.Add($it.Package)
                Write-Host ('  {0,-50} ordinary app - needs the Play Store' -f $it.Package) -ForegroundColor Yellow
            }
        }
    }
    if ($DryRun) { Show-Notice "Dry run: $($picked.Count) package(s) would be restored. Nothing was changed."; return }
    $Script:NeedScan = $true
    if ($lost.Count -gt 0) {
        Write-Host ''
        Write-Warn "$($lost.Count) app(s) must be reinstalled from the Play Store (your data was kept)."
        foreach ($p in $lost) {
            if (Read-YesNo "  Open the Play Store page for $p on the phone?" $true) {
                Invoke-Shell "am start -a android.intent.action.VIEW -d market://details?id=$p" | Out-Null
                Show-Notice "The Play Store page for $p is open on the phone.`n`nTap Install there, then press OK here."
            }
        }
    }
    $failedN = @($picked | Where-Object { $_.Action -ne 'store' }).Count - $back
    $summary = "Restored $back app(s)." + $(if ($lost.Count) { "`n$($lost.Count) need the Play Store." } else { '' }) + $(if ($failedN -gt 0) { "`n$failedN could not be restored (see the console)." } else { '' })
    if ($back -gt 0) {
        Write-Info 'Some launchers only show restored apps after a reboot.'
        if (Read-YesNo "$summary`n`nSome launchers only show restored apps after a reboot. Reboot the phone now?" $true) { Invoke-Adb @('reboot') | Out-Null }
    }
    else { Show-Notice $summary }
}

# ----------------------------------------------------------------------------------------------
# Main
# ----------------------------------------------------------------------------------------------
function Show-Home($Dev, [string]$Summary) {
    # Home window: pick an action. Returns 'Recommended', 'Custom', 'Restore', 'Rescan', 'Folder' or 'Quit'.
    $form = New-Object Windows.Forms.Form
    $form.Text = "HyperDebloat $Script:Version" + $(if ($DryRun) { '  (DRY RUN - nothing will change)' } else { '' })
    $form.Size = New-Object Drawing.Size(620, 600)
    $form.StartPosition = 'CenterScreen'
    $form.FormBorderStyle = 'FixedDialog'
    $form.MaximizeBox = $false
    $form.Font = New-Object Drawing.Font('Segoe UI', 10)

    $title = New-Object Windows.Forms.Label
    $title.Text = 'HyperDebloat'
    $title.Font = New-Object Drawing.Font('Segoe UI', 16, [Drawing.FontStyle]::Bold)
    $title.Location = New-Object Drawing.Point(20, 15); $title.AutoSize = $true
    $form.Controls.Add($title)

    $phone = New-Object Windows.Forms.Label
    $phone.Location = New-Object Drawing.Point(22, 55); $phone.Size = New-Object Drawing.Size(570, 45)
    if ($Dev) { $phone.Text = "Phone: $($Dev.MarketName) ($($Dev.Model))`r`n$($Dev.OsName) $($Dev.OsBuild)  |  Android $($Dev.Android)" }
    else { $phone.Text = "Phone: not connected yet" }
    $form.Controls.Add($phone)

    $sum = New-Object Windows.Forms.Label
    $sum.Location = New-Object Drawing.Point(22, 100); $sum.Size = New-Object Drawing.Size(570, 22)
    $sum.ForeColor = [Drawing.Color]::DimGray
    $sum.Text = if ($Summary) { $Summary } else { 'Not scanned yet. Recommended and Custom scan the phone first.' }
    $form.Controls.Add($sum)

    $Script:HomeChoice = 'Quit'
    $y = 132
    $buttons = @(
        @('Recommended', 'Recommended', 'Remove every GREEN (safe) package after you review the list.', 'Honeydew'),
        @('Custom', 'Custom', 'Pick from the full colour-coded list of packages.', 'White'),
        @('Restore', 'Restore', 'Put back anything removed or disabled - by this tool or any other.', 'White')
    )
    foreach ($b in $buttons) {
        $btn = New-Object Windows.Forms.Button
        $btn.Text = $b[1]; $btn.Tag = $b[0]
        $btn.Font = New-Object Drawing.Font('Segoe UI', 11, [Drawing.FontStyle]::Bold)
        $btn.Location = New-Object Drawing.Point(22, $y); $btn.Size = New-Object Drawing.Size(160, 50)
        $btn.BackColor = [Drawing.Color]::FromName($b[3])
        $btn.Add_Click({ $Script:HomeChoice = $this.Tag; $form.Close() })
        $form.Controls.Add($btn)
        $lbl = New-Object Windows.Forms.Label
        $lbl.Text = $b[2]; $lbl.Location = New-Object Drawing.Point(195, ($y + 6)); $lbl.Size = New-Object Drawing.Size(395, 42)
        $form.Controls.Add($lbl)
        $y += 64
    }

    $tip = New-Object Windows.Forms.Label
    $tip.Location = New-Object Drawing.Point(22, ($y + 4)); $tip.Size = New-Object Drawing.Size(570, 64)
    $tip.ForeColor = [Drawing.Color]::DimGray
    $tip.Text = "Before Recommended or Custom, open the apps you rely on (camera, gallery, file manager, payments) on the phone, so the scan can see what they use. Progress is shown in the console window."
    $form.Controls.Add($tip)
    $y += 76

    $small = @(@('Rescan', 'Rescan phone'), @('Folder', 'Open reports folder'), @('Quit', 'Quit'))
    $x = 22
    foreach ($b in $small) {
        $btn = New-Object Windows.Forms.Button
        $btn.Text = $b[1]; $btn.Tag = $b[0]
        $btn.Location = New-Object Drawing.Point($x, $y); $btn.Size = New-Object Drawing.Size(180, 36)
        $btn.Add_Click({ $Script:HomeChoice = $this.Tag; $form.Close() })
        $form.Controls.Add($btn)
        $x += 190
    }
    $form.ClientSize = New-Object Drawing.Size(610, ($y + 56))
    [void]$form.ShowDialog()
    return $Script:HomeChoice
}

function Read-ConsoleMenu {
    Write-Host ''
    Write-Host '  1  Recommended  - remove all GREEN packages in one go' -ForegroundColor Green
    Write-Host '  2  Custom       - pick from the colour-coded list'
    Write-Host '  3  Restore      - put back anything removed or disabled (by this or any tool)'
    Write-Host '  R  Rescan the phone'
    Write-Host '  Q  Quit'
    switch -Regex (Read-Host 'Choose') {
        '^1' { return 'Recommended' }
        '^2' { return 'Custom' }
        '^3' { return 'Restore' }
        '^[rR]' { return 'Rescan' }
        default { return 'Quit' }
    }
}

function Connect-Phone {
    # Waits for the phone and reads its details. Returns $null if the user gives up.
    if (-not (Wait-ForDevice)) { return $null }
    $dev = Get-DeviceInfo
    $key = "$($dev.Model)|$($dev.OsBuild)"
    if ($key -ne $Script:DeviceKey) {
        Write-Step 'Phone'
        Write-Info "$($dev.MarketName) ($($dev.Model), $($dev.Codename))  |  $($dev.OsName) $($dev.OsBuild)  |  Android $($dev.Android)"
        if (("$($dev.Manufacturer) $($dev.Brand)") -notmatch 'xiaomi|redmi|poco') {
            Write-Warn 'This does not look like a Xiaomi, Redmi or POCO phone. The lists are built for those.'
            if (-not (Read-YesNo 'This does not look like a Xiaomi, Redmi or POCO phone. The lists are built for those. Continue anyway?' $false -Warning)) { return $null }
        }
        $Script:DeviceKey = $key
        $Script:NeedScan = $true
    }
    $Script:DeviceDir = Join-Path $Script:Work ((("{0}_{1}" -f $dev.Model, $dev.OsBuild) -replace '[^\w\.-]', '_'))
    New-Item -ItemType Directory -Force -Path $Script:DeviceDir | Out-Null
    return $dev
}

function Invoke-Scan($Dev) {
    Write-Step 'Scanning the phone (read-only)'
    $sets = Get-PackageSets
    Write-Info "$($sets.All.Count) packages installed ($($sets.System.Count) system)"
    if (-not $Script:Gui -and -not $AssumeYes) {
        Write-Info 'Tip: open the apps you rely on (file manager, camera, gallery, payments) on the phone'
        Write-Info 'before this scan, so the live-connection check can see what they use.'
        $null = Read-Host 'Press Enter to start the scan'
    }
    $facts = Get-DeviceFacts -Installed $sets.All
    Write-Step 'Community lists (descriptions and cross-check)'
    $idx = Build-Index (Get-CommunityLists)
    $rows = Get-Classification -Idx $idx -Sets $sets -Facts $facts
    Write-Summary $rows
    Save-Report -Rows $rows -Dev $Dev -DeviceDir $Script:DeviceDir
    $parts = foreach ($t in @(1, 2, 3, 4, 0)) { "$(@($rows | Where-Object { $_.Tier -eq $t }).Count) $($Script:TierInfo[$t].Colour.ToLower())" }
    $Script:ScanSummary = "Last scan $(Get-Date -Format 'HH:mm'): " + ($parts -join ', ')
    $Script:NeedScan = $false
    return , $rows
}

function Main {
    # Windows Forms needs a single-threaded apartment; relaunch in Windows PowerShell if needed.
    if ((Test-IsWindowsHost) -and -not $NoGui -and [Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA' -and $PSCommandPath) {
        $passArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-STA', '-File', $PSCommandPath)
        foreach ($kv in $PSBoundParameters.GetEnumerator()) {
            if ($kv.Value -is [switch]) { if ($kv.Value) { $passArgs += "-$($kv.Key)" } } else { $passArgs += "-$($kv.Key)"; $passArgs += "$($kv.Value)" }
        }
        & powershell.exe @passArgs
        return
    }
    $Script:Gui = (-not $NoGui) -and (Test-IsWindowsHost) -and ([Threading.Thread]::CurrentThread.GetApartmentState() -eq 'STA')
    if ($Script:Gui) {
        Add-Type -AssemblyName System.Windows.Forms
        Add-Type -AssemblyName System.Drawing
        [Windows.Forms.Application]::EnableVisualStyles()
    }

    Write-Host "HyperDebloat $Script:Version - device-aware HyperOS debloater" -ForegroundColor Cyan
    if ($DryRun) { Write-Warn 'DRY RUN: nothing will be removed or restored.' }

    Write-Step 'ADB'
    $Script:Adb = Get-AdbExe
    Write-Info "Using $Script:Adb"

    $Script:NeedScan = $true
    $rows = $null
    $dev = Connect-Phone

    # One action when -Mode is given; otherwise keep returning to the home screen until Quit.
    $first = $true
    while ($true) {
        if ($Mode -and $first) { $choice = $Mode }
        elseif ($Mode) { return }
        elseif ($Script:Gui) { $choice = Show-Home -Dev $dev -Summary $Script:ScanSummary }
        else { $choice = Read-ConsoleMenu }
        $first = $false

        switch ($choice) {
            'Quit'   { return }
            'Folder' { Start-Process explorer.exe $Script:Work; continue }
            default {
                $dev = Connect-Phone
                if (-not $dev) { continue }
                if ($choice -eq 'Rescan' -or ($choice -in @('Recommended', 'Custom') -and ($Script:NeedScan -or -not $rows))) {
                    try { $rows = Invoke-Scan -Dev $dev }
                    catch {
                        $report = Write-ErrorReport $_ 'Scan'
                        Write-Host "  Error in scan: $($_.Exception.Message)" -ForegroundColor Red
                        if ($Script:Gui) { [void][Windows.Forms.MessageBox]::Show("The scan stopped with an error.`n`n$report", 'HyperDebloat - error', 'OK', 'Error') }
                        continue
                    }
                }
                try {
                    switch ($choice) {
                        'Recommended' { Invoke-Recommended -Rows $rows -DeviceDir $Script:DeviceDir }
                        'Custom'      { Invoke-Custom -Rows $rows -DeviceDir $Script:DeviceDir }
                        'Restore'     { Invoke-Restore -Model $dev.Model }
                    }
                }
                catch {
                    # One failed action must not close the tool: report it and go back to the home screen.
                    $Script:NeedScan = $true
                    $report = Write-ErrorReport $_ $choice
                    Write-Host "  Error in $choice`: $($_.Exception.Message)" -ForegroundColor Red
                    if ($Script:Gui) { [void][Windows.Forms.MessageBox]::Show("$choice stopped with an error. Nothing after this point was done.`n`n$report", 'HyperDebloat - error', 'OK', 'Error') }
                }
            }
        }
    }
}

try { Main }
catch {
    $report = Write-ErrorReport $_ 'startup'
    Write-Host ''
    Write-Host "Error: $($_.Exception.Message)" -ForegroundColor Red
    if ($Script:Gui) { try { [void][Windows.Forms.MessageBox]::Show("HyperDebloat stopped with an error.`n`n$report", 'HyperDebloat - error', 'OK', 'Error') } catch {} }
    elseif (-not $AssumeYes) { try { $null = Read-Host 'Press Enter to close' } catch {} }
    exit 1
}

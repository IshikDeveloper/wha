<#
.SYNOPSIS
Live/online adaptation of ntdevlabs' tiny11builder debloat steps.

.DESCRIPTION
tiny11builder (https://github.com/ntdevlabs/tiny11builder) works by mounting an OFFLINE
install.wim and stripping bloat before deployment. This script instead applies the SAME
set of removals/tweaks to your CURRENTLY RUNNING Windows install - which is what you want
when your workflow is:
    1. Fresh install -> fully patch via Windows Update
    2. Run THIS script to debloat live (this file)
    3. Delete throwaway account
    4. Sysprep /generalize /oobe /shutdown
    5. Boot WinPE, dism /capture-image the drive into a fresh install.wim
    6. Pack that wim into a new ISO

Run this AFTER Windows Update is fully finished and BEFORE you delete the throwaway
account and sysprep. Run it as Administrator.

.NOTES
Source reference: ntdevlabs/tiny11builder tiny11maker.ps1 (release 09-07-25)
This is not the tiny11 project's own code - it is a rewrite of its DISM/registry actions
targeting an online system (/Online instead of /Image:<mount>, HKLM/HKCU directly instead
of loading offline hives under z-prefixed keys).
#>

#Requires -RunAsAdministrator

$ErrorActionPreference = 'Continue'
Start-Transcript -Path "$PSScriptRoot\live-debloat_$(Get-Date -f yyyyMMdd_HHmms).log"

function Set-Reg {
    param([string]$Path, [string]$Name, [string]$Type, [string]$Value)
    try {
        & reg add $Path /v $Name /t $Type /d $Value /f | Out-Null
        Write-Output "Set: $Path\$Name = $Value"
    } catch {
        Write-Output "Failed to set $Path\$Name : $_"
    }
}

function Remove-RegKey {
    param([string]$Path)
    try {
        & reg delete $Path /f | Out-Null
        Write-Output "Removed key: $Path"
    } catch {
        Write-Output "Failed to remove $Path : $_"
    }
}

Write-Output "=== tiny11-style LIVE debloat starting ==="
Write-Output "Target: currently running online OS (not an offline WIM)"
Write-Output ""

# -------------------------------------------------------------------------
# 1. Remove provisioned Appx packages (same prefix list as tiny11maker.ps1)
#    Online equivalent: /Online instead of /Image:<mount path>
# -------------------------------------------------------------------------
Write-Output ">>> Removing provisioned Appx packages..."

$packagePrefixes = @(
    'AppUp.IntelManagementandSecurityStatus',
    'Clipchamp.Clipchamp',
    'DolbyLaboratories.DolbyAccess',
    'DolbyLaboratories.DolbyDigitalPlusDecoderOEM',
    'Microsoft.BingNews',
    'Microsoft.BingSearch',
    'Microsoft.BingWeather',
    'Microsoft.Copilot',
    'Microsoft.Windows.CrossDevice',
    'Microsoft.GamingApp',
    'Microsoft.GetHelp',
    'Microsoft.Getstarted',
    'Microsoft.Microsoft3DViewer',
    'Microsoft.MicrosoftOfficeHub',
    'Microsoft.MicrosoftSolitaireCollection',
    'Microsoft.MicrosoftStickyNotes',
    'Microsoft.MixedReality.Portal',
    'Microsoft.MSPaint',
    'Microsoft.Office.OneNote',
    'Microsoft.OfficePushNotificationUtility',
    'Microsoft.OutlookForWindows',
    'Microsoft.Paint',
    'Microsoft.People',
    'Microsoft.PowerAutomateDesktop',
    'Microsoft.SkypeApp',
    'Microsoft.StartExperiencesApp',
    'Microsoft.Todos',
    'Microsoft.Wallet',
    'Microsoft.Windows.DevHome',
    'Microsoft.Windows.Copilot',
    'Microsoft.Windows.Teams',
    'Microsoft.WindowsAlarms',
    'Microsoft.WindowsCamera',
    'microsoft.windowscommunicationsapps',
    'Microsoft.WindowsFeedbackHub',
    'Microsoft.WindowsMaps',
    'Microsoft.WindowsSoundRecorder',
    'Microsoft.WindowsTerminal',
    'Microsoft.Xbox.TCUI',
    'Microsoft.XboxApp',
    'Microsoft.XboxGameOverlay',
    'Microsoft.XboxGamingOverlay',
    'Microsoft.XboxIdentityProvider',
    'Microsoft.XboxSpeechToTextOverlay',
    'Microsoft.YourPhone',
    'Microsoft.ZuneMusic',
    'Microsoft.ZuneVideo',
    'MicrosoftCorporationII.MicrosoftFamily',
    'MicrosoftCorporationII.QuickAssist',
    'MSTeams',
    'MicrosoftTeams',
    'Microsoft.549981C3F5F10'
)

# Get-AppxProvisionedPackage is the online (live-system) equivalent of
# dism /image:<mount> /Get-ProvisionedAppxPackages
$packages = Get-AppxProvisionedPackage -Online | Select-Object -ExpandProperty PackageName

$packagesToRemove = $packages | Where-Object {
    $pkg = $_
    $packagePrefixes | Where-Object { $pkg -like "*$_*" }
}

foreach ($package in $packagesToRemove) {
    Write-Output "Removing provisioned package: $package"
    Remove-AppxProvisionedPackage -Online -PackageName $package -ErrorAction SilentlyContinue | Out-Null
}

# Also remove for the CURRENT user profile (tiny11 only strips provisioning,
# since it's working offline pre-first-login; live system also needs this
# so the throwaway account's Start Menu doesn't show them before you delete it)
Write-Output ">>> Removing installed Appx packages for current user..."
$installedPackages = Get-AppxPackage | Select-Object -ExpandProperty Name
$installedToRemove = $installedPackages | Where-Object {
    $pkg = $_
    $packagePrefixes | Where-Object { $pkg -like "*$_*" }
}
foreach ($package in $installedToRemove) {
    Write-Output "Removing installed package: $package"
    Get-AppxPackage -Name $package | Remove-AppxPackage -ErrorAction SilentlyContinue
}

Write-Output ""

# -------------------------------------------------------------------------
# 2. Remove Edge (live system paths - service must be stopped first)
# -------------------------------------------------------------------------
Write-Output ">>> Removing Edge..."

# Kill Edge/EdgeUpdate processes so files aren't locked
Get-Process msedge, MicrosoftEdgeUpdate -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue

# Stop the Edge update service (edgeupdate) if running
Stop-Service edgeupdate -Force -ErrorAction SilentlyContinue
Stop-Service edgeupdatem -Force -ErrorAction SilentlyContinue

$edgePaths = @(
    "$env:ProgramFiles(x86)\Microsoft\Edge",
    "$env:ProgramFiles(x86)\Microsoft\EdgeUpdate",
    "$env:ProgramFiles(x86)\Microsoft\EdgeCore",
    "$env:SystemRoot\System32\Microsoft-Edge-Webview"
)

foreach ($path in $edgePaths) {
    if (Test-Path $path) {
        & takeown /F $path /R /D Y | Out-Null
        & icacls $path /grant "*S-1-5-32-544:(OI)(CI)F" /T /C | Out-Null
        Remove-Item -Path $path -Recurse -Force -ErrorAction SilentlyContinue
        Write-Output "Removed: $path"
    } else {
        Write-Output "Not found (already absent): $path"
    }
}

Write-Output ""

# -------------------------------------------------------------------------
# 3. Remove OneDrive (live system - must uninstall running instance first)
# -------------------------------------------------------------------------
Write-Output ">>> Removing OneDrive..."

# Uninstall the running OneDrive instance properly first (live-system step
# tiny11 doesn't need since it works on an offline pre-first-run image)
Get-Process OneDrive -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
$oneDriveSetup = "$env:SystemRoot\SysWOW64\OneDriveSetup.exe"
if (-not (Test-Path $oneDriveSetup)) { $oneDriveSetup = "$env:SystemRoot\System32\OneDriveSetup.exe" }
if (Test-Path $oneDriveSetup) {
    Start-Process $oneDriveSetup -ArgumentList "/uninstall" -Wait -ErrorAction SilentlyContinue
}

$oneDriveExe = "$env:SystemRoot\System32\OneDriveSetup.exe"
if (Test-Path $oneDriveExe) {
    & takeown /F $oneDriveExe | Out-Null
    & icacls $oneDriveExe /grant "*S-1-5-32-544:(F)" | Out-Null
    Remove-Item -Path $oneDriveExe -Force -ErrorAction SilentlyContinue
    Write-Output "Removed: $oneDriveExe"
}

Write-Output ""

# -------------------------------------------------------------------------
# 4. Registry tweaks - LIVE equivalents.
#    tiny11 loads offline hives as zCOMPONENTS/zDEFAULT/zNTUSER/zSOFTWARE/zSYSTEM.
#    On a live system these map directly to:
#       zDEFAULT/zNTUSER -> HKCU (current interactive user's hive is already loaded)
#       zSOFTWARE         -> HKLM\SOFTWARE
#       zSYSTEM           -> HKLM\SYSTEM
#    NOTE: skipping the CPU/RAM/TPM/SecureBoot bypass keys here - you already
#    installed successfully, so LabConfig/MoSetup bypasses are not relevant
#    to a live already-running system the way they are to an offline setup image.
# -------------------------------------------------------------------------
Write-Output ">>> Disabling Sponsored Apps / suggestions..."
Set-Reg 'HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'OemPreInstalledAppsEnabled' 'REG_DWORD' '0'
Set-Reg 'HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'PreInstalledAppsEnabled' 'REG_DWORD' '0'
Set-Reg 'HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'SilentInstalledAppsEnabled' 'REG_DWORD' '0'
Set-Reg 'HKLM\SOFTWARE\Policies\Microsoft\Windows\CloudContent' 'DisableWindowsConsumerFeatures' 'REG_DWORD' '1'
Set-Reg 'HKCU\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'ContentDeliveryAllowed' 'REG_DWORD' '0'
Set-Reg 'HKLM\SOFTWARE\Microsoft\PolicyManager\current\device\Start' 'ConfigureStartPins' 'REG_SZ' '{"pinnedList": [{}]}'
Set-Reg 'HKCU\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'FeatureManagementEnabled' 'REG_DWORD' '0'
Set-Reg 'HKCU\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'PreInstalledAppsEverEnabled' 'REG_DWORD' '0'
Set-Reg 'HKCU\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'SoftLandingEnabled' 'REG_DWORD' '0'
Set-Reg 'HKCU\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'SubscribedContentEnabled' 'REG_DWORD' '0'
Set-Reg 'HKCU\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'SubscribedContent-310093Enabled' 'REG_DWORD' '0'
Set-Reg 'HKCU\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'SubscribedContent-338388Enabled' 'REG_DWORD' '0'
Set-Reg 'HKCU\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'SubscribedContent-338389Enabled' 'REG_DWORD' '0'
Set-Reg 'HKCU\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'SubscribedContent-338393Enabled' 'REG_DWORD' '0'
Set-Reg 'HKCU\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'SubscribedContent-353694Enabled' 'REG_DWORD' '0'
Set-Reg 'HKCU\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'SubscribedContent-353696Enabled' 'REG_DWORD' '0'
Set-Reg 'HKCU\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'SystemPaneSuggestionsEnabled' 'REG_DWORD' '0'
Set-Reg 'HKLM\SOFTWARE\Policies\Microsoft\PushToInstall' 'DisablePushToInstall' 'REG_DWORD' '1'
Set-Reg 'HKLM\SOFTWARE\Policies\Microsoft\MRT' 'DontOfferThroughWUAU' 'REG_DWORD' '1'
Remove-RegKey 'HKCU\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager\Subscriptions'
Remove-RegKey 'HKCU\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager\SuggestedApps'
Set-Reg 'HKLM\SOFTWARE\Policies\Microsoft\Windows\CloudContent' 'DisableConsumerAccountStateContent' 'REG_DWORD' '1'
Set-Reg 'HKLM\SOFTWARE\Policies\Microsoft\Windows\CloudContent' 'DisableCloudOptimizedContent' 'REG_DWORD' '1'

Write-Output ">>> Enabling local accounts on OOBE (BypassNRO)..."
Set-Reg 'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\OOBE' 'BypassNRO' 'REG_DWORD' '1'

Write-Output ">>> Disabling Reserved Storage..."
Set-Reg 'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\ReserveManager' 'ShippedWithReserves' 'REG_DWORD' '0'

Write-Output ">>> Disabling BitLocker Device Encryption..."
Set-Reg 'HKLM\SYSTEM\ControlSet001\Control\BitLocker' 'PreventDeviceEncryption' 'REG_DWORD' '1'

Write-Output ">>> Disabling Chat icon..."
Set-Reg 'HKLM\SOFTWARE\Policies\Microsoft\Windows\Windows Chat' 'ChatIcon' 'REG_DWORD' '3'
Set-Reg 'HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'TaskbarMn' 'REG_DWORD' '0'

Write-Output ">>> Removing Edge-related uninstall registry entries..."
Remove-RegKey "HKLM\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\Microsoft Edge"
Remove-RegKey "HKLM\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\Microsoft Edge Update"

Write-Output ">>> Disabling OneDrive folder backup..."
Set-Reg "HKLM\SOFTWARE\Policies\Microsoft\Windows\OneDrive" "DisableFileSyncNGSC" "REG_DWORD" "1"

Write-Output ">>> Disabling Telemetry..."
Set-Reg 'HKCU\Software\Microsoft\Windows\CurrentVersion\AdvertisingInfo' 'Enabled' 'REG_DWORD' '0'
Set-Reg 'HKCU\Software\Microsoft\Windows\CurrentVersion\Privacy' 'TailoredExperiencesWithDiagnosticDataEnabled' 'REG_DWORD' '0'
Set-Reg 'HKCU\Software\Microsoft\Speech_OneCore\Settings\OnlineSpeechPrivacy' 'HasAccepted' 'REG_DWORD' '0'
Set-Reg 'HKCU\Software\Microsoft\Input\TIPC' 'Enabled' 'REG_DWORD' '0'
Set-Reg 'HKCU\Software\Microsoft\InputPersonalization' 'RestrictImplicitInkCollection' 'REG_DWORD' '1'
Set-Reg 'HKCU\Software\Microsoft\InputPersonalization' 'RestrictImplicitTextCollection' 'REG_DWORD' '1'
Set-Reg 'HKCU\Software\Microsoft\InputPersonalization\TrainedDataStore' 'HarvestContacts' 'REG_DWORD' '0'
Set-Reg 'HKCU\Software\Microsoft\Personalization\Settings' 'AcceptedPrivacyPolicy' 'REG_DWORD' '0'
Set-Reg 'HKLM\SOFTWARE\Policies\Microsoft\Windows\DataCollection' 'AllowTelemetry' 'REG_DWORD' '0'
Set-Reg 'HKLM\SYSTEM\ControlSet001\Services\dmwappushservice' 'Start' 'REG_DWORD' '4'

Write-Output ">>> Preventing installation of DevHome and Outlook..."
Set-Reg 'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Orchestrator\UScheduler_Oobe\OutlookUpdate' 'workCompleted' 'REG_DWORD' '1'
Set-Reg 'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Orchestrator\UScheduler\OutlookUpdate' 'workCompleted' 'REG_DWORD' '1'
Set-Reg 'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Orchestrator\UScheduler\DevHomeUpdate' 'workCompleted' 'REG_DWORD' '1'
Remove-RegKey 'HKLM\SOFTWARE\Microsoft\WindowsUpdate\Orchestrator\UScheduler_Oobe\OutlookUpdate'
Remove-RegKey 'HKLM\SOFTWARE\Microsoft\WindowsUpdate\Orchestrator\UScheduler_Oobe\DevHomeUpdate'

Write-Output ">>> Disabling Copilot..."
Set-Reg 'HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsCopilot' 'TurnOffWindowsCopilot' 'REG_DWORD' '1'
Set-Reg 'HKLM\SOFTWARE\Policies\Microsoft\Edge' 'HubsSidebarEnabled' 'REG_DWORD' '0'
Set-Reg 'HKLM\SOFTWARE\Policies\Microsoft\Windows\Explorer' 'DisableSearchBoxSuggestions' 'REG_DWORD' '1'

Write-Output ">>> Preventing installation of Teams..."
Set-Reg 'HKLM\SOFTWARE\Policies\Microsoft\Teams' 'DisableInstallation' 'REG_DWORD' '1'

Write-Output ">>> Preventing installation of New Outlook..."
Set-Reg 'HKLM\SOFTWARE\Policies\Microsoft\Windows\Windows Mail' 'PreventRun' 'REG_DWORD' '1'

Write-Output ""

# -------------------------------------------------------------------------
# 5. Scheduled tasks - identical to tiny11 (same task paths exist live)
# -------------------------------------------------------------------------
Write-Output ">>> Disabling/removing scheduled tasks..."

$tasksToRemove = @(
    '\Microsoft\Windows\Application Experience\Microsoft Compatibility Appraiser',
    '\Microsoft\Windows\Application Experience\ProgramDataUpdater',
    '\Microsoft\Windows\Chkdsk\Proxy',
    '\Microsoft\Windows\Windows Error Reporting\QueueReporting'
)
foreach ($task in $tasksToRemove) {
    schtasks /Delete /TN $task /F 2>$null | Out-Null
    Write-Output "Removed task (if present): $task"
}
# CEIP is a whole folder of tasks in tiny11 (Remove-Item -Recurse on the folder)
schtasks /Delete /TN "\Microsoft\Windows\Customer Experience Improvement Program" /F 2>$null | Out-Null
Get-ScheduledTask -TaskPath "\Microsoft\Windows\Customer Experience Improvement Program\" -ErrorAction SilentlyContinue |
    ForEach-Object { Unregister-ScheduledTask -TaskName $_.TaskName -TaskPath $_.TaskPath -Confirm:$false -ErrorAction SilentlyContinue }

Write-Output ""

# -------------------------------------------------------------------------
# 6. Component store cleanup - THIS is the key one for a live post-update
#    system, since you just installed a bunch of cumulative updates.
#    Online equivalent of: dism /Image:<mount> /Cleanup-Image /StartComponentCleanup /ResetBase
# -------------------------------------------------------------------------
Write-Output ">>> Cleaning up WinSxS component store (this can take a while)..."
dism.exe /Online /Cleanup-Image /StartComponentCleanup /ResetBase

Write-Output ""
Write-Output "=== Live debloat complete ==="
Write-Output "Next steps in your workflow:"
Write-Output "  1. Reboot once to let everything settle, confirm Windows Update still shows clean"
Write-Output "  2. Delete the throwaway account (from a different admin session, e.g. built-in Administrator)"
Write-Output "  3. cd C:\Windows\System32\Sysprep"
Write-Output "     sysprep /generalize /oobe /shutdown"
Write-Output "  4. Boot WinPE (from your install media) and capture:"
Write-Output "     dism /Capture-Image /ImageFile:D:\install.wim /CaptureDir:C:\ /Name:""Windows 11 Custom"""
Write-Output "  5. Bring that install.wim back to your Linux box and rebuild the ISO"

Stop-Transcript

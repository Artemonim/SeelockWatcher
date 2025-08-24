#requires -Version 5.1

[CmdletBinding(SupportsShouldProcess)]
param(
    # ! Password for the Seelock device (secure).
    [Parameter(Mandatory = $false)]
    [System.Security.SecureString]$Password = (ConvertTo-SecureString '000000' -AsPlainText -Force),

    # ! The root folder where converted videos will be stored.
    [string]$OutputRoot = "$PSScriptRoot\Videos",

    # ! If specified, the original video files will not be deleted after conversion.
    [switch]$Preserve,

    # ! Keep the console open after completion (press Enter to close).
    [switch]$PauseAtEnd
)

# Import localized strings
. "$PSScriptRoot\scripts\Strings.ps1"

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# * Finds a suitable PowerShell executable (pwsh preferred, fallback to powershell.exe)
function Get-PowerShellExecutable {
    try {
        $cmd = Get-Command -Name 'pwsh' -ErrorAction SilentlyContinue
        if ($cmd -and (Test-Path -LiteralPath $cmd.Source)) { return $cmd.Source }
    } catch { }
    return 'powershell.exe'
}

# * Invokes a child script in a separate PowerShell process and captures output and exit code
function Invoke-ExternalScript {
    param(
        [Parameter(Mandatory = $true)] [string]$ScriptPath,
        [string[]]$Arguments = @(),
        [switch]$RedirectOutput
    )
    if (-not (Test-Path -LiteralPath $ScriptPath)) {
        throw ("Child script not found: {0}" -f $ScriptPath)
    }
    $exe = Get-PowerShellExecutable
    $baseArgs = @('-NoProfile','-ExecutionPolicy','Bypass','-File', $ScriptPath)
    $psiArgs = $baseArgs + $Arguments
    if ($RedirectOutput) {
        $stdoutFile = [System.IO.Path]::GetTempFileName()
        $stderrFile = [System.IO.Path]::GetTempFileName()
        try {
            $proc = Start-Process -FilePath $exe -ArgumentList $psiArgs -NoNewWindow -PassThru -Wait -RedirectStandardOutput $stdoutFile -RedirectStandardError $stderrFile
            $outText = ''
            $errText = ''
            if (Test-Path -LiteralPath $stdoutFile) { $outText = Get-Content -LiteralPath $stdoutFile -Raw }
            if (Test-Path -LiteralPath $stderrFile) { $errText = Get-Content -LiteralPath $stderrFile -Raw }
            return @{ ExitCode = $proc.ExitCode; StdOut = $outText; StdErr = $errText; CombinedOutput = ($outText + "`n" + $errText).Trim() }
        } finally {
            try { Remove-Item -LiteralPath $stdoutFile -ErrorAction SilentlyContinue } catch { }
            try { Remove-Item -LiteralPath $stderrFile -ErrorAction SilentlyContinue } catch { }
        }
    } else {
        $proc = Start-Process -FilePath $exe -ArgumentList $psiArgs -NoNewWindow -PassThru -Wait
        return @{ ExitCode = $proc.ExitCode; StdOut = ''; StdErr = ''; CombinedOutput = '' }
    }
}

# * Converts SecureString to plain text and zeroes unmanaged memory
function Convert-SecureStringToPlainText {
    param([System.Security.SecureString]$Sec)
    if (-not $Sec) { return '' }
    $ptr = [IntPtr]::Zero
    try {
        $ptr = [System.Runtime.InteropServices.Marshal]::SecureStringToGlobalAllocUnicode($Sec)
        return [System.Runtime.InteropServices.Marshal]::PtrToStringUni($ptr)
    } finally {
        if ($ptr -ne [IntPtr]::Zero) {
            [System.Runtime.InteropServices.Marshal]::ZeroFreeGlobalAllocUnicode($ptr)
        }
    }
}

try {
    # --- Step 1: Detect existing mount or connect to the device ---
    $existingDrive = $null
    try {
        $fsDrives = (Get-PSDrive -PSProvider FileSystem | Where-Object { $_.Root -match '^[A-Z]:\\$' }).Name | ForEach-Object { "{0}:" -f $_ }
        foreach ($d in $fsDrives) {
            if (Test-Path -LiteralPath (Join-Path -Path $d -ChildPath 'DCIM')) { $existingDrive = $d; break }
        }
    } catch { }

    if ($existingDrive) {
        $driveLetter = $existingDrive
        Write-Host ($Strings.Sync_MountSuccess -f $driveLetter)
    } else {
        Write-Host $Strings.Sync_Connecting
        $connectScriptPath = Join-Path -Path $PSScriptRoot -ChildPath 'scripts\Connect-Seelock.ps1'
        
        # The script outputs "DriveReady=X:" on success. We capture both stdout and stderr.
        $connectArgs = @('-VerboseLog:$false', '-CloseApp')
        if ($PSBoundParameters.ContainsKey('Password')) {
            $plainPwd = Convert-SecureStringToPlainText -Sec $Password
            $connectArgs = @('-Password', $plainPwd) + $connectArgs
        }
        $connectInvoke = Invoke-ExternalScript -ScriptPath $connectScriptPath -Arguments $connectArgs -RedirectOutput
        if ($connectInvoke.ExitCode -ne 0) {
            throw ($Strings.Sync_ConnectionFailed -f $connectInvoke.CombinedOutput)
        }

        $driveMatch = $connectInvoke.CombinedOutput | Select-String -Pattern 'DriveReady=([A-Z]:)'
        if (-not $driveMatch) {
            throw ($Strings.Sync_CannotGetDrive -f $connectInvoke.CombinedOutput)
        }
        $driveLetter = $driveMatch.Matches[0].Groups[1].Value
        Write-Host ($Strings.Sync_MountSuccess -f $driveLetter)
    }


    # --- Step 2: Convert videos ---
    $convertScriptPath = Join-Path -Path $PSScriptRoot -ChildPath 'scripts\Convert-SeelockVideos.ps1'

    Write-Host ($Strings.Sync_ConversionStarting -f $driveLetter, $OutputRoot)
    $convArgs = @('-InputDrive', $driveLetter, '-OutputDirectory', $OutputRoot)
    if ($Preserve.IsPresent) { $convArgs += '-Preserve' }
    $convInvoke = Invoke-ExternalScript -ScriptPath $convertScriptPath -Arguments $convArgs
    if ($convInvoke.ExitCode -ne 0) { throw $Strings.Sync_ConversionFailed }

    Write-Host $Strings.Sync_CompleteSuccess

} catch {
    Write-Error ($Strings.Sync_OverallFailure -f $_)
    exit 1
} finally {
    if (-not $PSBoundParameters.ContainsKey('PauseAtEnd')) { $PauseAtEnd = $true }
    if ($PauseAtEnd) {
        try { Read-Host 'Press Enter to close' | Out-Null } catch { Start-Sleep -Seconds 3 }
    }
}

#requires -Version 5.1

[CmdletBinding()]
param(
    # ! The root drive of the Seelock device (e.g., "G:")
    [Parameter(Mandatory = $true)]
    [string]$InputDrive,

    # ! The root directory where converted videos will be stored
    [string]$OutputDirectory,

    # ! If specified, the original video files will not be deleted after conversion.
    [switch]$Preserve
)

#region Configuration Loading
. "$PSScriptRoot\Strings.ps1"
$ConfigPath = Join-Path -Path $PSScriptRoot -ChildPath '..\Config.ini'
$Config = @{}
if (Test-Path -LiteralPath $ConfigPath) {
    try {
        Get-Content -LiteralPath $ConfigPath | ForEach-Object {
            if ($_ -match '^\s*([^#;].*?)\s*=\s*(.*)') {
                $key = $Matches[1].Trim()
                $value = $Matches[2].Trim()
                $Config[$key] = $value
            }
        }
    } catch {
        Write-Warning ("Failed to read or parse Config.ini: {0}" -f $_.Exception.Message)
    }
}
#endregion

#region Parameter Resolution
# * Precedence: Command-line > Config.ini > Hardcoded Default
if (-not $PSBoundParameters.ContainsKey('OutputDirectory')) {
    $OutputDirectory = if ($Config.ContainsKey('OutputPath')) { $Config.OutputPath } else { './Videos' }
}

# * Determine if we should delete files after conversion
$deleteAfterConvert = $true # Default
if ($Config.ContainsKey('DeleteAfterConvert')) {
    try { $deleteAfterConvert = [System.Convert]::ToBoolean($Config.DeleteAfterConvert) } catch {}
}
# * The -Preserve switch on command line is the highest priority
if ($PSBoundParameters.ContainsKey('Preserve')) {
    $deleteAfterConvert = -not $Preserve.IsPresent
}
#endregion
# * Video extensions shared between conversion and cleanup.
$videoExtensions = @('.mp4', '.mov', '.avi', '.mkv', '.webm')
# * Retention policy defaults: age threshold and behavior.
$retentionDays = 60
if ($Config.ContainsKey('RetentionDays')) {
    try {
        $retentionDays = [int]::Parse($Config.RetentionDays)
    } catch { }
}
$retentionDays = [math]::Max(1, $retentionDays)
$retentionMode = 'auto'
if ($Config.ContainsKey('RetentionMode')) {
    $mode = $Config.RetentionMode.Trim().ToLowerInvariant()
    if ($mode -in @('auto', 'prompt')) {
        $retentionMode = $mode
    }
}

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:stats = $null

function Test-FFmpegAvailable {
    if (-not (Get-Command ffmpeg.exe -ErrorAction SilentlyContinue)) {
        throw $Strings.Convert_FFmpegNotFound
    }
}

function Get-VideoDuration {
    param([string]$FilePath)
    try {
        $ffprobePath = (Get-Command ffprobe.exe -ErrorAction Stop).Source
        $arguments = @(
            '-v', 'error',
            '-show_entries', 'format=duration',
            '-of', 'default=noprint_wrappers=1:nokey=1',
            $FilePath
        )
        $durationStr = & $ffprobePath @arguments | Out-String -Stream
        return [double]::Parse($durationStr.Trim(), [System.Globalization.CultureInfo]::InvariantCulture)
    } catch {
        Write-Warning ("Could not get duration for '{0}'. ETA will be less accurate." -f (Split-Path $FilePath -Leaf))
        return 0
    }
}

# * Returns codec name of the first video stream using ffprobe (e.g., 'h264', 'hevc').
function Get-VideoCodecName {
    param([string]$FilePath)
    try {
        $ffprobePath = (Get-Command ffprobe.exe -ErrorAction Stop).Source
        $arguments = @(
            '-v', 'error',
            '-select_streams', 'v:0',
            '-show_entries', 'stream=codec_name',
            '-of', 'default=noprint_wrappers=1:nokey=1',
            $FilePath
        )
        $codec = (& $ffprobePath @arguments | Out-String -Stream).Trim().ToLowerInvariant()
        return $codec
    } catch {
        return ''
    }
}

# * Chooses a hardware decoder based on input codec and available decoders.
# * Preference order per codec: NVDEC (cuvid) -> QSV -> none.
function Get-DecoderArgsForCodec {
    param(
        [string]$CodecName,
        [string]$DecodersText
    )
    if (-not $CodecName) { return @() }

    $isH264 = ($CodecName -eq 'h264' -or $CodecName -eq 'avc')
    $isHevc = ($CodecName -eq 'hevc' -or $CodecName -eq 'h265')

    if ($isH264) {
        if ($DecodersText -match 'h264_cuvid') { return @('-c:v', 'h264_cuvid') }
        if ($DecodersText -match 'h264_qsv') { return @('-c:v', 'h264_qsv') }
        return @()
    }
    if ($isHevc) {
        if ($DecodersText -match 'hevc_cuvid') { return @('-c:v', 'hevc_cuvid') }
        if ($DecodersText -match 'hevc_qsv') { return @('-c:v', 'hevc_qsv') }
        return @()
    }
    return @()
}

function Write-Summary {
    param(
        [hashtable]$Stats,
        [System.TimeSpan]$ElapsedTime,
        [string]$OutputDirectory
    )
    $processed = $Stats.success
    $failed = $Stats.errors
    $totalVideos = $processed + $failed

    Write-Host ""
    Write-Host $Strings.Summary_Header
    Write-Host ($Strings.Summary_Total -f $totalVideos)
    if ($processed -gt 0) {
        Write-Host ($Strings.Summary_Success -f $processed)
    }
    if ($failed -gt 0) {
        Write-Host ($Strings.Summary_Failed -f $failed)
    }
    if ($Stats.ContainsKey('copied') -and $Stats.copied -gt 0) {
        Write-Host ($Strings.Summary_Copied -f $Stats.copied)
    }
    if ($Stats.ContainsKey('copy_errors') -and $Stats.copy_errors -gt 0) {
        Write-Host ($Strings.Summary_CopyErrors -f $Stats.copy_errors)
    }
    Write-Host ($Strings.Summary_Elapsed -f $ElapsedTime.ToString('g'))

    if ($Stats.bytes_in -gt 0) {
        $delta = $Stats.bytes_out - $Stats.bytes_in
        $delta_mb = $delta / 1MB
        $percent_change = ($delta / $Stats.bytes_in) * 100
        $sign = if ($delta -ge 0) { "+" } else { "" }
        Write-Host ($Strings.Summary_SizeDelta -f $sign, $delta_mb, $sign, $percent_change)
    }

    try {
        $fullOut = (Resolve-Path -LiteralPath $OutputDirectory -ErrorAction Stop).ProviderPath
    } catch { $fullOut = $OutputDirectory }
    Write-Host ($Strings.Summary_OutputFolder -f $fullOut)
}

function Get-BestFfmpegVideoCodec {
    $ffmpegPath = Get-Command ffmpeg.exe | Select-Object -ExpandProperty Source
    $allEncoders = (& $ffmpegPath -encoders 2>&1)
    $allDecoders = (& $ffmpegPath -decoders 2>&1)

    # * Helper function to build decoder argument
    function Get-DecoderArg {
        param([string]$CodecName, [string]$VendorDecoder)
        if ($allDecoders -match $VendorDecoder) { return @('-c:v', $VendorDecoder) }
        return @() # Use default decoder
    }

    # * --- HEVC (H.265) Encoders ---
    if ($allEncoders -match 'hevc_nvenc') {
        return @{
            Encoder     = 'hevc_nvenc'
            DecoderArgs = @(Get-DecoderArg -CodecName 'hevc' -VendorDecoder 'hevc_cuvid')
            EncoderArgs = @(
                '-c:v', 'hevc_nvenc', '-preset', 'p5', '-tune', 'hq', '-rc', 'vbr_hq', '-cq', '30',
                '-spatial_aq', '1', '-temporal_aq', '1', '-aq-strength', '8', '-rc-lookahead', '32',
                '-refs', '4', '-bf', '4', '-b_ref_mode', 'middle'
            )
        }
    }
    if ($allEncoders -match 'hevc_amf') {
        return @{
            Encoder     = 'hevc_amf'
            DecoderArgs = @()
            EncoderArgs = @('-c:v', 'hevc_amf', '-quality', 'quality', '-rc', 'cqp', '-qp_i', '30', '-qp_p', '30', '-bf', '4')
        }
    }
    if ($allEncoders -match 'hevc_qsv') {
        return @{
            Encoder     = 'hevc_qsv'
            DecoderArgs = @(Get-DecoderArg -CodecName 'hevc' -VendorDecoder 'hevc_qsv')
            EncoderArgs = @(
                '-c:v', 'hevc_qsv', '-preset', 'slow', '-cq', '30', '-look_ahead', '1', '-look_ahead_depth', '32'
            )
        }
    }
    if ($allEncoders -match 'libx265') {
        return @{ Encoder = 'libx265'; DecoderArgs = @(); EncoderArgs = @('-c:v', 'libx265', '-preset', 'fast', '-crf', '30') }
    }

    # * --- H.264 Encoders ---
    if ($allEncoders -match 'h264_nvenc') {
        return @{
            Encoder     = 'h264_nvenc'
            DecoderArgs = @(Get-DecoderArg -CodecName 'h264' -VendorDecoder 'h264_cuvid')
            EncoderArgs = @(
                '-c:v', 'h264_nvenc', '-preset', 'p5', '-tune', 'hq', '-rc', 'vbr_hq', '-cq', '30',
                '-spatial_aq', '1', '-temporal_aq', '1', '-aq-strength', '8', '-rc-lookahead', '32',
                '-refs', '4', '-bf', '2'
            )
        }
    }
    if ($allEncoders -match 'h264_amf') {
        return @{
            Encoder     = 'h264_amf'
            DecoderArgs = @()
            EncoderArgs = @('-c:v', 'h264_amf', '-quality', 'quality', '-rc', 'cqp', '-qp_i', '30', '-qp_p', '30', '-bf', '2')
        }
    }
    if ($allEncoders -match 'h264_qsv') {
        return @{
            Encoder     = 'h264_qsv'
            DecoderArgs = @(Get-DecoderArg -CodecName 'h264' -VendorDecoder 'h264_qsv')
            EncoderArgs = @(
                '-c:v', 'h264_qsv', '-preset', 'slow', '-cq', '30', '-look_ahead', '1', '-look_ahead_depth', '32'
            )
        }
    }

    # * --- Final CPU fallback ---
    return @{ Encoder = 'libx264'; DecoderArgs = @(); EncoderArgs = @('-c:v', 'libx264', '-preset', 'fast', '-crf', '30') }
}


function Convert-Videos {
    $sourceFolder = Join-Path -Path $InputDrive -ChildPath 'DCIM'
    if (-not (Test-Path -LiteralPath $sourceFolder)) {
        Write-Warning ($Strings.Convert_SourceNotFound -f $sourceFolder)
        return
    }

    $videoExtensions = @('.mp4', '.mov', '.avi', '.mkv', '.webm')
    $allFiles = Get-ChildItem -Path $sourceFolder -Recurse -File
    
    $filesToConvert = $allFiles | Where-Object { $videoExtensions -contains $_.Extension.ToLower() }
    $filesToCopy = $allFiles | Where-Object { $videoExtensions -notcontains $_.Extension.ToLower() }
    
    # --- Stats and Timer Setup ---
    $script:stats = @{ success = 0; errors = 0; bytes_in = 0; bytes_out = 0; copied = 0; copy_errors = 0 }
    $batchTimer = [System.Diagnostics.Stopwatch]::StartNew()

    if ((-not $filesToConvert) -and (-not $filesToCopy)) {
        Write-Host ("No files to process found in {0}" -f $sourceFolder)
        return
    }

    # --- Copy non-video files first ---
    if ($filesToCopy) {
        $copyCount = @($filesToCopy).Count
        Write-Host ($Strings.Convert_CopyingOther -f $copyCount)
        foreach ($file in $filesToCopy) {
            try {
                $relativePath = $file.FullName.Substring($sourceFolder.Length)
                # * Normalize relative path to avoid leading separator that would break Join-Path semantics
                if ($relativePath -and ($relativePath[0] -eq '\\' -or $relativePath[0] -eq '/')) { $relativePath = $relativePath.Substring(1) }
                $destinationPath = Join-Path -Path $OutputDirectory -ChildPath $relativePath
                $destinationDir = Split-Path -Path $destinationPath -Parent
                if (-not (Test-Path -LiteralPath $destinationDir)) {
                    New-Item -ItemType Directory -Path $destinationDir | Out-Null
                }
                Copy-Item -LiteralPath $file.FullName -Destination $destinationPath -Force
                Write-Host ("  -> Copied: {0}" -f $relativePath.TrimStart('\'))
                $script:stats.copied++
            } catch {
                Write-Host ("[ERROR] Failed to copy '{0}': {1}" -f $file.Name, $_.Exception.Message)
                $script:stats.copy_errors++
            }
        }
    }

    if (-not $filesToConvert) {
        Write-Host ($Strings.Convert_NoVideos -f $sourceFolder)
        return
    }

    $totalCount = @($filesToConvert).Count
    Write-Host ($Strings.Convert_VideosFound -f $totalCount)

    $codecInfo = Get-BestFfmpegVideoCodec
    Write-Host ($Strings.Convert_UsingEncoder -f $codecInfo.Encoder)

    # * Query available decoders once to drive input-aware selection per file
    $ffmpegPath = (Get-Command ffmpeg.exe -ErrorAction Stop).Source
    $availableDecodersText = (& $ffmpegPath -decoders 2>&1)

    # --- ETA Calculation Setup ---
    Write-Host $Strings.Convert_CalcWorkload
    $totalDurationSec = 0
    # * Collect per-file durations to enable better ETA when files are uniform in length
    $fileDurations = New-Object System.Collections.Generic.List[double]
    foreach ($file in $filesToConvert) {
        $d = Get-VideoDuration -FilePath $file.FullName
        $fileDurations.Add([double]$d)
        $totalDurationSec += $d
    }
    if ($totalDurationSec -gt 0) {
        $ts = [TimeSpan]::FromSeconds($totalDurationSec)
        Write-Host ($Strings.Convert_TotalDuration -f $ts.ToString('g'))
    }
    # * Determine if durations are near-uniform (within fixed 2s or 3% tolerance)
    $areUniformDurations = $false
    if ($fileDurations.Count -gt 0) {
        $minD = ($fileDurations | Measure-Object -Minimum).Minimum
        $maxD = ($fileDurations | Measure-Object -Maximum).Maximum
        $absTol = 2.0
        $relTol = 0.03
        $span = [math]::Abs($maxD - $minD)
        $refD = [math]::Max(1.0, ($fileDurations | Measure-Object -Average).Average)
        if (($span -le $absTol) -or (($span / $refD) -le $relTol)) { $areUniformDurations = $true }
    }
    
    $processedDurationSec = 0
    $fileCounter = 0

    foreach ($file in $filesToConvert) {
        $fileCounter++
        # * Use pre-probed duration to avoid calling ffprobe twice
        $currentDuration = if ($fileCounter -le $fileDurations.Count) { $fileDurations[$fileCounter - 1] } else { Get-VideoDuration -FilePath $file.FullName }

        # --- Progress Bar Update (initialize per-file ETA countdown) ---
        $percentComplete = if ($totalCount -gt 0) { ($fileCounter / $totalCount) * 100 } else { 0 }
        $status = "Processing {0} ({1}/{2})" -f $file.Name, $fileCounter, $totalCount
        # * Initialize ETA countdown (monotonic). Compute initial estimate once per file.
        $etaInitialSec = -1
        if ($areUniformDurations) {
            $completedFiles = [double]($fileCounter - 1)
            $fractionOfCurrent = 0.0
            if ($currentDuration -gt 0) { $fractionOfCurrent = 0.0 }
            $processedUnits = $completedFiles + $fractionOfCurrent
            $elapsedSec = $batchTimer.Elapsed.TotalSeconds
            $avgPerFileSec = if ($processedUnits -gt 0) { $elapsedSec / $processedUnits } else { 0 }
            $remainingUnits = [math]::Max(0.0, [double]$totalCount - $processedUnits)
            if ($avgPerFileSec -gt 0) { $etaInitialSec = [int][math]::Ceiling($remainingUnits * $avgPerFileSec) }
        } else {
            if ($processedDurationSec -gt 0 -and $totalDurationSec -gt 0) {
                $elapsedSec = $batchTimer.Elapsed.TotalSeconds
                $rate = if ($elapsedSec -gt 0) { $processedDurationSec / $elapsedSec } else { 0 }
                $remainingSec = $totalDurationSec - $processedDurationSec
                if ($rate -gt 0) { $etaInitialSec = [int][math]::Ceiling($remainingSec / $rate) }
            }
        }
        $etaCountdownSec = if ($etaInitialSec -ge 0) { $etaInitialSec } else { -1 }
        $etaDisplayInit = if ($etaCountdownSec -ge 0) { ([TimeSpan]::FromSeconds($etaCountdownSec)).ToString('hh\:mm\:ss') } else { 'N/A' }
        Write-Progress -Activity "Converting Videos" -Status ($status + " ETA: " + $etaDisplayInit) -PercentComplete $percentComplete -SecondsRemaining -1
        
        $relativePath = $file.FullName.Substring($sourceFolder.Length)
        # * Normalize relative path to avoid leading separator that would break Join-Path semantics
        if ($relativePath -and ($relativePath[0] -eq '\\' -or $relativePath[0] -eq '/')) { $relativePath = $relativePath.Substring(1) }
        $destinationDir = Join-Path -Path $OutputDirectory -ChildPath (Split-Path $relativePath -Parent)
        if (-not (Test-Path -LiteralPath $destinationDir)) {
            New-Item -ItemType Directory -Path $destinationDir | Out-Null
        }
        
        $outputFile = Join-Path -Path $destinationDir -ChildPath "$($file.BaseName).mp4"
        
        # * Select decoder based on INPUT codec, not the chosen OUTPUT encoder.
        $inputCodec = Get-VideoCodecName -FilePath $file.FullName
        $decoderArgs = Get-DecoderArgsForCodec -CodecName $inputCodec -DecodersText $availableDecodersText

        $ffmpegArgs = [System.Collections.Generic.List[string]]@(
            '-y',
            '-hide_banner',
            '-loglevel', 'error'
        )
        
        # * Decoder arguments must come BEFORE the input file
        $ffmpegArgs.AddRange([string[]]$decoderArgs)
        $ffmpegArgs.Add('-i')
        $ffmpegArgs.Add($file.FullName)
        
        # * Encoder arguments come AFTER the input file
        $ffmpegArgs.AddRange([string[]]$codecInfo.EncoderArgs)

        $ffmpegArgs.AddRange([string[]]@(
            '-vf', "scale='if(gt(iw,ih),-2,720)':'if(gt(iw,ih),720,-2)':flags=lanczos,format=yuv420p"
        ))

        $ffmpegArgs.AddRange([string[]]@(
            '-c:a', 'aac',
            '-b:a', '192k',
            '-af', 'acompressor=threshold=-21dB:ratio=4:attack=20:release=250',
            '-map_metadata', '0',
            '-movflags', '+faststart',
            $outputFile
        ))

        # Run ffmpeg asynchronously with progress reporting every ~1s
        $progressFile = [System.IO.Path]::GetTempFileName()
        $ffmpegArgs.Add('-progress')
        $ffmpegArgs.Add($progressFile)

        $ffexe = (Get-Command ffmpeg).Source
        $proc = Start-Process -FilePath $ffexe -ArgumentList $ffmpegArgs.ToArray() -NoNewWindow -PassThru
        $fileStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
        while (-not $proc.HasExited) {
            $curFileSec = 0
            try {
                if (Test-Path -LiteralPath $progressFile) {
                    $lines = Get-Content -LiteralPath $progressFile -ErrorAction SilentlyContinue
                    for ($i = $lines.Count - 1; $i -ge 0; $i--) {
                        $line = $lines[$i]
                        if ($line -like 'out_time_ms=*') {
                            $val = ($line -replace 'out_time_ms=','')
                            [double]$ms = 0; [void][double]::TryParse($val, [ref]$ms)
                            if ($ms -gt 0) { $curFileSec = [int]($ms / 1000000) }
                            break
                        }
                        elseif ($line -like 'out_time=*') {
                            $t = ($line -replace 'out_time=','')
                            $ts = $null; if ([TimeSpan]::TryParse($t, [ref]$ts)) { $curFileSec = [int]$ts.TotalSeconds; break }
                        }
                    }
                }
            } catch { }

            # * Compute percent to reflect already processed frames
            $dynamicProcessed = $processedDurationSec + $curFileSec
            if ($areUniformDurations) {
                $completedFiles = [double]($fileCounter - 1)
                $fractionOfCurrent = 0.0
                if ($currentDuration -gt 0) { $fractionOfCurrent = [math]::Min([double]$curFileSec / [double]$currentDuration, 1.0) }
                $processedUnits = $completedFiles + $fractionOfCurrent
                $overallPercent = if ($totalCount -gt 0) { ([double]$processedUnits / [double]$totalCount) * 100.0 } else { 0 }
            } else {
                $overallPercent = if ($totalDurationSec -gt 0) { ($dynamicProcessed / $totalDurationSec) * 100 } else { $percentComplete }
            }

            $etaDisplay = if ($etaCountdownSec -ge 0) { ([TimeSpan]::FromSeconds($etaCountdownSec)).ToString('hh\:mm\:ss') } else { 'N/A' }
            Write-Progress -Activity "Converting Videos" -Status ($status + " ETA: " + $etaDisplay) -PercentComplete $overallPercent -SecondsRemaining -1
            Start-Sleep -Seconds 1
            # * Tick ETA countdown so timer loses one second per sleep cycle
            if ($etaCountdownSec -ge 0) { $etaCountdownSec = [math]::Max($etaCountdownSec - 1, 0) }
        }
        $fileStopwatch.Stop()
        if (Test-Path -LiteralPath $progressFile) { Remove-Item -LiteralPath $progressFile -Force -ErrorAction SilentlyContinue }

        # * If first attempt fails and a forced decoder was used, retry without forcing decoder (auto/CPU fallback).
        if (($proc.ExitCode -ne 0) -and ($decoderArgs.Count -gt 0)) {
            # ! Remove partial output before retry
            if (Test-Path -LiteralPath $outputFile) { Remove-Item -LiteralPath $outputFile -Force -ErrorAction SilentlyContinue }

            # * Rebuild args without decoder override
            $ffmpegArgs2 = [System.Collections.Generic.List[string]]@(
                '-y',
                '-hide_banner',
                '-loglevel', 'error',
                '-i', $file.FullName
            )
            $ffmpegArgs2.AddRange([string[]]$codecInfo.EncoderArgs)
            $ffmpegArgs2.AddRange([string[]]@(
                '-vf', "scale='if(gt(iw,ih),-2,720)':'if(gt(iw,ih),720,-2)':flags=lanczos,format=yuv420p"
            ))
            $ffmpegArgs2.AddRange([string[]]@(
                '-c:a', 'aac',
                '-b:a', '192k',
                '-af', 'acompressor=threshold=-21dB:ratio=4:attack=20:release=250',
                '-map_metadata', '0',
                '-movflags', '+faststart',
                $outputFile
            ))

            $progressFile2 = [System.IO.Path]::GetTempFileName()
            $ffmpegArgs2.Add('-progress')
            $ffmpegArgs2.Add($progressFile2)

            $proc = Start-Process -FilePath $ffexe -ArgumentList $ffmpegArgs2.ToArray() -NoNewWindow -PassThru
            while (-not $proc.HasExited) {
                $curFileSec = 0
                try {
                    if (Test-Path -LiteralPath $progressFile2) {
                        $lines = Get-Content -LiteralPath $progressFile2 -ErrorAction SilentlyContinue
                        for ($i = $lines.Count - 1; $i -ge 0; $i--) {
                            $line = $lines[$i]
                            if ($line -like 'out_time_ms=*') {
                                $val = ($line -replace 'out_time_ms=','')
                                [double]$ms = 0; [void][double]::TryParse($val, [ref]$ms)
                                if ($ms -gt 0) { $curFileSec = [int]($ms / 1000000) }
                                break
                            }
                            elseif ($line -like 'out_time=*') {
                                $t = ($line -replace 'out_time=','')
                                $ts = $null; if ([TimeSpan]::TryParse($t, [ref]$ts)) { $curFileSec = [int]$ts.TotalSeconds; break }
                            }
                        }
                    }
                } catch { }

                $dynamicProcessed = $processedDurationSec + $curFileSec
                $overallPercent = if ($totalDurationSec -gt 0) { ($dynamicProcessed / $totalDurationSec) * 100 } else { $percentComplete }
                $etaDisplay = if ($etaCountdownSec -ge 0) { ([TimeSpan]::FromSeconds($etaCountdownSec)).ToString('hh\:mm\:ss') } else { 'N/A' }
                Write-Progress -Activity "Converting Videos" -Status ($status + " ETA: " + $etaDisplay) -PercentComplete $overallPercent -SecondsRemaining -1
                Start-Sleep -Seconds 1
                # * Tick ETA countdown to keep fallback display aligned with timer
                if ($etaCountdownSec -ge 0) { $etaCountdownSec = [math]::Max($etaCountdownSec - 1, 0) }
            }
            if (Test-Path -LiteralPath $progressFile2) { Remove-Item -LiteralPath $progressFile2 -Force -ErrorAction SilentlyContinue }
        }

        if ($proc.ExitCode -eq 0) {
            Write-Host ($Strings.Convert_ConvertSuccess -f $outputFile)
            $script:stats.success++
            $script:stats.bytes_in += $file.Length
            $convertedOk = $false
            try {
                $outItem = Get-Item -LiteralPath $outputFile -ErrorAction Stop
                $script:stats.bytes_out += $outItem.Length
                if ($outItem.Length -gt 0) { $convertedOk = $true }
            } catch { $convertedOk = $false }
            if ($deleteAfterConvert -and $convertedOk) {
                Remove-Item -LiteralPath $file.FullName -Force
            }
        } else {
            Write-Host ($Strings.Convert_ConvertFailed -f $file.Name)
            $script:stats.errors++
            # Clean up partial output file
            if (Test-Path -LiteralPath $outputFile) {
                Remove-Item -LiteralPath $outputFile -Force
            }
        }
        $processedDurationSec += $currentDuration
    }

    $batchTimer.Stop()
    Write-Progress -Activity "Converting Videos" -Completed

    if ($retentionDays -gt 0) {
        Remove-OldArchiveFiles -ArchiveRoot $OutputDirectory -RetentionDays $retentionDays -Mode $retentionMode
    }
}

# * Computes the relative path of a child entry under a reference folder.
function Get-RelativeChildPath {
    param(
        [Parameter(Mandatory = $true)][string]$BasePath,
        [Parameter(Mandatory = $true)][string]$TargetPath
    )

    $baseResolved = $null
    $targetResolved = $null
    try { $baseResolved = (Resolve-Path -LiteralPath $BasePath -ErrorAction Stop).ProviderPath } catch { $baseResolved = $BasePath }
    try { $targetResolved = (Resolve-Path -LiteralPath $TargetPath -ErrorAction Stop).ProviderPath } catch { $targetResolved = $TargetPath }

    if (-not $baseResolved -or -not $targetResolved) { return $targetResolved }
    $normalizedBase = $baseResolved.TrimEnd('\', '/')
    if ($targetResolved.Length -le $normalizedBase.Length) { return $targetResolved }
    $relative = $targetResolved.Substring($normalizedBase.Length)
    if ($relative.StartsWith('\') -or $relative.StartsWith('/')) { $relative = $relative.Substring(1) }
    return $relative
}

# * Removes stale video files older than the retention threshold and prunes empty directories.
function Remove-OldArchiveFiles {
    param(
        [Parameter(Mandatory = $true)][string]$ArchiveRoot,
        [Parameter(Mandatory = $true)][int]$RetentionDays,
        [Parameter(Mandatory = $true)][string]$Mode
    )

    if (-not (Test-Path -LiteralPath $ArchiveRoot)) { return }
    if ($RetentionDays -le 0) { return }

    $resolvedRoot = $null
    try { $resolvedRoot = (Resolve-Path -LiteralPath $ArchiveRoot -ErrorAction Stop).ProviderPath } catch { $resolvedRoot = $ArchiveRoot }
    Write-Host ($Strings.Convert_RetentionScanning -f $resolvedRoot, $RetentionDays)

    $cutoff = (Get-Date).AddDays(-$RetentionDays)
    $candidateFiles = @(Get-ChildItem -LiteralPath $resolvedRoot -Recurse -File -ErrorAction SilentlyContinue | Where-Object {
        $ext = $_.Extension.ToLowerInvariant()
        ($videoExtensions -contains $ext) -and ($_.LastWriteTime -lt $cutoff)
    })

    if (-not $candidateFiles -or $candidateFiles.Count -eq 0) {
        Write-Host ($Strings.Convert_RetentionNone -f $RetentionDays)
        return
    }

    $fileCount = $candidateFiles.Count
    Write-Host ($Strings.Convert_RetentionFound -f $fileCount, $RetentionDays)

    if ($Mode -eq 'prompt') {
        foreach ($file in $candidateFiles) {
            $relativePath = Get-RelativeChildPath -BasePath $resolvedRoot -TargetPath $file.FullName
            Write-Host ("  - {0}" -f $relativePath)
        }
        $userInput = Read-Host ($Strings.Convert_RetentionPrompt -f $RetentionDays)
        if ($userInput.Trim().ToLowerInvariant() -notmatch '^(y|д|yes|да)$') {
            Write-Host $Strings.Convert_RetentionSkipped
            return
        }
    }

    Write-Host $Strings.Convert_RetentionDeleting
    $deletedCount = 0
    foreach ($file in $candidateFiles) {
        try {
            Remove-Item -LiteralPath $file.FullName -Force
            $deletedCount++
        } catch {
            Write-Warning ("Failed to delete '{0}': {1}" -f $file.FullName, $_.Exception.Message)
        }
    }
    Write-Host ($Strings.Convert_RetentionDeleted -f $deletedCount)

    Write-Host $Strings.Convert_RetentionCleaning
    $directories = Get-ChildItem -LiteralPath $resolvedRoot -Directory -Recurse -ErrorAction SilentlyContinue |
        Sort-Object -Property @{ Expression = { $_.FullName.Length }; Descending = $true }
    foreach ($dir in $directories) {
        if ($null -eq (Get-ChildItem -LiteralPath $dir.FullName -Force -ErrorAction SilentlyContinue | Select-Object -First 1)) {
            try {
                Remove-Item -LiteralPath $dir.FullName -Force
                Write-Host ($Strings.Convert_RetentionDirClean -f $dir.FullName)
            } catch {
                Write-Warning ("Failed to remove directory '{0}': {1}" -f $dir.FullName, $_.Exception.Message)
            }
        }
    }
}

try {
    Test-FFmpegAvailable
    $overallTimer = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        Convert-Videos
        Write-Host $Strings.Convert_ProcessComplete
    } finally {
        # Ensure summary appears even on interruption or error
        Write-Progress -Activity "Converting Videos" -Completed
        if ($overallTimer) { $overallTimer.Stop() }
        # Build minimal stats if Convert-Videos failed early
        if (-not ($script:stats)) {
            $script:stats = @{ success = 0; errors = 0; bytes_in = 0; bytes_out = 0; copied = 0; copy_errors = 0 }
        }
        Write-Summary -Stats $script:stats -ElapsedTime $overallTimer.Elapsed -OutputDirectory $OutputDirectory
    }
} catch {
    $e = $_
    $errMsg = $null
    try { $errMsg = $e.Exception.Message } catch { }
    if (-not $errMsg) { try { $errMsg = ($e | Out-String) } catch { $errMsg = 'Unhandled error' } }
    Write-Host ("[ERROR] {0}" -f $errMsg)
    exit 1
}

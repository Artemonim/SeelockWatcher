#requires -Version 5.1
param(
	# * Path to Seelock Connect LTE executable
	[string]$ExePath = "C:\Program Files\Seelock Connect LTE\SeelockConnectLTE.exe",
	# * Password for the device (will not be logged)
	[string]$Password = "",
	# * Max time to wait for windows/controls (seconds)
	[int]$UiTimeoutSec = 1,
	# * Max time to wait for new USB drive to appear (seconds)
	[int]$DriveTimeoutSec = 1,
	# * Close the application when done
	[switch]$CloseApp = $true,
	# * If true, attempt reattach even if drive seems already mounted
	[switch]$ForceReattach,
	# * Folder names that indicate Seelock mass storage already mounted
	[string[]]$ExistingDriveIndicators = @('DCIM','PHOTO','MOVIE','RECORD','VIDEO','LOG'),
	# * Verbose logging
	[switch]$VerboseLog
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$operationSucceeded = $false

function Write-Info {
	param([string]$Message)
	if ($VerboseLog) { Write-Host "[INFO] $Message" }
}

function Throw-If([bool]$Condition, [string]$Message) {
	if ($Condition) { throw $Message }
}

function Get-ExistingDrives {
	try {
		# * Returns current filesystem drive letters
		(Get-PSDrive -PSProvider FileSystem | Where-Object { $_.Root -match '^[A-Z]:\\$' }).Name | ForEach-Object { "{0}:" -f $_ } | Sort-Object -Unique
	} catch {
		# * Fallback via CIM if PSDrive fails
		(Get-CimInstance Win32_Volume | Where-Object { $_.DriveLetter } | Select-Object -ExpandProperty DriveLetter | Sort-Object -Unique)
	}
}

function Test-SeelockDrivePresent {
	param([string[]]$Indicators)
	$drives = Get-ExistingDrives
	foreach ($d in $drives) {
		try {
			$root = (Join-Path -Path $d -ChildPath '.')
			$items = @(Get-ChildItem -LiteralPath $root -Force -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name)
			if ($items) {
				foreach ($mark in $Indicators) {
					if ($items -contains $mark) { return $d }
				}
			}
		} catch {
			Write-Info ("Skipping drive {0}: {1}" -f $d, $_.Exception.Message)
		}
	}
	return $null
}

function Wait-ForNewDrive {
	param([string[]]$Before, [int]$TimeoutSec)
	$deadline = (Get-Date).AddSeconds($TimeoutSec)
	while ((Get-Date) -lt $deadline) {
		$now = Get-ExistingDrives
		$new = Compare-Object -ReferenceObject $Before -DifferenceObject $now | Where-Object { $_.SideIndicator -eq '=>' } | Select-Object -ExpandProperty InputObject -ErrorAction SilentlyContinue
		if ($new) { return ($new | Select-Object -First 1) }
		Start-Sleep -Milliseconds 500
	}
	return $null
}

function Import-UIAutomationAssemblies {
	# * Loads .NET UIAutomation assemblies
	Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes | Out-Null
}

function Get-SeelockProcesses {
	# * Returns all running processes for Seelock Connect LTE
	$procs = @()
	try { $procs += Get-Process -Name 'SeelockConnectLTE' -ErrorAction SilentlyContinue } catch { }
	return $procs | Where-Object { $_ -ne $null } | Sort-Object -Property Id -Unique
}

function Close-SeelockGracefully {
	param([int]$TimeoutSec = 10)
	$deadline = (Get-Date).AddSeconds($TimeoutSec)
	$attemptedClose = $false
	while ((Get-Date) -lt $deadline) {
		$procs = @(Get-SeelockProcesses)
		if (-not $procs -or @($procs).Count -eq 0) { return $true }
		if (-not $attemptedClose) {
			foreach ($p in $procs) { try { $p.CloseMainWindow() | Out-Null } catch { } }
			# * Try UI Automation to close visible top-level windows, including success modals
			try {
				$wins = @()
				foreach ($p in $procs) { $wins += (Get-TopLevelWindowsByProcessId -ProcessId $p.Id) }
				for ($w = 0; $w -lt $wins.Count; $w++) {
					$wEl = $wins[$w]
					$ok = Find-OkButton -Root $wEl -TimeoutSec 1
					if ($ok) { Invoke-ElementClick -Element $ok }
				}
			} catch { Write-Info ("Close-SeelockGracefully UI sweep: {0}" -f $_.Exception.Message) }
			$attemptedClose = $true
		}
		Start-Sleep -Milliseconds 200
	}
	return $false
}

function Kill-SeelockForce {
	try {
		$procs = Get-SeelockProcesses
		foreach ($p in $procs) { try { if (-not $p.HasExited) { $p.Kill() } } catch { Write-Info ("Kill failed: {0}" -f $_.Exception.Message) } }
	} catch { Write-Info ("Kill enumeration failed: {0}" -f $_.Exception.Message) }
}

function Get-TopLevelWindowsByProcessId {
	param([int]$ProcessId)
	$root = [System.Windows.Automation.AutomationElement]::RootElement
	$pidProp = [System.Windows.Automation.AutomationElement]::ProcessIdProperty
	$cond = New-Object System.Windows.Automation.PropertyCondition($pidProp, $ProcessId)
	$col = $root.FindAll([System.Windows.Automation.TreeScope]::Children, $cond)
	if (-not $col) { return @() }
	# * Convert AutomationElementCollection to PowerShell array to ensure .Count is available
	$results = @()
	for ($i = 0; $i -lt $col.Count; $i++) { $results += $col.Item($i) }
	return ,$results
}

function Find-TopLevelWindowByProcessId {
	param([int]$ProcessId, [int]$TimeoutSec)
	$deadline = (Get-Date).AddSeconds($TimeoutSec)
	$root = [System.Windows.Automation.AutomationElement]::RootElement
	$pidProp = [System.Windows.Automation.AutomationElement]::ProcessIdProperty
	$cond = New-Object System.Windows.Automation.PropertyCondition($pidProp, $ProcessId)
	while ((Get-Date) -lt $deadline) {
		$win = $root.FindFirst([System.Windows.Automation.TreeScope]::Children, $cond)
		if ($win) { return $win }
		Start-Sleep -Milliseconds 200
	}
	return $null
}

function Find-DescendantButtonByNames {
	param($Root, [string[]]$Names, [int]$TimeoutSec)
	$deadline = (Get-Date).AddSeconds($TimeoutSec)
	$ae = [System.Windows.Automation.AutomationElement]
	$ct = [System.Windows.Automation.ControlType]::Button
	$typeCond = New-Object System.Windows.Automation.PropertyCondition($ae::ControlTypeProperty, $ct)
	while ((Get-Date) -lt $deadline) {
		# * Try exact name matches first
		$conds = @()
		foreach ($n in $Names) { $conds += New-Object System.Windows.Automation.PropertyCondition($ae::NameProperty, $n) }
		if ($conds.Count -gt 0) {
			$or = New-Object System.Windows.Automation.OrCondition($conds)
			$and = New-Object System.Windows.Automation.AndCondition($typeCond, $or)
			$btn = $Root.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $and)
			if ($btn) { return $btn }
		}
		# * Fallback: any button containing keyword 'USB'
		$btns = $Root.FindAll([System.Windows.Automation.TreeScope]::Descendants, $typeCond)
		for ($i = 0; $i -lt $btns.Count; $i++) {
			$name = $btns.Item($i).Current.Name
			if ($name -and ($name -match 'USB' -or $name -match 'диск' -or $name -match 'Disk')) { return $btns.Item($i) }
		}
		Start-Sleep -Milliseconds 200
	}
	return $null
}

function Find-UsbButtonAcrossWindows {
	param([int]$ProcessId, [int]$TimeoutSec)
	$deadline = (Get-Date).AddSeconds($TimeoutSec)
	while ((Get-Date) -lt $deadline) {
		$wins = Get-TopLevelWindowsByProcessId -ProcessId $ProcessId
		for ($w = 0; $w -lt $wins.Count; $w++) {
			$wEl = $wins[$w]
			$btn = Find-DescendantButtonByNames -Root $wEl -Names @('USB диск','USB Disk','Подключить USB диск','Connect USB Disk') -TimeoutSec 1
			if ($btn) { return $btn }
		}
		Start-Sleep -Milliseconds 200
	}
	return $null
}

function Find-OkButton {
	param($Root, [int]$TimeoutSec)
	$deadline = (Get-Date).AddSeconds($TimeoutSec)
	$ae = [System.Windows.Automation.AutomationElement]
	$ct = [System.Windows.Automation.ControlType]::Button
	$typeCond = New-Object System.Windows.Automation.PropertyCondition($ae::ControlTypeProperty, $ct)
	$names = @('OK','Ok','ОК','Ок','Закрыть','Close','Yes','Да','Продолжить','Continue','Готово','Done')
	while ((Get-Date) -lt $deadline) {
		$btns = $Root.FindAll([System.Windows.Automation.TreeScope]::Descendants, $typeCond)
		for ($i = 0; $i -lt $btns.Count; $i++) {
			$name = $btns.Item($i).Current.Name
			if ($name -and ($names | Where-Object { $name -like "$_*" }).Count -gt 0) { return $btns.Item($i) }
		}
		Start-Sleep -Milliseconds 200
	}
	return $null
}

function Wait-CloseSuccessLoginModal {
	param([int]$ProcessId, [int]$TimeoutSec)
	$deadline = (Get-Date).AddSeconds($TimeoutSec)
	$ae = [System.Windows.Automation.AutomationElement]
	$textType = [System.Windows.Automation.ControlType]::Text
	$textCond = New-Object System.Windows.Automation.PropertyCondition($ae::ControlTypeProperty, $textType)
	while ((Get-Date) -lt $deadline) {
		$wins = Get-TopLevelWindowsByProcessId -ProcessId $ProcessId
		for ($w = 0; $w -lt $wins.Count; $w++) {
			$wEl = $wins[$w]
			$name = $wEl.Current.Name
			$hit = $false
			if ($name -and ($name -match 'Успеш' -or $name -match 'Success' -or $name -match 'Выполнено' -or $name -match 'Удачно')) { $hit = $true }
			if (-not $hit) {
				# * Inspect inner static text for success keywords
				try {
					$texts = $wEl.FindAll([System.Windows.Automation.TreeScope]::Descendants, $textCond)
					for ($i = 0; $i -lt $texts.Count; $i++) {
						$tn = $texts.Item($i).Current.Name
						if ($tn -and ($tn -match 'Успеш' -or $tn -match 'Success' -or $tn -match 'Вход выполнен' -or $tn -match 'Авторизац')) { $hit = $true; break }
					}
				} catch { Write-Info ("Success modal scan: {0}" -f $_.Exception.Message) }
			}
			if ($hit) {
				$ok = Find-OkButton -Root $wEl -TimeoutSec 2
				if ($ok) { Invoke-ElementClick -Element $ok; return $true }
			}
		}
		Start-Sleep -Milliseconds 200
	}
	return $false
}

function Get-WindowTextContents {
	param($Root)
	$ae = [System.Windows.Automation.AutomationElement]
	$textType = [System.Windows.Automation.ControlType]::Text
	$textCond = New-Object System.Windows.Automation.PropertyCondition($ae::ControlTypeProperty, $textType)
	$result = @()
	try {
		$texts = $Root.FindAll([System.Windows.Automation.TreeScope]::Descendants, $textCond)
		for ($i = 0; $i -lt $texts.Count; $i++) {
			$tn = $texts.Item($i).Current.Name
			if ($tn) { $result += $tn }
		}
	} catch { Write-Info ("Read window text: {0}" -f $_.Exception.Message) }
	return ($result -join ' ').Trim()
}

function Wait-CloseConnectionErrorModal {
	param([int]$ProcessId, [int]$TimeoutSec)
	$deadline = (Get-Date).AddSeconds($TimeoutSec)
	while ((Get-Date) -lt $deadline) {
		$wins = Get-TopLevelWindowsByProcessId -ProcessId $ProcessId
		for ($w = 0; $w -lt $wins.Count; $w++) {
			$wEl = $wins[$w]
			$name = $wEl.Current.Name
			$allText = (Get-WindowTextContents -Root $wEl)
			$hay = (($name + ' ' + $allText) -as [string])
			if ($hay -and ($hay -match 'Ошибка' -or $hay -match 'ошибка' -or $hay -match 'Error' -or $hay -match 'Не удалось' -or $hay -match 'Failed' -or $hay -match 'подключ')) {
				# * Classify reason
				$reason = 'Generic'
				if ($hay -match 'уже' -and $hay -match 'подключ') { $reason = 'AlreadyConnected' }
				elseif ($hay -match 'парол' -or $hay -match 'password') { $reason = 'AuthFailed' }
				# * Close modal
				$ok = Find-OkButton -Root $wEl -TimeoutSec 2
				if ($ok) { Invoke-ElementClick -Element $ok }
				return $reason
			}
		}
		Start-Sleep -Milliseconds 150
	}
	return $null
}

function Find-DescendantEditForPassword {
	param($Root, [int]$TimeoutSec)
	$deadline = (Get-Date).AddSeconds($TimeoutSec)
	$ae = [System.Windows.Automation.AutomationElement]
	$ct = [System.Windows.Automation.ControlType]::Edit
	$typeCond = New-Object System.Windows.Automation.PropertyCondition($ae::ControlTypeProperty, $ct)
	while ((Get-Date) -lt $deadline) {
		$edits = $Root.FindAll([System.Windows.Automation.TreeScope]::Descendants, $typeCond)
		# * Prefer true password boxes (IsPassword)
		for ($i = 0; $i -lt $edits.Count; $i++) {
			$edit = $edits.Item($i)
			try {
				$isPwd = $edit.GetCurrentPropertyValue($ae::IsPasswordProperty)
				if ($isPwd) { return $edit }
			} catch { Write-Info ("Probe IsPassword: {0}" -f $_.Exception.Message) }
		}
		# * Next: labeled by 'Пароль'/'Password'
		for ($i = 0; $i -lt $edits.Count; $i++) {
			$edit = $edits.Item($i)
			try {
				$label = $edit.Current.LabeledBy
				if ($label -and ($label.Current.Name -match 'Парол' -or $label.Current.Name -match 'Passw')) { return $edit }
			} catch { }
		}
		# * Proximity to a static text with 'Пароль'
		$txtType = [System.Windows.Automation.ControlType]::Text
		$txtCond = New-Object System.Windows.Automation.PropertyCondition($ae::ControlTypeProperty, $txtType)
		$texts = $Root.FindAll([System.Windows.Automation.TreeScope]::Descendants, $txtCond)
		for ($t = 0; $t -lt $texts.Count; $t++) {
			$txt = $texts.Item($t)
			if ($txt.Current.Name -and ($txt.Current.Name -match 'Парол' -or $txt.Current.Name -match 'Passw')) {
				# * Find nearest edit by vertical distance
				$best = $null; $bestDy = [double]::PositiveInfinity
				for ($i = 0; $i -lt $edits.Count; $i++) {
					$e = $edits.Item($i)
					$dy = [math]::Abs($e.Current.BoundingRectangle.Y - $txt.Current.BoundingRectangle.Y)
					if ($dy -lt $bestDy) { $best = $e; $bestDy = $dy }
				}
				if ($best) { return $best }
			}
		}
		# * Fallback: return last edit (password often second)
		if ($edits.Count -gt 0) { return $edits.Item($edits.Count - 1) }
		Start-Sleep -Milliseconds 200
	}
	return $null
}

function Invoke-ElementClick {
	param($Element)
	$invokePattern = [System.Windows.Automation.InvokePattern]::Pattern
	if ($Element.TryGetCurrentPattern($invokePattern, [ref]([object]$null))) {
		$pattern = $Element.GetCurrentPattern($invokePattern)
		$pattern.Invoke()
		return
	}
	# ! Warning: fallback using real mouse click at clickable point (avoid sending Enter)
	$pt = $Element.GetClickablePoint()
	Add-Type -AssemblyName System.Windows.Forms | Out-Null
	[System.Windows.Forms.Cursor]::Position = New-Object System.Drawing.Point([int]$pt.X, [int]$pt.Y)
	if (-not ([System.Management.Automation.PSTypeName]'NativeMouse').Type) {
		Add-Type @"
using System;
using System.Runtime.InteropServices;
public static class NativeMouse {
    [DllImport("user32.dll", SetLastError=true)]
    public static extern void mouse_event(int dwFlags, int dx, int dy, int dwData, int dwExtraInfo);
    public const int MOUSEEVENTF_LEFTDOWN = 0x0002;
    public const int MOUSEEVENTF_LEFTUP   = 0x0004;
}
"@
	}
	[NativeMouse]::mouse_event([NativeMouse]::MOUSEEVENTF_LEFTDOWN, 0, 0, 0, 0)
	Start-Sleep -Milliseconds 30
	[NativeMouse]::mouse_event([NativeMouse]::MOUSEEVENTF_LEFTUP, 0, 0, 0, 0)
}

function Set-EditValue {
	param($Edit, [string]$Text)
	$valPattern = [System.Windows.Automation.ValuePattern]::Pattern
	if ($Edit.TryGetCurrentPattern($valPattern, [ref]([object]$null))) {
		$pattern = $Edit.GetCurrentPattern($valPattern)
		try { $pattern.SetValue("") } catch { }
		$pattern.SetValue($Text)
		return
	}
	# ! Warning: fallback to focus + clipboard paste to avoid stray chars
	$Edit.SetFocus()
	Add-Type -AssemblyName System.Windows.Forms | Out-Null
	try { [System.Windows.Forms.SendKeys]::SendWait('^a{DEL}') } catch { }
	Set-Clipboard -Value $Text -AsPlainText
	[System.Windows.Forms.SendKeys]::SendWait('^v')
}

try {
	Throw-If -Condition (-not (Test-Path -LiteralPath $ExePath)) -Message ("Executable not found: {0}" -f $ExePath)
	Throw-If -Condition ([string]::IsNullOrWhiteSpace($Password)) -Message "Password is required. Pass -Password 'YOUR_PASSWORD'"

	# * Short-circuit if already mounted and not forcing reattach
	$existing = $null
	if (-not $ForceReattach) {
		$existing = Test-SeelockDrivePresent -Indicators $ExistingDriveIndicators
		if ($existing) {
			Write-Output ("DriveReady={0}" -f $existing)
			$operationSucceeded = $true
			return
		}
	}

	Write-Info ("Launching: {0}" -f $ExePath)
	$drivesBefore = Get-ExistingDrives
	$proc = Start-Process -FilePath $ExePath -PassThru
	$proc.EnableRaisingEvents = $true

	Import-UIAutomationAssemblies
	$mainWindow = Find-TopLevelWindowByProcessId -ProcessId $proc.Id -TimeoutSec $UiTimeoutSec
	Throw-If -Condition (-not $mainWindow) -Message "Main window not found within timeout"
	try { $mainWindow.SetFocus() } catch { }

	Write-Info "Clicking 'Connect/Подключение' button"
	$connectBtn = Find-DescendantButtonByNames -Root $mainWindow -Names @('Подключение','Connect','Connection') -TimeoutSec $UiTimeoutSec
	Throw-If -Condition (-not $connectBtn) -Message "Connect button not found"
	Invoke-ElementClick -Element $connectBtn
	Start-Sleep -Milliseconds 300

	Write-Info "Entering password"
	$pwdEdit = Find-DescendantEditForPassword -Root $mainWindow -TimeoutSec $UiTimeoutSec
	Throw-If -Condition (-not $pwdEdit) -Message "Password field not found"
	Set-EditValue -Edit $pwdEdit -Text $Password
	Start-Sleep -Milliseconds 300

	Write-Info "Clicking 'Login/Логин' button"
	$loginBtn = Find-DescendantButtonByNames -Root $mainWindow -Names @('Логин','Login') -TimeoutSec $UiTimeoutSec
	Throw-If -Condition (-not $loginBtn) -Message "Login button not found"
	Invoke-ElementClick -Element $loginBtn

	# * Close success login modal if present, then wait for USB button or error
	[void] (Wait-CloseSuccessLoginModal -ProcessId $proc.Id -TimeoutSec 5)

	# * Wait for either USB button or error modal
	$deadlineLogin = (Get-Date).AddSeconds($UiTimeoutSec)
	$usbBtn = $null
	while ((Get-Date) -lt $deadlineLogin) {
		if ($proc.HasExited) { throw "Application exited unexpectedly after login" }
		$usbBtn = Find-UsbButtonAcrossWindows -ProcessId $proc.Id -TimeoutSec 1
		if ($usbBtn) { break }
		# * Look for error modal under same process
		$wins = Get-TopLevelWindowsByProcessId -ProcessId $proc.Id
		for ($w = 0; $w -lt $wins.Count; $w++) {
			$wEl = $wins.Item($w)
			$name = $wEl.Current.Name
			if ($name -and ($name -match 'Ошибка' -or $name -match 'Error' -or $name -match 'Неверный')) {
				throw ("Login error dialog detected: {0}" -f $name)
			}
			# * Also close any success modal encountered mid-wait
			[void] (Wait-CloseSuccessLoginModal -ProcessId $proc.Id -TimeoutSec 1)
		}
		Start-Sleep -Milliseconds 200
	}
	if (-not $usbBtn) {
		# * If USB button not visible, check for connection-required modal and close it
		$errReason = Wait-CloseConnectionErrorModal -ProcessId $proc.Id -TimeoutSec 2
		if ($errReason) { throw ("USB button not available after login ({0})" -f $errReason) }
		throw "USB Disk button not found after login"
	}
	Write-Info "Clicking '(подключить) USB диск'"
	Invoke-ElementClick -Element $usbBtn
	# * Handle success modal that appears after USB connect
	Start-Sleep -Milliseconds 300
	[void] (Wait-CloseSuccessLoginModal -ProcessId $proc.Id -TimeoutSec 5)

	Write-Info "Waiting for new USB drive to appear"
	$newDrive = Wait-ForNewDrive -Before $drivesBefore -TimeoutSec $DriveTimeoutSec
	if (-not $newDrive) {
		# * Check for connection error modal and close it for a clean end
		$errReason = Wait-CloseConnectionErrorModal -ProcessId $proc.Id -TimeoutSec 2
		if ($errReason) {
			throw ("USB connect failed ({0})" -f $errReason)
		}
		throw "No new drive detected within $DriveTimeoutSec seconds"
	}

	Write-Output ("DriveReady={0}" -f $newDrive)
	$operationSucceeded = $true
	
	if ($CloseApp) {
		Write-Info "Closing application"
		$grace = Close-SeelockGracefully -TimeoutSec 10
		if (-not $grace) {
			Write-Info "Force killing Seelock processes"
			Kill-SeelockForce
		}
	}
}
catch {
	# ! Handle errors gracefully. If core operation succeeded, do not print as error; just clean up and exit 0
	$msg = $_.Exception.Message
	if ($operationSucceeded) {
		Write-Info ("Cleanup after success: {0}" -f $msg)
		try { if ($CloseApp) { $null = Close-SeelockGracefully -TimeoutSec 2; Kill-SeelockForce } } catch { }
		exit 0
	} else {
		Write-Error ("Automation failed: {0}" -f $msg)
		try { if ($proc -and -not $proc.HasExited -and $CloseApp) { $null = Close-SeelockGracefully -TimeoutSec 2; Kill-SeelockForce } } catch { }
		exit 1
	}
}
finally {
	# * Ensure app is terminated even if unhandled runtime errors occur
	try { if ($CloseApp) { $null = Close-SeelockGracefully -TimeoutSec 2; Kill-SeelockForce } } catch { }
}



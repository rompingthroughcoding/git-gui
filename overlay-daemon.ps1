param(
	[string]$CommandFile,
	[long]$OwnerHwnd
)

# Persistent overlay daemon for git-gui-master. Compiles the Win32 interop once,
# then reads "attach" commands from $CommandFile and manages every docked window
# (main repo windows and tool windows) in a single loop - so docking a repo or a
# tool window is near-instant instead of paying a fresh PowerShell + Add-Type
# startup each time.
#
# Command line format (space separated, status path last):
#   <hwnd|pid> <id> <hostHwnd> <closeWithHost 0|1> <statusFile>

Add-Type @"
using System;
using System.Runtime.InteropServices;
public class NativeOverlay {
	[DllImport("user32.dll")] public static extern IntPtr SetWindowLongPtr(IntPtr h, int idx, IntPtr val);
	[DllImport("user32.dll", SetLastError=true)] public static extern int GetWindowLong(IntPtr h, int idx);
	[DllImport("user32.dll")] public static extern int SetWindowLong(IntPtr h, int idx, int val);
	[DllImport("user32.dll")] public static extern bool MoveWindow(IntPtr h, int x, int y, int w, int ht, bool repaint);
	[DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int cmd);
	[DllImport("user32.dll")] public static extern bool IsWindow(IntPtr h);
	[DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
	[DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
	[DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int cx, int cy, uint flags);
	[DllImport("user32.dll")] public static extern IntPtr PostMessage(IntPtr h, uint msg, IntPtr wp, IntPtr lp);
	public struct RECT { public int Left, Top, Right, Bottom; }
}
"@

$owner = [IntPtr]$OwnerHwnd
$GWL_STYLE = -16; $GWLP_HWNDPARENT = -8
$WS_CAPTION = 0x00C00000; $WS_THICKFRAME = 0x00040000
$WS_MINIMIZE = 0x20000000; $WS_MAXIMIZE = 0x01000000; $WS_POPUP = [int]0x80000000
$WM_CLOSE = 0x0010

function Write-St($status, $text) { if ($status) { Set-Content -Path $status -Value $text -EA SilentlyContinue } }

$managed = New-Object System.Collections.ArrayList
$processed = 0

while ([NativeOverlay]::IsWindow($owner)) {
	if (Test-Path -LiteralPath $CommandFile) {
		$lines = @(Get-Content -LiteralPath $CommandFile -EA SilentlyContinue)
		for ($i = $processed; $i -lt $lines.Count; $i++) {
			$parts = $lines[$i] -split ' ', 5
			if ($parts.Count -lt 5) { continue }
			[void]$managed.Add([pscustomobject]@{
				Kind = $parts[0]; Id = [long]$parts[1]; Host = [IntPtr][long]$parts[2]
				CloseWith = ($parts[3] -eq '1'); Status = $parts[4]
				Gg = [IntPtr]::Zero; Attached = $false; Hidden = $false; Last = ""; Tries = 0
			})
		}
		$processed = $lines.Count
	}

	$dead = New-Object System.Collections.ArrayList
	foreach ($e in $managed) {
		if ($e.Gg -eq [IntPtr]::Zero) {
			if ($e.Kind -eq 'hwnd') {
				$e.Gg = [IntPtr]$e.Id
			} else {
				try { $p = Get-Process -Id ([int]$e.Id) -EA Stop; $p.Refresh(); if ($p.MainWindowHandle -ne [IntPtr]::Zero) { $e.Gg = $p.MainWindowHandle } }
				catch { [void]$dead.Add($e); Write-St $e.Status "closed"; continue }
			}
			$e.Tries++
			if ($e.Gg -eq [IntPtr]::Zero) { if ($e.Tries -gt 150) { [void]$dead.Add($e) }; continue }
		}
		if (-not [NativeOverlay]::IsWindow($e.Gg)) { [void]$dead.Add($e); Write-St $e.Status "closed"; continue }
		if (-not $e.Attached) {
			[void][NativeOverlay]::SetWindowLongPtr($e.Gg, $GWLP_HWNDPARENT, $owner)
			$s = [NativeOverlay]::GetWindowLong($e.Gg, $GWL_STYLE)
			$s = $s -band (-bnot ($WS_CAPTION -bor $WS_THICKFRAME -bor $WS_MINIMIZE -bor $WS_MAXIMIZE -bor $WS_POPUP))
			[void][NativeOverlay]::SetWindowLong($e.Gg, $GWL_STYLE, $s)
			[void][NativeOverlay]::SetWindowPos($e.Gg, [IntPtr]::Zero, 0, 0, 0, 0, 0x37)
			$e.Attached = $true
			Write-St $e.Status "overlay gg=$($e.Gg)"
		}
		if ($e.CloseWith -and -not [NativeOverlay]::IsWindow($e.Host)) {
			if ([NativeOverlay]::IsWindow($e.Gg)) { [void][NativeOverlay]::PostMessage($e.Gg, $WM_CLOSE, [IntPtr]::Zero, [IntPtr]::Zero) }
			[void]$dead.Add($e); Write-St $e.Status "closed"; continue
		}
		if ([NativeOverlay]::IsWindowVisible($e.Host)) {
			$r = New-Object NativeOverlay+RECT
			if ([NativeOverlay]::GetWindowRect($e.Host, [ref]$r)) {
				$w = $r.Right - $r.Left; $h = $r.Bottom - $r.Top
				if ($w -gt 0 -and $h -gt 0) {
					$key = "$($r.Left),$($r.Top),$w,$h"
					if ($key -ne $e.Last) { [void][NativeOverlay]::MoveWindow($e.Gg, $r.Left, $r.Top, $w, $h, $true); $e.Last = $key }
					if ($e.Hidden) { [void][NativeOverlay]::ShowWindow($e.Gg, 8); $e.Hidden = $false }
				}
			}
		} elseif (-not $e.Hidden) {
			[void][NativeOverlay]::ShowWindow($e.Gg, 0); $e.Hidden = $true; $e.Last = ""
		}
	}
	foreach ($d in $dead) { [void]$managed.Remove($d) }
	Start-Sleep -Milliseconds 90
}

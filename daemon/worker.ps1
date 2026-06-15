# appbridge worker - persistent Windows UI Automation engine.
# Speaks line-delimited JSON (NDJSON) over stdin/stdout with the Node daemon.
# stdout: EXACTLY one compact JSON line per request. stderr: free-form logs only.
# No arbitrary-code-execution surface: there is intentionally no eval/run action.

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
[Console]::InputEncoding  = [System.Text.Encoding]::UTF8

Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes
Add-Type -AssemblyName System.Windows.Forms

Add-Type @"
using System;
using System.Runtime.InteropServices;
public class AbWin32 {
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
  [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr hWnd);
  [DllImport("user32.dll")] public static extern bool SetCursorPos(int X, int Y);
  [DllImport("user32.dll")] public static extern void mouse_event(uint a, uint b, uint c, uint d, IntPtr e);
  [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr hWnd, uint Msg, IntPtr wParam, IntPtr lParam);
  [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
  public const uint M_LDOWN = 0x02, M_LUP = 0x04, M_RDOWN = 0x08, M_RUP = 0x10;
  public const uint WM_CLOSE = 0x0010;
  public const int SW_RESTORE = 9;
}
"@

[void][AbWin32]::SetProcessDPIAware()

$AE     = [System.Windows.Automation.AutomationElement]
$Walker = [System.Windows.Automation.TreeWalker]::ControlViewWalker
# NOTE: PowerShell variable names are case-insensitive, so these MUST NOT collide
# with the lowercase locals ($vp, $ip, ...) used at the call sites below.
$PAT_VALUE   = [System.Windows.Automation.ValuePattern]::Pattern
$PAT_INVOKE  = [System.Windows.Automation.InvokePattern]::Pattern
$PAT_TOGGLE  = [System.Windows.Automation.TogglePattern]::Pattern
$PAT_SELITEM = [System.Windows.Automation.SelectionItemPattern]::Pattern
$PAT_EXPAND  = [System.Windows.Automation.ExpandCollapsePattern]::Pattern
$PAT_WINDOW  = [System.Windows.Automation.WindowPattern]::Pattern
$Scope  = [System.Windows.Automation.TreeScope]

$script:Reg      = @{}   # @eN  -> AutomationElement (reset each snapshot)
$script:WinReg   = @{}   # @wN  -> AutomationElement (reset each list_windows)
$script:Sessions = @{}   # session name -> target window AutomationElement
$script:ECount   = 0
$script:WCount   = 0
$script:Shots    = 0

function Log($m) { [Console]::Error.WriteLine("[worker] $m") }

function Get-Arg($req, $name, $def = $null) {
  if ($null -ne $req.args -and ($req.args.PSObject.Properties.Name -contains $name)) {
    return $req.args.$name
  }
  return $def
}

function To-IntPtr($n) { return [IntPtr][int64]$n }

function Get-Pat($el, $pat) {
  $o = $null
  if ($el.TryGetCurrentPattern($pat, [ref]$o)) { return $o }
  return $null
}

function WindowInfo($el, $ref) {
  $c = $el.Current
  $r = $c.BoundingRectangle
  $fg = [AbWin32]::GetForegroundWindow()
  return [ordered]@{
    ref        = $ref
    title      = $c.Name
    class      = $c.ClassName
    pid        = $c.ProcessId
    handle     = [int64]$c.NativeWindowHandle
    bounds     = @{ x = [int]$r.X; y = [int]$r.Y; w = [int]$r.Width; h = [int]$r.Height }
    foreground = ([int64]$c.NativeWindowHandle -eq [int64]$fg)
  }
}

function Find-TopWindow($title) {
  $root = $AE::RootElement
  $kids = $root.FindAll($Scope::Children, [System.Windows.Automation.Condition]::TrueCondition)
  foreach ($k in $kids) {
    try {
      if ($k.Current.Name -and $k.Current.Name.ToLower().Contains($title.ToLower())) { return $k }
    } catch {}
  }
  return $null
}

# Resolve a top-level window element from request args / session.
function Resolve-Window($req) {
  $sel = Get-Arg $req 'window'
  if (-not $sel) { $sel = Get-Arg $req 'selector' }
  $session = if ($req.session) { $req.session } else { 'default' }

  if ($sel -is [string] -and $sel -match '^@w\d+$') {
    if ($script:WinReg.ContainsKey($sel)) { return $script:WinReg[$sel] }
    throw "unknown window ref '$sel' - call list_windows first"
  }
  $handle = Get-Arg $req 'handle'
  if ($handle) { return $AE::FromHandle((To-IntPtr $handle)) }

  $title = Get-Arg $req 'title'
  if ($title) {
    $w = Find-TopWindow $title
    if ($w) { return $w }
    throw "no window matching title '$title'"
  }
  if ($script:Sessions.ContainsKey($session) -and $script:Sessions[$session]) {
    return $script:Sessions[$session]
  }
  $fg = [AbWin32]::GetForegroundWindow()
  if ($fg -ne [IntPtr]::Zero) { return $AE::FromHandle($fg) }
  throw "no target window - pass title/window/handle, or focus a window first"
}

# Resolve an element from an @e / @w ref.
function Resolve-Element($sel) {
  if ($sel -is [string]) {
    if ($sel -match '^@e\d+$') {
      if ($script:Reg.ContainsKey($sel)) { return $script:Reg[$sel] }
      throw "unknown element ref '$sel' - take a fresh snapshot"
    }
    if ($sel -match '^@w\d+$') {
      if ($script:WinReg.ContainsKey($sel)) { return $script:WinReg[$sel] }
      throw "unknown window ref '$sel' - call list_windows first"
    }
  }
  throw "selector must be an @e or @w ref (got '$sel')"
}

function Focus-Window($el) {
  try {
    $h = To-IntPtr $el.Current.NativeWindowHandle
    if ($h -ne [IntPtr]::Zero) {
      if ([AbWin32]::IsIconic($h)) { [void][AbWin32]::ShowWindow($h, [AbWin32]::SW_RESTORE) }
      [void][AbWin32]::SetForegroundWindow($h)
      Start-Sleep -Milliseconds 120
    } else {
      $el.SetFocus()
    }
  } catch { Log "focus failed: $($_.Exception.Message)" }
}

function Element-Center($el) {
  $r = $el.Current.BoundingRectangle
  return @{ x = [int]($r.X + $r.Width / 2); y = [int]($r.Y + $r.Height / 2) }
}

function Pointer-Click($x, $y, $button = 'left') {
  [void][AbWin32]::SetCursorPos([int]$x, [int]$y)
  Start-Sleep -Milliseconds 40
  if ($button -eq 'right') {
    [AbWin32]::mouse_event([AbWin32]::M_RDOWN, 0, 0, 0, [IntPtr]::Zero)
    [AbWin32]::mouse_event([AbWin32]::M_RUP,   0, 0, 0, [IntPtr]::Zero)
  } else {
    [AbWin32]::mouse_event([AbWin32]::M_LDOWN, 0, 0, 0, [IntPtr]::Zero)
    [AbWin32]::mouse_event([AbWin32]::M_LUP,   0, 0, 0, [IntPtr]::Zero)
  }
}

# ---- Snapshot ---------------------------------------------------------------

function Walk-Node($el, $depth, $maxDepth, [ref]$count, $maxCount, $includeOffscreen, $sb) {
  if ($count.Value -ge $maxCount) { return }
  $cur = $null
  try { $cur = $el.Current } catch { return }
  $offscreen = $false
  try { $offscreen = $cur.IsOffscreen } catch {}
  if ($offscreen -and -not $includeOffscreen) { return }

  $script:ECount++
  $ref = "@e$($script:ECount)"
  $script:Reg[$ref] = $el
  $count.Value++

  $ctype = ($cur.ControlType.ProgrammaticName -replace '^ControlType\.', '')
  $name  = $cur.Name
  $autoId = $cur.AutomationId
  $val = $null
  $vp = Get-Pat $el $PAT_VALUE
  if ($vp) { try { $val = $vp.Current.Value } catch {} }

  $label = if ($name) { '"' + ($name -replace '\s+', ' ').Trim() + '"' } elseif ($autoId) { '#' + $autoId } else { '' }
  $line = ('  ' * $depth) + "$ref $ctype $label"
  if ($null -ne $val -and $val -ne '') {
    $v = [string]$val; if ($v.Length -gt 80) { $v = $v.Substring(0, 80) + '...' }
    $line += ' ="' + ($v -replace '\s+', ' ') + '"'
  }
  try { if (-not $cur.IsEnabled) { $line += ' [disabled]' } } catch {}
  [void]$sb.AppendLine($line)

  if ($depth -ge $maxDepth) { return }
  $child = $Walker.GetFirstChild($el)
  while ($null -ne $child -and $count.Value -lt $maxCount) {
    Walk-Node $child ($depth + 1) $maxDepth $count $maxCount $includeOffscreen $sb
    try { $child = $Walker.GetNextSibling($child) } catch { break }
  }
}

function Do-Snapshot($req) {
  $win = Resolve-Window $req
  $session = if ($req.session) { $req.session } else { 'default' }
  $script:Sessions[$session] = $win
  $script:Reg = @{}
  $script:ECount = 0
  $maxDepth = [int](Get-Arg $req 'maxDepth' 40)
  $maxCount = [int](Get-Arg $req 'maxNodes' 400)
  $includeOffscreen = [bool](Get-Arg $req 'includeOffscreen' $false)

  $sb = New-Object System.Text.StringBuilder
  $count = 0
  $cref = [ref]$count
  $cur = $win.Current
  [void]$sb.AppendLine("Window `"$($cur.Name)`" <$($cur.ClassName)> pid=$($cur.ProcessId)")
  $child = $Walker.GetFirstChild($win)
  while ($null -ne $child -and $cref.Value -lt $maxCount) {
    Walk-Node $child 1 $maxDepth $cref $maxCount $includeOffscreen $sb
    try { $child = $Walker.GetNextSibling($child) } catch { break }
  }
  return [ordered]@{
    title     = $cur.Name
    class     = $cur.ClassName
    pid       = $cur.ProcessId
    nodes     = $cref.Value
    truncated = ($cref.Value -ge $maxCount)
    tree      = $sb.ToString().TrimEnd()
  }
}

# ---- Actions ----------------------------------------------------------------

function Do-ListWindows($req) {
  $script:WinReg = @{}
  $script:WCount = 0
  $root = $AE::RootElement
  $kids = $root.FindAll($Scope::Children, [System.Windows.Automation.Condition]::TrueCondition)
  $out = New-Object System.Collections.Generic.List[object]
  foreach ($k in $kids) {
    try {
      $c = $k.Current
      if ([string]::IsNullOrEmpty($c.Name) -and [int64]$c.NativeWindowHandle -eq 0) { continue }
      $script:WCount++
      $ref = "@w$($script:WCount)"
      $script:WinReg[$ref] = $k
      $out.Add((WindowInfo $k $ref))
    } catch {}
  }
  return @{ windows = $out.ToArray() }
}

function Do-FindWindow($req) {
  $title = Get-Arg $req 'title'
  if (-not $title) { $title = Get-Arg $req 'url' }
  if (-not $title) { throw "find_window needs a 'title'" }
  $null = Do-ListWindows $req
  $matches = New-Object System.Collections.Generic.List[object]
  foreach ($kv in $script:WinReg.GetEnumerator()) {
    try {
      $n = $kv.Value.Current.Name
      if ($n -and $n.ToLower().Contains($title.ToLower())) {
        $matches.Add((WindowInfo $kv.Value $kv.Key))
      }
    } catch {}
  }
  if ($matches.Count -eq 0) { throw "no window matching title '$title'" }
  $session = if ($req.session) { $req.session } else { 'default' }
  $best = $matches[0]
  $script:Sessions[$session] = $script:WinReg[$best.ref]
  return @{ matched = $matches.Count; window = $best; all = $matches.ToArray() }
}

function Do-Launch($req) {
  $path = Get-Arg $req 'path'
  if (-not $path) { $path = Get-Arg $req 'app' }
  if (-not $path) { $path = Get-Arg $req 'url' }
  if (-not $path) { throw "launch needs a 'path' (exe / app name / uri)" }
  $pargs = Get-Arg $req 'args'
  $wait  = [int](Get-Arg $req 'waitMs' 1200)
  $p = $null
  if ($pargs) { $p = Start-Process -FilePath $path -ArgumentList $pargs -PassThru }
  else        { $p = Start-Process -FilePath $path -PassThru }
  Start-Sleep -Milliseconds $wait
  $procId = $null; try { $procId = $p.Id } catch {}
  $session = if ($req.session) { $req.session } else { 'default' }
  $bound = $null
  if ($procId) {
    try {
      $root = $AE::RootElement
      $cond = New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::ProcessIdProperty, [int]$procId)
      $w = $root.FindFirst($Scope::Children, $cond)
      if ($w) { $script:Sessions[$session] = $w; $bound = (WindowInfo $w '@w0') }
    } catch {}
  }
  return @{ launched = $true; pid = $procId; window = $bound }
}

function Do-Focus($req) {
  $win = Resolve-Window $req
  Focus-Window $win
  $session = if ($req.session) { $req.session } else { 'default' }
  $script:Sessions[$session] = $win
  return @{ focused = $true; window = (WindowInfo $win '@w0') }
}

function Do-Click($req) {
  $x = Get-Arg $req 'x'; $y = Get-Arg $req 'y'
  $button = Get-Arg $req 'button' 'left'
  if ($null -ne $x -and $null -ne $y) {
    Pointer-Click $x $y $button
    return @{ clicked = $true; via = 'coords'; x = [int]$x; y = [int]$y }
  }
  $sel = Get-Arg $req 'selector'
  if (-not $sel) { throw "click needs a 'selector' (@e/@w ref) or x/y coords" }
  $el = Resolve-Element $sel

  $ip = Get-Pat $el $PAT_INVOKE
  if ($ip) { $ip.Invoke(); return @{ clicked = $true; via = 'invoke' } }
  $tp = Get-Pat $el $PAT_TOGGLE
  if ($tp) { $tp.Toggle(); return @{ clicked = $true; via = 'toggle' } }
  $sip = Get-Pat $el $PAT_SELITEM
  if ($sip) { $sip.Select(); return @{ clicked = $true; via = 'select' } }
  $ecp = Get-Pat $el $PAT_EXPAND
  if ($ecp) {
    if ($ecp.Current.ExpandCollapseState -eq [System.Windows.Automation.ExpandCollapseState]::Expanded) { $ecp.Collapse() } else { $ecp.Expand() }
    return @{ clicked = $true; via = 'expandcollapse' }
  }
  $c = Element-Center $el
  try { $el.SetFocus() } catch {}
  Pointer-Click $c.x $c.y $button
  return @{ clicked = $true; via = 'coords-fallback'; x = $c.x; y = $c.y }
}

function Do-Fill($req) {
  $sel = Get-Arg $req 'selector'
  if (-not $sel) { throw "fill needs a 'selector'" }
  $value = [string](Get-Arg $req 'value' '')
  $el = Resolve-Element $sel
  $vp = Get-Pat $el $PAT_VALUE
  if ($vp -and -not $vp.Current.IsReadOnly) {
    try { $el.SetFocus() } catch {}
    $vp.SetValue($value)
    return @{ filled = $true; mode = 'value' }
  }
  # Fallback for contenteditable / rich editors: focus, select-all, clipboard paste.
  try { $el.SetFocus() } catch {}
  Start-Sleep -Milliseconds 60
  Set-Clipboard -Value $value
  [System.Windows.Forms.SendKeys]::SendWait('^a')
  Start-Sleep -Milliseconds 30
  [System.Windows.Forms.SendKeys]::SendWait('^v')
  return @{ filled = $true; mode = 'clipboard-paste' }
}

function Do-Key($req) {
  $keys = Get-Arg $req 'keys'
  if (-not $keys) { throw "key needs 'keys' (SendKeys syntax: '{ENTER}', '^s', 'hi{TAB}there')" }
  $sel = Get-Arg $req 'selector'
  if ($sel) { try { (Resolve-Element $sel).SetFocus() } catch {} }
  else {
    $win = $null; try { $win = Resolve-Window $req } catch {}
    if ($win) { Focus-Window $win }
  }
  Start-Sleep -Milliseconds 40
  [System.Windows.Forms.SendKeys]::SendWait([string]$keys)
  return @{ sent = $true; keys = [string]$keys }
}

function Do-Screenshot($req) {
  $format = ([string](Get-Arg $req 'format' 'png')).ToLower()
  $quality = [int](Get-Arg $req 'quality' 80)
  $path = Get-Arg $req 'path'
  $sel = Get-Arg $req 'selector'
  $region = Get-Arg $req 'region'
  $raise = [bool](Get-Arg $req 'raise' $true)

  $left = 0; $top = 0; $w = 0; $h = 0
  if ($sel) {
    $el = Resolve-Element $sel
    $r = $el.Current.BoundingRectangle
    $left = [int]$r.X; $top = [int]$r.Y; $w = [int]$r.Width; $h = [int]$r.Height
  } elseif ($region -eq 'screen' -or $region -eq 'fullscreen') {
    $vs = [System.Windows.Forms.SystemInformation]::VirtualScreen
    $left = $vs.X; $top = $vs.Y; $w = $vs.Width; $h = $vs.Height
  } else {
    $win = Resolve-Window $req
    if ($raise) { Focus-Window $win }
    $r = $win.Current.BoundingRectangle
    $left = [int]$r.X; $top = [int]$r.Y; $w = [int]$r.Width; $h = [int]$r.Height
  }
  if ($w -le 0 -or $h -le 0) { throw "capture region has zero size ($w x $h)" }

  if (-not $path) {
    $dir = Join-Path $env:TEMP 'appbridge'
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $script:Shots++
    $ext = if ($format -eq 'jpeg' -or $format -eq 'jpg') { 'jpg' } else { 'png' }
    $path = Join-Path $dir ("shot-$PID-$($script:Shots).$ext")
  } else {
    $parent = Split-Path -Parent $path
    if ($parent -and -not (Test-Path $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
  }

  # The actual grab is delegated to an isolated one-shot child (capture.ps1) so the
  # core engine carries no screen-capture code of its own.
  $cap = Join-Path $PSScriptRoot 'capture.ps1'
  $exe = (Get-Process -Id $PID).Path
  $errFile = [System.IO.Path]::GetTempFileName()
  $out = & $exe -NoProfile -NonInteractive -File $cap -Left $left -Top $top -Width $w -Height $h -Path $path -Format $format -Quality $quality 2>$errFile
  $errText = (Get-Content $errFile -Raw -ErrorAction SilentlyContinue)
  Remove-Item $errFile -ErrorAction SilentlyContinue
  $line = ($out | Where-Object { $_ -match '^\s*\{' } | Select-Object -First 1)
  if (-not $line) { throw "capture failed: $errText $out" }
  $res = $line | ConvertFrom-Json
  $mime = if ($format -eq 'jpeg' -or $format -eq 'jpg') { 'image/jpeg' } else { 'image/png' }
  return @{ path = $res.path; format = $format; width = $w; height = $h; sizeBytes = $res.sizeBytes; mimeType = $mime }
}

function Do-CloseWindow($req) {
  $win = Resolve-Window $req
  $wp = Get-Pat $win $PAT_WINDOW
  if ($wp) { $wp.Close(); return @{ closed = $true; via = 'windowpattern' } }
  $h = To-IntPtr $win.Current.NativeWindowHandle
  if ($h -ne [IntPtr]::Zero) {
    [void][AbWin32]::PostMessage($h, [AbWin32]::WM_CLOSE, [IntPtr]::Zero, [IntPtr]::Zero)
    return @{ closed = $true; via = 'wm_close' }
  }
  throw "cannot close: no window pattern or native handle"
}

function Dispatch($req) {
  switch ($req.action) {
    'ping'         { return @{ pong = $true } }
    'list_windows' { return (Do-ListWindows $req) }
    'find_window'  { return (Do-FindWindow $req) }
    'launch'       { return (Do-Launch $req) }
    'focus'        { return (Do-Focus $req) }
    'snapshot'     { return (Do-Snapshot $req) }
    'click'        { return (Do-Click $req) }
    'fill'         { return (Do-Fill $req) }
    'key'          { return (Do-Key $req) }
    'screenshot'   { return (Do-Screenshot $req) }
    'close_window' { return (Do-CloseWindow $req) }
    default        { throw "unknown action '$($req.action)'" }
  }
}

Log "ready (pid $PID)"

while ($true) {
  $line = [Console]::In.ReadLine()
  if ($null -eq $line) { break }
  if ([string]::IsNullOrWhiteSpace($line)) { continue }
  $reqId = 0
  try {
    $req = $line | ConvertFrom-Json
    if ($null -ne $req.id) { $reqId = $req.id }
    $data = Dispatch $req
    $resp = @{ id = $reqId; ok = $true; data = $data }
  } catch {
    $resp = @{ id = $reqId; ok = $false; error = "$($_.Exception.Message)" }
    Log "error: $($_.Exception.Message)"
  }
  $json = $resp | ConvertTo-Json -Compress -Depth 25
  [Console]::Out.WriteLine($json)
  [Console]::Out.Flush()
}
Log "stdin closed, exiting"

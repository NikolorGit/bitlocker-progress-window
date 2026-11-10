# BitLocker progress window for drive C:
# Shows percentage, progress bar, speed, time left, disk activity and a history chart.
# Needs admin to read BitLocker status: it asks once (UAC) when started normally.
# Read-only: it never pauses, resumes or changes encryption. Closing it changes nothing.
# Use -Demo to preview with fake data (no admin needed).

param([switch]$Demo)

$ErrorActionPreference = 'Stop'
$inv = [Globalization.CultureInfo]::InvariantCulture

# Relaunch as admin (one UAC prompt) unless in demo mode
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $Demo -and -not $isAdmin) {
    Start-Process powershell.exe -Verb RunAs -WindowStyle Hidden -ArgumentList "-NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File `"$PSCommandPath`""
    exit
}

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase

$histFile = Join-Path $PSScriptRoot 'history.csv'
$refreshSec = if ($Demo) { 1 } else { 15 }

[xml]$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="BitLocker progress" Width="580" Height="540" ResizeMode="CanMinimize"
        WindowStartupLocation="CenterScreen" Background="#0F1216" FontFamily="Segoe UI">
  <Grid Margin="28,22,28,18">
    <Grid.RowDefinitions>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="*"/>
      <RowDefinition Height="Auto"/>
    </Grid.RowDefinitions>

    <DockPanel Grid.Row="0">
      <TextBlock Text="BITLOCKER  /  DRIVE C:" Foreground="#7C8794" FontSize="12" FontWeight="SemiBold" VerticalAlignment="Center"/>
      <Border x:Name="Pill" HorizontalAlignment="Right" CornerRadius="10" Padding="10,3" Background="#1E3A34">
        <TextBlock x:Name="Status" Text="Starting..." Foreground="#5EEAD4" FontSize="12" FontWeight="SemiBold"/>
      </Border>
    </DockPanel>

    <Grid Grid.Row="1" Margin="0,6,0,0">
      <TextBlock x:Name="Pct" Text="--" Foreground="White" FontSize="64" FontWeight="Bold"/>
      <TextBlock x:Name="Sub" Text="" Foreground="#9AA5B1" FontSize="14" HorizontalAlignment="Right" VerticalAlignment="Bottom" Margin="0,0,0,14"/>
    </Grid>

    <Border x:Name="Track" Grid.Row="2" Height="12" CornerRadius="6" Background="#232A33">
      <Border x:Name="Fill" HorizontalAlignment="Left" Width="0" CornerRadius="6">
        <Border.Background>
          <LinearGradientBrush StartPoint="0,0" EndPoint="1,0">
            <GradientStop Color="#2DD4BF" Offset="0"/>
            <GradientStop Color="#22C55E" Offset="1"/>
          </LinearGradientBrush>
        </Border.Background>
      </Border>
    </Border>

    <UniformGrid Grid.Row="3" Columns="3" Margin="-5,18,-5,0">
      <Border Background="#171C22" CornerRadius="10" Padding="14,12" Margin="5,0">
        <StackPanel>
          <TextBlock Text="SPEED" Foreground="#7C8794" FontSize="11" FontWeight="SemiBold"/>
          <TextBlock x:Name="SpeedVal" Text="--" Foreground="White" FontSize="20" FontWeight="SemiBold" Margin="0,4,0,0"/>
          <TextBlock x:Name="SpeedSub" Text="measuring..." Foreground="#7C8794" FontSize="11"/>
        </StackPanel>
      </Border>
      <Border Background="#171C22" CornerRadius="10" Padding="14,12" Margin="5,0">
        <StackPanel>
          <TextBlock Text="TIME LEFT" Foreground="#7C8794" FontSize="11" FontWeight="SemiBold"/>
          <TextBlock x:Name="EtaVal" Text="--" Foreground="White" FontSize="20" FontWeight="SemiBold" Margin="0,4,0,0"/>
          <TextBlock x:Name="EtaSub" Text="measuring..." Foreground="#7C8794" FontSize="11"/>
        </StackPanel>
      </Border>
      <Border Background="#171C22" CornerRadius="10" Padding="14,12" Margin="5,0">
        <StackPanel>
          <TextBlock Text="DISK ACTIVITY" Foreground="#7C8794" FontSize="11" FontWeight="SemiBold"/>
          <TextBlock x:Name="DiskVal" Text="--" Foreground="White" FontSize="20" FontWeight="SemiBold" Margin="0,4,0,0"/>
          <TextBlock x:Name="DiskSub" Text="" Foreground="#7C8794" FontSize="11"/>
        </StackPanel>
      </Border>
    </UniformGrid>

    <Border Grid.Row="4" Background="#171C22" CornerRadius="10" Padding="14,12" Margin="0,12,0,0">
      <Grid>
        <Grid.RowDefinitions>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="*"/>
          <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>
        <DockPanel>
          <TextBlock Text="PROGRESS HISTORY" Foreground="#7C8794" FontSize="11" FontWeight="SemiBold"/>
          <TextBlock x:Name="ChartRange" HorizontalAlignment="Right" Foreground="#5B6672" FontSize="11"/>
        </DockPanel>
        <Canvas x:Name="Chart" Grid.Row="1" Margin="0,8,0,4" ClipToBounds="True"/>
        <DockPanel Grid.Row="2">
          <TextBlock x:Name="ChartFrom" Foreground="#5B6672" FontSize="11"/>
          <TextBlock x:Name="ChartTo" HorizontalAlignment="Right" Foreground="#5B6672" FontSize="11"/>
        </DockPanel>
      </Grid>
    </Border>

    <TextBlock x:Name="Foot" Grid.Row="5" Foreground="#5B6672" FontSize="11" Margin="0,10,0,0" TextWrapping="Wrap"/>
  </Grid>
</Window>
'@

$win = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $xaml))
$ui = @{}
foreach ($n in 'Pill','Status','Pct','Sub','Track','Fill','SpeedVal','SpeedSub','EtaVal','EtaSub','DiskVal','DiskSub','Chart','ChartRange','ChartFrom','ChartTo','Foot') { $ui[$n] = $win.FindName($n) }
$bc = New-Object Windows.Media.BrushConverter
function Brush([string]$hex) { $bc.ConvertFromString($hex) }

# ---- history ----
$script:history = New-Object System.Collections.Generic.List[object]
if ($Demo) {
    $t0 = (Get-Date).AddMinutes(-45)
    for ($i = 0; $i -le 90; $i++) { $script:history.Add([pscustomobject]@{ T = $t0.AddSeconds(30 * $i); P = 10.0 + 0.09 * $i + (Get-Random -Minimum 0 -Maximum 3) / 100 }) }
    $script:demoP = $script:history[-1].P
} elseif (Test-Path $histFile) {
    $cut = (Get-Date).AddHours(-24)
    foreach ($line in Get-Content $histFile) {
        $p = $line -split ','
        if ($p.Count -ne 2) { continue }
        try {
            $t = [datetime]::ParseExact($p[0], 'yyyy-MM-ddTHH:mm:ss', $inv)
            if ($t -ge $cut) { $script:history.Add([pscustomobject]@{ T = $t; P = [double]::Parse($p[1], $inv) }) }
        } catch {}
    }
}

# ---- disk counters ----
$script:diskBytes = $null; $script:diskIdle = $null
try {
    # The physical disk that holds C: (instance names look like "1 c:")
    $inst = (New-Object Diagnostics.PerformanceCounterCategory 'PhysicalDisk').GetInstanceNames() | Where-Object { $_ -match '(^|\s)c:' } | Select-Object -First 1
    if (-not $inst) { $inst = '_Total' }
    $script:diskBytes = New-Object Diagnostics.PerformanceCounter('PhysicalDisk', 'Disk Bytes/sec', $inst)
    $script:diskIdle  = New-Object Diagnostics.PerformanceCounter('PhysicalDisk', '% Idle Time', $inst)
    [void]$script:diskBytes.NextValue(); [void]$script:diskIdle.NextValue()
} catch {}

function Read-State {
    if ($Demo) {
        $script:demoP = [math]::Min(100, $script:demoP + 0.05)
        return [pscustomobject]@{ Percent = $script:demoP; Status = 'Encryption Paused'; SizeGB = 1906.43 }
    }
    $out = & manage-bde.exe -status C: 2>&1 | Out-String
    $pct  = [regex]::Match($out, 'Percentage Encrypted:\s*([\d.,]+)')
    $stat = [regex]::Match($out, 'Conversion Status:\s*(.+)')
    $size = [regex]::Match($out, 'Size:\s*([\d.,]+)\s*GB')
    if (-not $pct.Success) { throw "Could not read BitLocker status" }
    [pscustomobject]@{
        Percent = [double]::Parse(($pct.Groups[1].Value -replace ',', '.'), $inv)
        Status  = $stat.Groups[1].Value.Trim()
        SizeGB  = if ($size.Success) { [double]::Parse(($size.Groups[1].Value -replace ',', '.'), $inv) } else { 0 }
    }
}

# Percent per minute over the last 15 minutes (null if not moving)
function Get-Rate {
    $now = Get-Date
    $w = @($script:history | Where-Object { $_.T -ge $now.AddMinutes(-15) })
    if ($w.Count -lt 2) { return $null }
    $min = ($w[-1].T - $w[0].T).TotalMinutes
    if ($min -lt 1 -or $w[-1].P -le $w[0].P) { return $null }
    ($w[-1].P - $w[0].P) / $min
}

function Format-Duration([double]$minutes) {
    $ts = [TimeSpan]::FromMinutes($minutes)
    if ($ts.TotalHours -ge 1) { '{0}h {1:D2}m' -f [int][math]::Floor($ts.TotalHours), $ts.Minutes } else { '{0} min' -f [int][math]::Ceiling($ts.TotalMinutes) }
}

function Draw-Chart {
    $c = $ui.Chart; $c.Children.Clear()
    $w = $c.ActualWidth; $h = $c.ActualHeight
    $pts = $script:history.ToArray()
    if ($pts.Count -lt 2 -or $w -le 0 -or $h -le 0) {
        $tb = New-Object Windows.Controls.TextBlock -Property @{ Text = 'Collecting data...'; Foreground = (Brush '#5B6672'); FontSize = 12 }
        [Windows.Controls.Canvas]::SetLeft($tb, 0); [Windows.Controls.Canvas]::SetTop($tb, 4); [void]$c.Children.Add($tb)
        return
    }
    $t0 = $pts[0].T; $t1 = $pts[-1].T
    $span = [math]::Max(1, ($t1 - $t0).TotalSeconds)
    $pMin = ($pts | Measure-Object P -Minimum).Minimum
    $pMax = ($pts | Measure-Object P -Maximum).Maximum
    $pad = [math]::Max(0.5, ($pMax - $pMin) * 0.1)
    $lo = [math]::Max(0, $pMin - $pad); $hi = [math]::Min(100, $pMax + $pad)
    if ($hi - $lo -lt 1) { $hi = $lo + 1 }

    # light grid lines
    foreach ($f in 0.25, 0.5, 0.75) {
        $gl = New-Object Windows.Shapes.Line -Property @{ X1 = 0; X2 = $w; Y1 = $h * $f; Y2 = $h * $f; Stroke = (Brush '#222932'); StrokeThickness = 1 }
        [void]$c.Children.Add($gl)
    }

    $line = New-Object Windows.Media.PointCollection
    $area = New-Object Windows.Media.PointCollection
    $area.Add((New-Object Windows.Point 0, $h))
    foreach ($p in $pts) {
        $x = ($p.T - $t0).TotalSeconds / $span * $w
        $y = $h - (($p.P - $lo) / ($hi - $lo)) * $h
        $pt = New-Object Windows.Point $x, $y
        $line.Add($pt); $area.Add($pt)
    }
    $area.Add((New-Object Windows.Point $w, $h))

    $fillBrush = New-Object Windows.Media.LinearGradientBrush
    $fillBrush.StartPoint = '0,0'; $fillBrush.EndPoint = '0,1'
    $fillBrush.GradientStops.Add((New-Object Windows.Media.GradientStop ([Windows.Media.Color]::FromArgb(90, 45, 212, 191)), 0))
    $fillBrush.GradientStops.Add((New-Object Windows.Media.GradientStop ([Windows.Media.Color]::FromArgb(0, 45, 212, 191)), 1))
    [void]$c.Children.Add((New-Object Windows.Shapes.Polygon -Property @{ Points = $area; Fill = $fillBrush }))
    [void]$c.Children.Add((New-Object Windows.Shapes.Polyline -Property @{ Points = $line; Stroke = (Brush '#2DD4BF'); StrokeThickness = 2 }))

    $last = $line[$line.Count - 1]
    $dot = New-Object Windows.Shapes.Ellipse -Property @{ Width = 8; Height = 8; Fill = (Brush '#5EEAD4') }
    [Windows.Controls.Canvas]::SetLeft($dot, $last.X - 4); [Windows.Controls.Canvas]::SetTop($dot, $last.Y - 4)
    [void]$c.Children.Add($dot)

    $ui.ChartFrom.Text = $t0.ToString('HH:mm')
    $ui.ChartTo.Text = 'now'
    $ui.ChartRange.Text = ('{0:N1}% - {1:N1}%' -f $lo, $hi)
}

function Set-Pill([string]$text, [string]$bg, [string]$fg) {
    $ui.Status.Text = $text; $ui.Pill.Background = (Brush $bg); $ui.Status.Foreground = (Brush $fg)
}

$script:lastState = $null
function Update {
    try {
        $s = Read-State
        $script:lastState = $s
        $now = Get-Date
        $script:history.Add([pscustomobject]@{ T = $now; P = $s.Percent })
        while ($script:history.Count -gt 0 -and $script:history[0].T -lt $now.AddHours(-24)) { $script:history.RemoveAt(0) }
        if (-not $Demo) { Add-Content -Path $histFile -Value ('{0},{1}' -f $now.ToString('yyyy-MM-ddTHH:mm:ss', $inv), $s.Percent.ToString($inv)) }

        $ui.Pct.Text = ('{0:N1}%' -f $s.Percent)
        if ($s.SizeGB -gt 0) { $ui.Sub.Text = ('{0:N0} of {1:N0} GB encrypted' -f ($s.SizeGB * $s.Percent / 100), $s.SizeGB) }

        $rate = Get-Rate
        if ($s.Status -match 'Fully Encrypted' -or $s.Percent -ge 100) {
            Set-Pill 'Finished' '#14532D' '#86EFAC'
            $ui.EtaVal.Text = 'Done'; $ui.EtaSub.Text = 'drive C: is encrypted'
            $ui.SpeedVal.Text = '--'; $ui.SpeedSub.Text = 'nothing left to do'
        } else {
            if ($s.Status -match 'Paused' -and $rate) { Set-Pill 'Encrypting (says paused)' '#3B2F14' '#FCD34D' }
            elseif ($s.Status -match 'Paused')        { Set-Pill 'Paused' '#2A2F36' '#CBD5E1' }
            else                                      { Set-Pill 'Encrypting' '#1E3A34' '#5EEAD4' }

            if ($rate) {
                $gbMin = $rate / 100 * $s.SizeGB
                $ui.SpeedVal.Text = ('{0:N1} GB/min' -f $gbMin)
                $ui.SpeedSub.Text = ('{0:N1}% per hour' -f ($rate * 60))
                $left = (100 - $s.Percent) / $rate
                $ui.EtaVal.Text = (Format-Duration $left)
                $fin = $now.AddMinutes($left)
                $day = if ($fin.Date -eq $now.Date) { 'today' } elseif ($fin.Date -eq $now.Date.AddDays(1)) { 'tomorrow' } else { $fin.ToString('MMM d') }
                $ui.EtaSub.Text = ('done ~{0} {1}' -f $fin.ToString('HH:mm'), $day)
            } else {
                $ui.SpeedVal.Text = '--'; $ui.SpeedSub.Text = if ($script:history.Count -lt 3) { 'measuring...' } else { 'not moving' }
                $ui.EtaVal.Text = '--';  $ui.EtaSub.Text = if ($script:history.Count -lt 3) { 'needs ~1 min of data' } else { 'waiting for progress' }
            }
        }

        $fillW = $ui.Track.ActualWidth * [math]::Min(100, $s.Percent) / 100
        $ui.Fill.Width = [math]::Max(0, $fillW)

        if ($script:diskBytes) {
            $mb = $script:diskBytes.NextValue() / 1MB
            $busy = 100 - [math]::Min(100, $script:diskIdle.NextValue())
            $ui.DiskVal.Text = ('{0:N0} MB/s' -f $mb)
            $ui.DiskSub.Text = ('drive C: {0:N0}% busy' -f $busy)
        } else { $ui.DiskVal.Text = 'n/a' }

        Draw-Chart
        $ui.Foot.Text = ('Updated {0}  -  refreshes every {1} s  -  read-only, closing this window does not affect encryption' -f $now.ToString('HH:mm:ss'), $refreshSec)
        if ($Demo) { $ui.Foot.Text = 'DEMO MODE (fake data)  -  ' + $ui.Foot.Text }
    } catch {
        $ui.Foot.Text = 'Error: ' + $_.Exception.Message + ' (line ' + $_.InvocationInfo.ScriptLineNumber + ': ' + $_.InvocationInfo.Line.Trim() + ')'
    }
}

$timer = New-Object Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromSeconds($refreshSec)
$timer.Add_Tick({ Update })
$win.Add_ContentRendered({ Update; $timer.Start() })
$ui.Track.Add_SizeChanged({ if ($script:lastState) { $ui.Fill.Width = $ui.Track.ActualWidth * [math]::Min(100, $script:lastState.Percent) / 100 } })
$win.Add_Closed({ $timer.Stop() })
[void]$win.ShowDialog()

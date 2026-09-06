# ---------------------------------------------------------------------------
# The window.
#
# It is not a second description of what the script does - it renders the
# manifest a dry run produced, which is the same data the apply step consumes.
# Every row is a real planned change with its current and proposed value, so the
# interface cannot drift from the code.
#
# Two implementation rules learned the hard way:
#
#   1. No GetNewClosure(). Shared state lives in $script:Gui* and handlers call
#      named functions. Closures over mutable locals silently captured stale
#      copies, so switching phase did nothing and presets threw.
#
#   2. A checkbox handler NEVER rebuilds the list it lives in. Clearing a panel
#      from inside the click event of one of its own children tears down the
#      element mid-event and takes the window with it. Ticking a box updates the
#      counts only; the list is rebuilt for navigation and presets, which happen
#      from the sidebar and toolbar.
# ---------------------------------------------------------------------------

$script:GuiXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Trim" Height="770" Width="1160" MinHeight="620" MinWidth="940"
        WindowStartupLocation="CenterScreen" Background="#171C1B"
        TextOptions.TextFormattingMode="Display" UseLayoutRounding="True">
  <Window.Resources>
    <SolidColorBrush x:Key="Panel"  Color="#1E2524"/>
    <SolidColorBrush x:Key="Raise"  Color="#263130"/>
    <SolidColorBrush x:Key="Rule"   Color="#2E3937"/>
    <SolidColorBrush x:Key="Ink"    Color="#E6EDEB"/>
    <SolidColorBrush x:Key="Soft"   Color="#98A6A3"/>
    <!-- Was #6C7A77, which measured 3.85:1 on the window and 3.0:1 on a raised
         panel - under AA, on the secondary line of every single row. Dim is a
         style; unreadable is a defect. #8C9A97 clears 4.5:1 everywhere.
         The panes kept their own hardcoded copies of the old value long after
         this was fixed here, because the guard only ever checked the palette.
         There is one grey now, and the guard checks every use of it. -->
    <SolidColorBrush x:Key="Faint"  Color="#8C9A97"/>

    <SolidColorBrush x:Key="Accent" Color="#46C6B0"/>

    <Style TargetType="TextBlock">
      <Setter Property="Foreground" Value="{StaticResource Ink}"/>
      <Setter Property="FontFamily" Value="Segoe UI Variable Text, Segoe UI"/>
      <Setter Property="FontSize" Value="13"/>
    </Style>

    <Style x:Key="Btn" TargetType="Button">
      <Setter Property="Foreground" Value="{StaticResource Ink}"/>
      <Setter Property="Background" Value="{StaticResource Raise}"/>
      <Setter Property="BorderBrush" Value="{StaticResource Rule}"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="Padding" Value="13,6"/>
      <Setter Property="FontFamily" Value="Segoe UI Variable Text, Segoe UI"/>
      <Setter Property="FontSize" Value="13"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="b" Background="{TemplateBinding Background}"
                    BorderBrush="{TemplateBinding BorderBrush}"
                    BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="4">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"
                                Margin="{TemplateBinding Padding}"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="b" Property="BorderBrush" Value="{StaticResource Faint}"/>
              </Trigger>
              <!-- A custom template replaces the focus adorner, so somebody
                   tabbing through had no way to see where they were. -->
              <Trigger Property="IsKeyboardFocused" Value="True">
                <Setter TargetName="b" Property="BorderBrush" Value="{StaticResource Accent}"/>
                <Setter TargetName="b" Property="BorderThickness" Value="2"/>
              </Trigger>
              <Trigger Property="IsEnabled" Value="False">
                <Setter Property="Opacity" Value="0.4"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="Nav" TargetType="Button" BasedOn="{StaticResource Btn}">
      <Setter Property="HorizontalContentAlignment" Value="Stretch"/>
      <Setter Property="FontWeight" Value="Normal"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="b" Background="{TemplateBinding Background}"
                    BorderBrush="{TemplateBinding BorderBrush}"
                    BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="3">
              <ContentPresenter HorizontalAlignment="Stretch" VerticalAlignment="Center"
                                Margin="{TemplateBinding Padding}"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="b" Property="Background" Value="#263130"/>
              </Trigger>
              <Trigger Property="IsKeyboardFocused" Value="True">
                <Setter TargetName="b" Property="BorderBrush" Value="{StaticResource Accent}"/>
                <Setter TargetName="b" Property="BorderThickness" Value="1.5"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="Primary" TargetType="Button" BasedOn="{StaticResource Btn}">
      <Setter Property="Background" Value="{StaticResource Accent}"/>
      <Setter Property="BorderBrush" Value="{StaticResource Accent}"/>
      <Setter Property="Foreground" Value="#06211D"/>
      <Setter Property="Padding" Value="20,7"/>
    </Style>

    <!-- The tick used to float free in the 21x21 grid and centre itself on its
         own geometry bounds, which put it a fraction high and left of the box
         it belonged to. It is now the box's child, so it is centred on the box
         by layout rather than by coincidence. -->
    <Style TargetType="CheckBox">
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="SnapsToDevicePixels" Value="True"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="CheckBox">
            <Grid Width="24" Height="24" Background="Transparent">
              <!-- Outside the box, so showing it cannot resize the box. -->
              <Border x:Name="focus" CornerRadius="7" Background="Transparent"
                      BorderBrush="{StaticResource Accent}" BorderThickness="1.5"
                      Visibility="Collapsed"/>
              <Border x:Name="box" Width="18" Height="18" CornerRadius="4"
                      Background="#141918" BorderBrush="#5D6E6B" BorderThickness="1.5"
                      HorizontalAlignment="Center" VerticalAlignment="Center"
                      SnapsToDevicePixels="True">
                <Path x:Name="tick" Visibility="Collapsed"
                      HorizontalAlignment="Center" VerticalAlignment="Center"
                      Margin="0,0.5,0,0"
                      Data="M 0,4.6 L 3.6,8.2 L 9.6,0.8"
                      Stroke="#06211D" StrokeThickness="2"
                      StrokeStartLineCap="Round" StrokeEndLineCap="Round" StrokeLineJoin="Round"/>
              </Border>
            </Grid>
            <ControlTemplate.Triggers>
              <!-- BorderThickness goes to zero, not to the same colour as the
                   fill. A Border draws its background and its border as two
                   pieces of geometry; the straight edges snap to the pixel
                   grid and meet invisibly, but the rounded corners cannot, so
                   an equal-coloured border left four faint arcs inside every
                   ticked box. One layer has no seam to show. -->
              <Trigger Property="IsChecked" Value="True">
                <Setter TargetName="box"  Property="Background"      Value="#46C6B0"/>
                <Setter TargetName="box"  Property="BorderThickness" Value="0"/>
                <Setter TargetName="tick" Property="Visibility"      Value="Visible"/>
              </Trigger>
              <!-- Unticked: the border answers. Ticked: the border is already
                   the accent, so brightening the fill is the only move left
                   that reads as a response to the pointer. -->
              <MultiTrigger>
                <MultiTrigger.Conditions>
                  <Condition Property="IsMouseOver" Value="True"/>
                  <Condition Property="IsChecked"   Value="False"/>
                </MultiTrigger.Conditions>
                <Setter TargetName="box" Property="BorderBrush" Value="{StaticResource Accent}"/>
                <Setter TargetName="box" Property="Background"  Value="#1B2422"/>
              </MultiTrigger>
              <MultiTrigger>
                <MultiTrigger.Conditions>
                  <Condition Property="IsMouseOver" Value="True"/>
                  <Condition Property="IsChecked"   Value="True"/>
                </MultiTrigger.Conditions>
                <Setter TargetName="box" Property="Background"      Value="#5AD6C0"/>
                <Setter TargetName="box" Property="BorderThickness" Value="0"/>
              </MultiTrigger>
              <Trigger Property="IsKeyboardFocused" Value="True">
                <Setter TargetName="focus" Property="Visibility" Value="Visible"/>
              </Trigger>
              <Trigger Property="IsEnabled" Value="False">
                <Setter Property="Opacity" Value="0.4"/>
                <Setter Property="Cursor"  Value="Arrow"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <!-- Scroll bars.
         The default WPF one is the Aero 2 chrome: 17px wide, a grey track, a
         raised grey thumb and a stepper button at each end. It is the oldest
         looking thing on the window by about fifteen years, and on a dark
         panel the light track reads as a seam down the edge.
         This is a 10px transparent gutter with a rounded thumb, no steppers.
         The paging areas are kept - they are invisible, but clicking above or
         below the thumb still pages, which is behaviour people rely on. -->
    <Style x:Key="ScrollPage" TargetType="RepeatButton">
      <Setter Property="Focusable" Value="False"/>
      <Setter Property="IsTabStop" Value="False"/>
      <Setter Property="OverridesDefaultStyle" Value="True"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="RepeatButton">
            <!-- Transparent, not null: a null background is not hit-testable
                 and paging would silently stop working. -->
            <Border Background="Transparent"/>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="ScrollThumb" TargetType="Thumb">
      <Setter Property="OverridesDefaultStyle" Value="True"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Thumb">
            <!-- 2px all round, so the same thumb works in either orientation
                 and the bar reads as a gutter rather than a bar. -->
            <Border x:Name="t" CornerRadius="3" Background="#3B4746" Margin="2"/>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="t" Property="Background" Value="#556765"/>
              </Trigger>
              <Trigger Property="IsDragging" Value="True">
                <Setter TargetName="t" Property="Background" Value="{StaticResource Accent}"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style TargetType="ScrollBar">
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="Width" Value="10"/>
      <Setter Property="MinWidth" Value="10"/>
      <Setter Property="OverridesDefaultStyle" Value="True"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ScrollBar">
            <Grid Background="Transparent">
              <Track x:Name="PART_Track" IsDirectionReversed="True">
                <Track.DecreaseRepeatButton>
                  <RepeatButton Style="{StaticResource ScrollPage}" Command="ScrollBar.PageUpCommand"/>
                </Track.DecreaseRepeatButton>
                <Track.Thumb>
                  <Thumb Style="{StaticResource ScrollThumb}"/>
                </Track.Thumb>
                <Track.IncreaseRepeatButton>
                  <RepeatButton Style="{StaticResource ScrollPage}" Command="ScrollBar.PageDownCommand"/>
                </Track.IncreaseRepeatButton>
              </Track>
            </Grid>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
      <Style.Triggers>
        <Trigger Property="Orientation" Value="Horizontal">
          <Setter Property="Width"     Value="Auto"/>
          <Setter Property="MinWidth"  Value="0"/>
          <Setter Property="Height"    Value="10"/>
          <Setter Property="MinHeight" Value="10"/>
          <Setter Property="Template">
            <Setter.Value>
              <ControlTemplate TargetType="ScrollBar">
                <Grid Background="Transparent">
                  <Track x:Name="PART_Track" IsDirectionReversed="False">
                    <Track.DecreaseRepeatButton>
                      <RepeatButton Style="{StaticResource ScrollPage}" Command="ScrollBar.PageLeftCommand"/>
                    </Track.DecreaseRepeatButton>
                    <Track.Thumb>
                      <Thumb Style="{StaticResource ScrollThumb}"/>
                    </Track.Thumb>
                    <Track.IncreaseRepeatButton>
                      <RepeatButton Style="{StaticResource ScrollPage}" Command="ScrollBar.PageRightCommand"/>
                    </Track.IncreaseRepeatButton>
                  </Track>
                </Grid>
              </ControlTemplate>
            </Setter.Value>
          </Setter>
        </Trigger>
      </Style.Triggers>
    </Style>
  </Window.Resources>

  <Grid>
    <Grid.RowDefinitions>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="*"/>
      <RowDefinition Height="Auto"/>
    </Grid.RowDefinitions>

    <!-- header: mark, wordmark, one line saying what this is -->
    <Border Grid.Row="0" Background="{StaticResource Panel}" BorderBrush="{StaticResource Rule}"
            BorderThickness="0,0,0,1" Padding="16,12">
      <Grid>
        <StackPanel Orientation="Horizontal">
          <!-- The mark: three bars cut shorter each time. Reduction, in a shape
               that still reads at 16 pixels. -->
          <Canvas Width="26" Height="26" Margin="0,0,12,0" VerticalAlignment="Center">
            <Rectangle Canvas.Left="1" Canvas.Top="3"  Width="24" Height="4.5" RadiusX="2.25" RadiusY="2.25" Fill="#46C6B0"/>
            <Rectangle Canvas.Left="1" Canvas.Top="10.5" Width="16" Height="4.5" RadiusX="2.25" RadiusY="2.25" Fill="#46C6B0" Opacity="0.72"/>
            <Rectangle Canvas.Left="1" Canvas.Top="18" Width="9"  Height="4.5" RadiusX="2.25" RadiusY="2.25" Fill="#46C6B0" Opacity="0.45"/>
          </Canvas>
          <StackPanel VerticalAlignment="Center">
            <TextBlock Text="Trim" FontSize="19" FontWeight="Bold"/>
            <TextBlock x:Name="TxtMachine" Foreground="{StaticResource Faint}" FontSize="11.5" Margin="0,1,0,0"/>
          </StackPanel>
        </StackPanel>
        <TextBlock HorizontalAlignment="Right" VerticalAlignment="Center" TextAlignment="Right"
                   Foreground="{StaticResource Soft}" FontSize="12" LineHeight="17"
                   Text="Nothing is changed until you press Apply.&#x0a;A restore point is taken first where Windows allows one, and every change is written down so it can be undone."/>
      </Grid>
    </Border>

    <!-- toolbar -->
    <Border Grid.Row="1" BorderBrush="{StaticResource Rule}" BorderThickness="0,0,0,1" Padding="16,9">
      <Grid>
        <StackPanel Orientation="Horizontal">
          <TextBlock Text="Preset" Foreground="{StaticResource Faint}" FontSize="12"
                     VerticalAlignment="Center" Margin="0,0,10,0"/>
          <Button x:Name="BtnRecommended" Style="{StaticResource Btn}" Content="Recommended" Margin="0,0,6,0"/>
          <Button x:Name="BtnAdvanced" Style="{StaticResource Btn}" Content="Advanced" Margin="0,0,6,0"/>
          <Button x:Name="BtnEverything" Style="{StaticResource Btn}" Content="Everything" Margin="0,0,6,0"/>
          <Button x:Name="BtnClear" Style="{StaticResource Btn}" Content="Clear"/>
        </StackPanel>
        <TextBlock x:Name="TxtPresetHint" HorizontalAlignment="Right" VerticalAlignment="Center"
                   Foreground="{StaticResource Faint}" FontSize="12"/>
      </Grid>
    </Border>

    <!-- body -->
    <Grid Grid.Row="2">
      <Grid.ColumnDefinitions>
        <ColumnDefinition Width="222"/>
        <ColumnDefinition Width="*"/>
      </Grid.ColumnDefinitions>

      <Border Grid.Column="0" Background="{StaticResource Panel}" BorderBrush="{StaticResource Rule}" BorderThickness="0,0,1,0">
        <ScrollViewer VerticalScrollBarVisibility="Auto">
          <StackPanel x:Name="PanelPhases" Margin="8,10"/>
        </ScrollViewer>
      </Border>

      <Grid Grid.Column="1">
        <Grid.RowDefinitions>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="*"/>
        </Grid.RowDefinitions>
        <Border Grid.Row="0" Padding="18,14,18,8">
          <Grid>
            <TextBlock x:Name="TxtPhase" FontSize="17" FontWeight="SemiBold"/>
            <TextBlock x:Name="TxtPhaseSub" HorizontalAlignment="Right" VerticalAlignment="Center"
                       Foreground="{StaticResource Faint}" FontSize="12"/>
          </Grid>
        </Border>
        <Border x:Name="BannerBox" Grid.Row="1" Margin="18,0,18,10" Padding="11,9"
                Background="#2A1712" BorderBrush="#E4785C" BorderThickness="1" CornerRadius="4"
                Visibility="Collapsed">
          <TextBlock x:Name="TxtBanner" Foreground="#F0BCAB" FontSize="12" TextWrapping="Wrap"/>
        </Border>
        <ScrollViewer x:Name="ItemScroll" Grid.Row="2" VerticalScrollBarVisibility="Auto" Padding="12,0,8,12">
          <StackPanel x:Name="PanelItems" Margin="6,0"/>
        </ScrollViewer>
      </Grid>
    </Grid>

    <!-- footer -->
    <Border Grid.Row="3" Background="{StaticResource Panel}" BorderBrush="{StaticResource Rule}" BorderThickness="0,1,0,0" Padding="16,11">
      <Grid>
        <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
          <TextBlock x:Name="TxtCount" FontWeight="SemiBold" FontSize="14"/>
          <TextBlock x:Name="TxtNote" Foreground="{StaticResource Faint}" FontSize="12" Margin="12,0,0,0" VerticalAlignment="Center"/>
        </StackPanel>
        <StackPanel Orientation="Horizontal" HorizontalAlignment="Right">
          <Button x:Name="BtnCancel" Style="{StaticResource Btn}" Content="Close" Margin="0,0,8,0"/>
          <Button x:Name="BtnApply" Style="{StaticResource Primary}" Content="Apply"/>
        </StackPanel>
      </Grid>
    </Border>

    <!-- The credit lives at the foot of the Overview, not on every screen. -->
  </Grid>
</Window>
'@

# ---------------------------------------------------------------------------
#  Shared state. Named, script-scoped, and never captured into a closure.
# ---------------------------------------------------------------------------
$script:GuiUi      = $null
$script:GuiWin     = $null
$script:GuiItems   = @()
$script:GuiPhases  = @()
# The panes that are not phases of the plan. Declared once, next to the state
# it belongs with: this list was repeated in five places, and adding a pane to
# four of them produces a tab that renders but shows a meaningless 0/0 counter.
# Made once and frozen: a fresh brush for every row on every repaint is pure
# allocation, and a frozen brush can be shared across threads for nothing.
$script:GuiRowHover = $null

$script:GuiExtraPanes = @('Overview', 'Disk cleanup', 'Startup apps', 'Uninstall apps')

$script:GuiCurrent = 'Overview'
$script:GuiApplied = $false
$script:GuiPreset  = 'recommended'
$script:GuiFacts   = $null
$script:GuiAlready = 0
$script:GuiCleanItems = @()
$script:GuiCleanScanned = $false
$script:GuiScanning = $false
$script:GuiApps = @()
$script:GuiAppsLoaded = $false
$script:GuiUninstallTarget = $null
$script:GuiLeftovers = @()
$script:GuiUninstallStage = 'list'

# "Opinionated" described how the decision was made, not what it means for the
# person reading it. These say what to do about it.
$script:GuiTierName = @{ safe = 'SAFE'; op = 'CAUTION'; trade = 'RISKY' }
$script:GuiTierWhy  = @{
    safe  = 'Safe to run on any system.'
    op    = 'Works for most people, but proceed with caution.'
    trade = 'Most likely to cause issues. Only if you know what you are doing.'
}

function Get-GuiBrush {
    param([Parameter(Mandatory)][string]$Hex)
    return [Windows.Media.BrushConverter]::new().ConvertFrom($Hex)
}

<#
.SYNOPSIS
    Windows 11 paints the title bar light unless asked otherwise, which looks
    broken above a dark window.
#>
function Set-DarkTitleBar {
    param([Parameter(Mandatory)]$Window)
    try {
        if (-not ('Trim.Dwm' -as [type])) {
            Add-Type -Namespace Trim -Name Dwm -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("dwmapi.dll")]
public static extern int DwmSetWindowAttribute(System.IntPtr hwnd, int attr, ref int value, int size);
'@
        }
        $h = (New-Object System.Windows.Interop.WindowInteropHelper $Window).Handle
        $on = 1
        # 20 on current builds, 19 on 1809-1903. Trying both is cheaper than
        # working out which build this is.
        [void][Trim.Dwm]::DwmSetWindowAttribute($h, 20, [ref]$on, 4)
        [void][Trim.Dwm]::DwmSetWindowAttribute($h, 19, [ref]$on, 4)
    } catch { }
}

<#
.SYNOPSIS
    Draw the mark as the window and taskbar icon.

.DESCRIPTION
    Rendered rather than shipped as a file, so the single distributable script
    has no external assets to lose.
#>
function New-TrimIcon {
    try {
        $dv = New-Object Windows.Media.DrawingVisual
        $dc = $dv.RenderOpen()
        $accent = Get-GuiBrush '#46C6B0'
        $bg     = Get-GuiBrush '#171C1B'
        $dc.DrawRoundedRectangle($bg, $null, (New-Object Windows.Rect 0,0,64,64), 12, 12)
        $bars = @(@(8,14,48), @(8,28,32), @(8,42,18))
        $op   = @(1.0, 0.72, 0.45)
        for ($i = 0; $i -lt 3; $i++) {
            $b = $bars[$i]
            $brush = $accent.Clone(); $brush.Opacity = $op[$i]; $brush.Freeze()
            $dc.DrawRoundedRectangle($brush, $null,
                (New-Object Windows.Rect $b[0], $b[1], $b[2], 9), 4.5, 4.5)
        }
        $dc.Close()
        $rtb = New-Object Windows.Media.Imaging.RenderTargetBitmap 64, 64, 96, 96, ([Windows.Media.PixelFormats]::Pbgra32)
        $rtb.Render($dv)
        return $rtb
    } catch { return $null }
}

<#
.SYNOPSIS
    Flatten the ledger and the action list into one list of selectable rows.
#>
function Get-GuiItems {
    param($Ledger, $Actions)

    $items = [System.Collections.Generic.List[object]]::new()

    foreach ($e in @($Ledger)) {
        $now = if ($e.HadValue) { "$($e.OldValue)" } else { '(not set)' }
        if ("$now" -eq '') { $now = '(empty)' }
        $to = if ($e.Action -eq 'remove') { '(removed)' } else { "$($e.NewValue)" }

        $items.Add([pscustomobject]@{
            Key      = "reg|$($e.Path)|$($e.Name)"
            Kind     = 'reg'
            Phase    = "$($e.Phase)"
            Title    = if ($e.Because) { "$($e.Because)" } else { "$($e.Name)" }
            Detail   = "$($e.Name)   $now -> $to"
            Tier     = if ($e.PSObject.Properties.Name -contains 'Tier' -and $e.Tier) { "$($e.Tier)" } else { 'safe' }
            Selected = $true
        }) | Out-Null
    }

    foreach ($a in @($Actions)) {
        $items.Add([pscustomobject]@{
            Key      = "act|$($a.Kind)|$($a.Target)"
            Kind     = "$($a.Kind)"
            Phase    = "$($a.Phase)"
            Title    = "$($a.Target)"
            Detail   = "$($a.Detail)   [reversible: $($a.Reversible)]"
            Tier     = if ($a.PSObject.Properties.Name -contains 'Tier' -and $a.Tier) { "$($a.Tier)" } else { 'safe' }
            Selected = $true
        }) | Out-Null
    }

    foreach ($i in $items) { if ($i.Tier -eq 'trade') { $i.Selected = $false } }
    return $items
}

# ---------------------------------------------------------------------------
#  Rendering
# ---------------------------------------------------------------------------

function Get-GuiPhaseCounts {
    param([Parameter(Mandatory)][string]$Phase)
    $inP = @($script:GuiItems | Where-Object { $_.Phase -eq $Phase })
    return [pscustomobject]@{ On = @($inP | Where-Object { $_.Selected }).Count; Total = $inP.Count }
}

function Update-GuiCounts {
    $ui    = $script:GuiUi
    $total = @($script:GuiItems | Where-Object { $_.Selected }).Count
    $trade = @($script:GuiItems | Where-Object { $_.Selected -and $_.Tier -eq 'trade' }).Count

    $ui.TxtCount.Text = "$total of $($script:GuiItems.Count) changes selected"
    $ui.TxtNote.Text  = "$($script:GuiAlready) settings already correct - left alone"
    $ui.BtnApply.IsEnabled = ($total -gt 0)

    if ($trade -gt 0) {
        $ui.BannerBox.Visibility = 'Visible'
        $ui.TxtBanner.Text = "Risky change selected. Disabling Memory Integrity removes the check that stops a " +
            "malicious or vulnerable kernel driver tampering with Windows. Microsoft advise turning it off " +
            "for a session and back on afterwards, not leaving it off. A reboot is required."
    } else {
        $ui.BannerBox.Visibility = 'Collapsed'
    }

    if ($script:GuiCurrent -notin $script:GuiExtraPanes) {
        $c = Get-GuiPhaseCounts -Phase $script:GuiCurrent
        $ui.TxtPhaseSub.Text = "$($c.On) of $($c.Total) selected"
    }
    Update-GuiPhaseCounts
}

# Only the numbers, so ticking a box does not rebuild the sidebar under the mouse.
function Update-GuiPhaseCounts {
    foreach ($child in $script:GuiUi.PanelPhases.Children) {
        if (-not $child.Tag -or $child.Tag -in $script:GuiExtraPanes) { continue }
        $c = Get-GuiPhaseCounts -Phase $child.Tag
        $grid = $child.Content
        if ($grid -and $grid.Children.Count -ge 2) {
            $grid.Children[1].Text = "$($c.On)/$($c.Total)"
        }
    }
}

function Update-GuiPhases {
    $ui = $script:GuiUi
    $ui.PanelPhases.Children.Clear()

    $brInk    = Get-GuiBrush '#E6EDEB'
    $brFaint  = Get-GuiBrush '#8C9A97'
    $brRaise  = Get-GuiBrush '#263130'
    $brAccent = Get-GuiBrush '#46C6B0'
    $brNone   = [Windows.Media.Brushes]::Transparent

    foreach ($p in (@('Overview') + $script:GuiPhases + @('Disk cleanup','Startup apps','Uninstall apps'))) {
        $isCur = ($p -eq $script:GuiCurrent)

        $b = New-Object Windows.Controls.Button
        $b.Style           = $script:GuiWin.FindResource('Nav')
        $b.Background      = if ($isCur) { $brRaise } else { $brNone }
        $b.BorderBrush     = if ($isCur) { $brAccent } else { $brNone }
        $b.BorderThickness = New-Object Windows.Thickness 2,0,0,0
        $b.Padding         = New-Object Windows.Thickness 10,7,8,7
        $b.Margin          = New-Object Windows.Thickness 0,0,0,2
        $b.FontWeight      = if ($isCur) { 'SemiBold' } else { 'Normal' }
        $b.Tag             = $p

        $g  = New-Object Windows.Controls.Grid
        $c1 = New-Object Windows.Controls.ColumnDefinition; $c1.Width = New-Object Windows.GridLength 1, 'Star'
        $c2 = New-Object Windows.Controls.ColumnDefinition; $c2.Width = 'Auto'
        $g.ColumnDefinitions.Add($c1); $g.ColumnDefinitions.Add($c2)

        $t1 = New-Object Windows.Controls.TextBlock
        $t1.Text = $p
        $t1.Foreground = if ($isCur) { $brInk } else { $brFaint }

        $t2 = New-Object Windows.Controls.TextBlock
        $t2.FontSize = 11
        $t2.Foreground = $brFaint
        $t2.VerticalAlignment = 'Center'
        if ($p -eq 'Overview') {
            $t2.Text = ''
        } elseif ($p -in $script:GuiExtraPanes) {
            # Not part of the preset flow, so it has no selected/total to show.
            $t2.Text = ''
            $t1.Foreground = if ($isCur) { $brInk } else { $brFaint }
        } else {
            $c = Get-GuiPhaseCounts -Phase $p
            $t2.Text = "$($c.On)/$($c.Total)"
        }
        [Windows.Controls.Grid]::SetColumn($t2, 1)

        $g.Children.Add($t1) | Out-Null
        $g.Children.Add($t2) | Out-Null
        $b.Content = $g
        $b.Add_Click({ Set-GuiPhase $this.Tag })
        $ui.PanelPhases.Children.Add($b) | Out-Null
    }
}

<#
.SYNOPSIS
    A row of large figures, for the facts worth reading at a glance.
#>
function Add-GuiStatStrip {
    param([Parameter(Mandatory)][array]$Stats)

    $wrap = New-Object Windows.Controls.Border
    $wrap.Background      = Get-GuiBrush '#1E2524'
    $wrap.BorderBrush     = Get-GuiBrush '#2E3937'
    $wrap.BorderThickness = New-Object Windows.Thickness 1
    $wrap.CornerRadius    = New-Object Windows.CornerRadius 6
    $wrap.Padding         = New-Object Windows.Thickness 20,16,20,16
    $wrap.HorizontalAlignment = 'Left'
    $wrap.Margin          = New-Object Windows.Thickness 0,2,0,0

    $g = New-Object Windows.Controls.Grid
    for ($i = 0; $i -lt $Stats.Count; $i++) {
        $cd = New-Object Windows.Controls.ColumnDefinition
        $cd.Width = 'Auto'
        $g.ColumnDefinitions.Add($cd)
    }

    for ($i = 0; $i -lt $Stats.Count; $i++) {
        $stat = $Stats[$i]

        $cell = New-Object Windows.Controls.StackPanel
        $cell.Margin = New-Object Windows.Thickness $(if ($i -eq 0) { 0 } else { 46 }),0,0,0

        $n = New-Object Windows.Controls.TextBlock
        $n.Text       = [string]$stat.Value
        $n.FontSize   = 30
        $n.FontWeight = 'Bold'
        # Tabular figures, so a 9 and a 60 do not shift the label under them.
        # ContainsKey, not $stat.Accent: under StrictMode reading a key that is
        # not there is an error, not $null, and most of these stats do not set
        # it.
        $isAccent = $stat.ContainsKey('Accent') -and $stat.Accent
        $n.Foreground = Get-GuiBrush $(if ($isAccent) { '#46C6B0' } else { '#E6EDEB' })
        $cell.Children.Add($n) | Out-Null

        $l = New-Object Windows.Controls.TextBlock
        $l.Text       = [string]$stat.Label
        $l.FontSize   = 12
        $l.Foreground = Get-GuiBrush '#8C9A97'
        $l.Margin     = New-Object Windows.Thickness 0,2,0,0
        $cell.Children.Add($l) | Out-Null

        [Windows.Controls.Grid]::SetColumn($cell, $i)
        $g.Children.Add($cell) | Out-Null
    }

    $wrap.Child = $g
    $script:GuiUi.PanelItems.Children.Add($wrap) | Out-Null
}

function Add-GuiParagraph {
    param([string]$Text, [string]$Colour = '#98A6A3', [double]$Size = 13, [string]$Weight = 'Normal', [double]$Top = 0)
    $t = New-Object Windows.Controls.TextBlock
    $t.Text = $Text
    $t.TextWrapping = 'Wrap'
    $t.FontSize = $Size
    $t.FontWeight = $Weight
    $t.Foreground = Get-GuiBrush $Colour
    $t.Margin = New-Object Windows.Thickness 0, $Top, 0, 0
    $t.MaxWidth = 720
    $t.HorizontalAlignment = 'Left'
    $script:GuiUi.PanelItems.Children.Add($t) | Out-Null
}

<#
.SYNOPSIS
    The landing pane: what this program is, before any list of checkboxes.
#>
function Show-GuiOverview {
    $ui = $script:GuiUi
    $ui.TxtPhase.Text = 'What this is'

    $f = $script:GuiFacts

    if ($script:GuiScanning) {
        Add-GuiParagraph -Text 'Looking at your PC' -Colour '#E6EDEB' -Size 14.5 -Weight 'SemiBold'
        Add-GuiParagraph -Text ('Trim is working out what it would change on this machine - which apps are ' +
            'installed, what the graphics driver supports, which background tasks are running. ' +
            'It takes a few seconds and changes nothing.') -Top 6
        return
    }

    $ui.TxtPhaseSub.Text = ''
    $total = $script:GuiItems.Count

    # The two numbers people actually want were buried mid-paragraph. They are
    # the first thing on the screen now, at a size you can read without
    # reading.
    Add-GuiStatStrip -Stats @(
        @{ Value = "$total";                 Label = 'things it would change'; Accent = $true },
        @{ Value = "$($script:GuiAlready)";  Label = 'already set that way' },
        @{ Value = '0';                      Label = 'changed so far' }
    )

    Add-GuiParagraph -Text ('Trim removes advertising, telemetry and preinstalled clutter from Windows, ' +
        'and tunes what is left for games. Nothing on this PC has been touched yet.') `
        -Colour '#E6EDEB' -Size 14.5 -Top 20

    Add-GuiParagraph -Text 'Before anything is changed, a backup is made' -Colour '#E6EDEB' -Size 13 -Weight 'SemiBold' -Top 22
    Add-GuiParagraph -Text ("Trim asks Windows for a System Restore point before it touches anything, so the whole " +
        "machine can be rolled back to how it is right now. Some machines have System Protection switched off by " +
        "policy and refuse; if that happens it says so rather than pretending otherwise. Either way, every single " +
        "setting it changes is written down beforehand, and you get a script that puts each one back exactly as " +
        "it was. You are never stuck with a change you did not want.") -Top 5

    Add-GuiParagraph -Text 'How it works' -Colour '#E6EDEB' -Size 13 -Weight 'SemiBold' -Top 22
    Add-GuiParagraph -Text ("Recommended ticks only what is safe on any system. Advanced adds everything marked " +
        "Caution, and Everything adds the risky ones as well - or go through the sections on the left and tick " +
        "exactly what you want. Every row shows the setting, what it is now, and what it would become. " +
        "Nothing at all happens until you press Apply.") -Top 5

    # Three exceptions, not one. This said "apps ... everything else is
    # reversible" while the README and the site both listed three, and this is
    # the screen somebody reads immediately before pressing Apply.
    Add-GuiParagraph -Text 'The three exceptions' -Colour '#E6EDEB' -Size 13 -Weight 'SemiBold' -Top 20
    Add-GuiParagraph -Text ("Three things the undo script cannot put back. Apps that get removed - reinstall " +
        "those from the Microsoft Store. The WinUtil phase's own changes, if you keep it - that is what the " +
        "restore point is for. And the netsh TCP settings, which is one command, printed in the log. " +
        "Everything else is reversible.") -Top 5

    Add-GuiParagraph -Text 'The labels on each row' -Colour '#E6EDEB' -Size 13 -Weight 'SemiBold' -Top 20
    foreach ($t in @('safe','op','trade')) {
        $row = New-Object Windows.Controls.StackPanel
        $row.Orientation = 'Horizontal'
        $row.Margin = New-Object Windows.Thickness 0,7,0,0

        $chip = New-Object Windows.Controls.Border
        $br = Get-GuiBrush (@{ safe='#4FBFA4'; op='#D4A23E'; trade='#E4785C' }[$t])
        $chip.BorderBrush = $br
        $chip.BorderThickness = New-Object Windows.Thickness 1
        $chip.CornerRadius = New-Object Windows.CornerRadius 2
        $chip.Padding = New-Object Windows.Thickness 6,1,6,1
        $chip.Width = 108
        $chip.VerticalAlignment = 'Center'
        $ct = New-Object Windows.Controls.TextBlock
        $ct.Text = $script:GuiTierName[$t]
        $ct.FontSize = 9.5
        $ct.FontWeight = 'Bold'
        $ct.Foreground = $br
        $ct.HorizontalAlignment = 'Center'
        $chip.Child = $ct

        $tx = New-Object Windows.Controls.TextBlock
        $tx.Text = $script:GuiTierWhy[$t]
        $tx.Foreground = Get-GuiBrush '#98A6A3'
        $tx.Margin = New-Object Windows.Thickness 12,0,0,0
        $tx.VerticalAlignment = 'Center'

        $row.Children.Add($chip) | Out-Null
        $row.Children.Add($tx) | Out-Null
        $ui.PanelItems.Children.Add($row) | Out-Null
    }

    Add-GuiParagraph -Text 'This machine' -Colour '#E6EDEB' -Size 13 -Weight 'SemiBold' -Top 24
    Add-GuiParagraph -Text 'Anything that does not apply to this hardware was skipped rather than guessed at.' `
        -Colour '#8C9A97' -Size 12 -Top 4
    Add-GuiSpecGrid -Facts $f

    # Readable, and no more prominent than that. It belongs here once, not on
    # every screen and not in front of someone launching the thing.
    #
    # It used to read "Debloat and tweak engine: WinUtil", which credited Chris
    # Titus Tech for the whole tool and told the reader something false about
    # their own machine: that everything being changed came from WinUtil, and
    # that skipping it would leave nothing. It is one phase of twelve, and it
    # can be skipped.
    Add-GuiParagraph -Text 'One of twelve phases applies WinUtil by Chris Titus Tech - christitus.com/win' `
        -Colour '#8C9A97' -Size 11 -Top 26
}

<#
.SYNOPSIS
    The machine's specification, as a grid, with a button that copies it.

.DESCRIPTION
    People are asked for their specs constantly - by support, by a forum, by
    whoever is helping them. Showing it here and letting them take it in one
    click is more useful than a sentence they would have to retype.
#>
function Get-MachineSpecRows {
    param([Parameter(Mandatory)]$Facts)

    # Fetched here rather than at startup: these queries are slow and nothing
    # else needs them.
    $hw = Get-HardwareDetail

    $rows = [ordered]@{}
    $rows['Operating system'] = "$($Facts.OSCaption) $($Facts.DisplayVersion) (build $($Facts.OSBuild))"
    $rows['Form factor']      = if ($Facts.IsLaptop) { 'Laptop' } else { 'Desktop' }
    $rows['Model']            = "$($Facts.Manufacturer) $($Facts.Model)".Trim()
    if ($hw.Board)       { $rows['Motherboard'] = $hw.Board }
    if ($hw.BiosVersion) { $rows['BIOS']        = $hw.BiosVersion }

    if ($hw.CpuName -and $hw.CpuName -ne 'unknown') {
        $rows['Processor'] = "$($hw.CpuName)  -  $($hw.CpuCores) cores, $($hw.CpuThreads) threads"
    }

    $ram = "$($Facts.RamGB) GB"
    if (@($hw.RamSticks).Count) {
        $ram += "  -  $(@($hw.RamSticks).Count) x $(@($hw.RamSticks)[0].SizeGB) GB"
        if ($hw.RamSpeed) { $ram += " at $($hw.RamSpeed) MT/s" }
    }
    $rows['Memory'] = $ram

    $rows['Graphics'] = ($Facts.GpuNames -join [Environment]::NewLine)
    if ($Facts.RefreshRate) { $rows['Display'] = "$($Facts.RefreshRate) Hz" }

    if (@($hw.Disks).Count) {
        $rows['Storage'] = (@($hw.Disks | ForEach-Object {
            "$($_.Model) - $($_.SizeGB) GB $($_.Media)$(if ($_.Bus) { " ($($_.Bus))" })"
        }) -join [Environment]::NewLine)
    }

    $drives = @()
    try { $drives = @(Get-StorageInventory) } catch { }
    if ($drives.Count) {
        $rows['Volumes'] = (@($drives | ForEach-Object {
            "$($_.Letter): $($_.FreeGB) GB free of $($_.SizeGB) GB$(if ($_.Label) { " - $($_.Label)" })"
        }) -join [Environment]::NewLine)
    }

    if ($Facts.IsManaged) { $rows['Management'] = 'Domain-joined or MDM-enrolled' }
    return $rows
}

function Add-GuiSpecGrid {
    param([Parameter(Mandatory)]$Facts)

    $rows = Get-MachineSpecRows -Facts $Facts
    $ui   = $script:GuiUi

    $panel = New-Object Windows.Controls.Border
    $panel.BorderBrush     = Get-GuiBrush '#2E3937'
    $panel.BorderThickness = New-Object Windows.Thickness 1
    $panel.CornerRadius    = New-Object Windows.CornerRadius 4
    $panel.Background      = Get-GuiBrush '#1E2524'
    $panel.Padding         = New-Object Windows.Thickness 14,10,14,12
    $panel.Margin          = New-Object Windows.Thickness 0,10,0,0
    $panel.HorizontalAlignment = 'Left'
    $panel.MaxWidth        = 780

    $grid = New-Object Windows.Controls.Grid
    $c1 = New-Object Windows.Controls.ColumnDefinition; $c1.Width = 'Auto'
    $c2 = New-Object Windows.Controls.ColumnDefinition; $c2.Width = New-Object Windows.GridLength 1, 'Star'
    $grid.ColumnDefinitions.Add($c1); $grid.ColumnDefinitions.Add($c2)

    $brFaint = Get-GuiBrush '#8C9A97'
    $brInk   = Get-GuiBrush '#E6EDEB'
    $r = 0
    foreach ($k in $rows.Keys) {
        $grid.RowDefinitions.Add((New-Object Windows.Controls.RowDefinition))

        $lbl = New-Object Windows.Controls.TextBlock
        $lbl.Text = $k
        $lbl.Foreground = $brFaint
        $lbl.FontSize = 12
        $lbl.Margin = New-Object Windows.Thickness 0,3,22,3
        $lbl.VerticalAlignment = 'Top'
        [Windows.Controls.Grid]::SetRow($lbl, $r)
        [Windows.Controls.Grid]::SetColumn($lbl, 0)

        $val = New-Object Windows.Controls.TextBlock
        $val.Text = "$($rows[$k])"
        $val.Foreground = $brInk
        $val.FontSize = 12
        $val.TextWrapping = 'Wrap'
        $val.Margin = New-Object Windows.Thickness 0,3,0,3
        [Windows.Controls.Grid]::SetRow($val, $r)
        [Windows.Controls.Grid]::SetColumn($val, 1)

        $grid.Children.Add($lbl) | Out-Null
        $grid.Children.Add($val) | Out-Null
        $r++
    }

    $stack = New-Object Windows.Controls.StackPanel
    $stack.Children.Add($grid) | Out-Null

    $copy = New-Object Windows.Controls.Button
    $copy.Style   = $script:GuiWin.FindResource('Btn')
    $copy.Content = 'Copy specs to clipboard'
    $copy.HorizontalAlignment = 'Left'
    $copy.Margin  = New-Object Windows.Thickness 0,12,0,0
    $copy.Add_Click({ Copy-GuiSpecs })
    $stack.Children.Add($copy) | Out-Null

    $panel.Child = $stack
    $ui.PanelItems.Children.Add($panel) | Out-Null
}

function Copy-GuiSpecs {
    $rows = Get-MachineSpecRows -Facts $script:GuiFacts
    $width = ($rows.Keys | Measure-Object -Property Length -Maximum).Maximum
    $lines = @('System specification', ('-' * 60))
    foreach ($k in $rows.Keys) {
        $value = "$($rows[$k])" -split [Environment]::NewLine
        $lines += ("{0}  {1}" -f $k.PadRight($width), $value[0])
        foreach ($extra in ($value | Select-Object -Skip 1)) {
            $lines += ("{0}  {1}" -f ''.PadRight($width), $extra)
        }
    }
    $lines += ('-' * 60)
    $lines += "Collected by Trim on $(Get-Date -Format 'yyyy-MM-dd HH:mm')"
    try {
        Set-Clipboard -Value ($lines -join [Environment]::NewLine)
        [void][Windows.MessageBox]::Show('Specification copied to the clipboard.', 'Trim', 'OK', 'Information')
    } catch {
        [void][Windows.MessageBox]::Show("Could not access the clipboard: $($_.Exception.Message)", 'Trim', 'OK', 'Warning')
    }
}


<#
.SYNOPSIS
    The cleanup pane. Separate from the preset flow on purpose.

.DESCRIPTION
    Deleting a file is not the same kind of act as changing a setting, and the
    undo script cannot bring one back. So this is never something Apply does in
    passing: you come here, you scan, you look at exactly which folder on which
    disk is about to lose what, and you press the delete button yourself.
#>
function Show-GuiCleanup {
    $ui = $script:GuiUi
    $ui.TxtPhase.Text = 'Disk cleanup'
    $ui.TxtPhaseSub.Text = ''

    if (-not $script:GuiCleanScanned) {
        Add-GuiParagraph -Text 'Free up space' -Colour '#E6EDEB' -Size 14.5 -Weight 'SemiBold'
        Add-GuiParagraph -Text ('This sweeps every drive on this PC for temporary files, caches and leftovers, ' +
            'and shows you every location it finds separately - which folder, on which disk, and how much. ' +
            'Nothing is deleted until you tick it and press Delete.') -Top 6
        Add-GuiParagraph -Text ('It is kept apart from the rest of Trim deliberately. Settings can be undone; ' +
            'deleted files cannot, so no preset will ever do this to you in passing.') -Colour '#8C9A97' -Size 12 -Top 10

        $btns = New-Object Windows.Controls.StackPanel
        $btns.Orientation = 'Horizontal'
        $btns.Margin = New-Object Windows.Thickness 0,20,0,0
        $scan = New-Object Windows.Controls.Button
        $scan.Style = $script:GuiWin.FindResource('Primary')
        $scan.Content = 'Scan this PC'
        $scan.Add_Click({ Invoke-GuiCleanScan })
        $btns.Children.Add($scan) | Out-Null
        $ui.PanelItems.Children.Add($btns) | Out-Null
        return
    }

    $total = ([double](($script:GuiCleanItems | Measure-Object Bytes -Sum).Sum))
    $sel   = ([double](($script:GuiCleanItems | Where-Object { $_.Selected } | Measure-Object Bytes -Sum).Sum))
    $ui.TxtPhaseSub.Text = "$(Format-Bytes $sel) selected of $(Format-Bytes $total) found"

    $bar = New-Object Windows.Controls.StackPanel
    $bar.Orientation = 'Horizontal'
    $bar.Margin = New-Object Windows.Thickness 0,0,0,14
    foreach ($spec in @(
        @{ Text = 'Rescan';          Style = 'Btn';     Handler = { Invoke-GuiCleanScan } },
        @{ Text = 'Find duplicates'; Style = 'Btn';     Handler = { Invoke-GuiDuplicateScan } },
        @{ Text = 'Find large files'; Style = 'Btn';    Handler = { Invoke-GuiLargeFileScan } },
        @{ Text = 'Delete selected'; Style = 'Primary'; Handler = { Invoke-GuiCleanDelete } })) {
        $b = New-Object Windows.Controls.Button
        $b.Style = $script:GuiWin.FindResource($spec.Style)
        $b.Content = $spec.Text
        $b.Margin = New-Object Windows.Thickness 0,0,8,0
        $b.Add_Click($spec.Handler)
        $bar.Children.Add($b) | Out-Null
    }
    $ui.PanelItems.Children.Add($bar) | Out-Null

    Show-GuiLargeFiles

    if ($script:GuiCleanItems.Count -eq 0) {
        Add-GuiParagraph -Text 'Nothing to clean. This PC is already tidy.' -Colour '#4FBFA4' -Size 14
        return
    }

    $brInk   = Get-GuiBrush '#E6EDEB'
    $brFaint = Get-GuiBrush '#8C9A97'
    $brSoft  = Get-GuiBrush '#98A6A3'
    $brRule  = Get-GuiBrush '#2E3937'
    $tierBrush = @{ safe = Get-GuiBrush '#4FBFA4'; op = Get-GuiBrush '#D4A23E'; trade = Get-GuiBrush '#E4785C' }

    foreach ($grp in ($script:GuiCleanItems | Group-Object Category)) {
        $gsum = [double](($grp.Group | Measure-Object Bytes -Sum).Sum)

        $head = New-Object Windows.Controls.StackPanel
        $head.Margin = New-Object Windows.Thickness 0,14,0,4
        $h1 = New-Object Windows.Controls.TextBlock
        $h1.Text = "$($grp.Name)   -   $(Format-Bytes $gsum)"
        $h1.FontWeight = 'SemiBold'
        $h1.FontSize = 13.5
        $h1.Foreground = $brInk
        $h2 = New-Object Windows.Controls.TextBlock
        $h2.Text = $grp.Group[0].Why
        $h2.TextWrapping = 'Wrap'
        $h2.FontSize = 11.5
        $h2.Foreground = $brSoft
        $h2.MaxWidth = 760
        $h2.HorizontalAlignment = 'Left'
        $h2.Margin = New-Object Windows.Thickness 0,2,0,0
        $head.Children.Add($h1) | Out-Null
        $head.Children.Add($h2) | Out-Null
        $ui.PanelItems.Children.Add($head) | Out-Null

        foreach ($item in $grp.Group) {
            $row = New-Object Windows.Controls.Border
            $row.BorderBrush = $brRule
            $row.BorderThickness = New-Object Windows.Thickness 0,0,0,1
            $row.Padding = New-Object Windows.Thickness 4,6,4,7

            $g = New-Object Windows.Controls.Grid
            foreach ($w in @('Auto','Auto','Star','Auto')) {
                $cd = New-Object Windows.Controls.ColumnDefinition
                $cd.Width = if ($w -eq 'Star') { New-Object Windows.GridLength 1, 'Star' } else { 'Auto' }
                $g.ColumnDefinitions.Add($cd)
            }

            $cb = New-Object Windows.Controls.CheckBox
            $cb.IsChecked = [bool]$item.Selected
            $cb.Margin = New-Object Windows.Thickness 0,1,12,0
            $cb.VerticalAlignment = 'Center'
            $cb.Tag = $item
            $cb.Add_Click({ $this.Tag.Selected = [bool]$this.IsChecked; Update-GuiCleanTotals })
            [Windows.Controls.Grid]::SetColumn($cb, 0)

            $size = New-Object Windows.Controls.TextBlock
            $size.Text = $item.Size
            $size.Width = 84
            $size.TextAlignment = 'Right'
            $size.FontWeight = 'SemiBold'
            $size.Foreground = $brInk
            $size.VerticalAlignment = 'Center'
            $size.Margin = New-Object Windows.Thickness 0,0,14,0
            [Windows.Controls.Grid]::SetColumn($size, 1)

            $path = New-Object Windows.Controls.TextBlock
            $path.Text = $item.Path
            $path.FontFamily = New-Object Windows.Media.FontFamily 'Cascadia Mono, Consolas'
            $path.FontSize = 11.5
            $path.Foreground = $brFaint
            $path.TextTrimming = 'CharacterEllipsis'
            $path.VerticalAlignment = 'Center'
            $path.ToolTip = "$($item.Path)`n$($item.Count) file(s)"
            [Windows.Controls.Grid]::SetColumn($path, 2)

            $chip = New-Object Windows.Controls.Border
            $chip.BorderBrush = $tierBrush[$item.Tier]
            $chip.BorderThickness = New-Object Windows.Thickness 1
            $chip.CornerRadius = New-Object Windows.CornerRadius 2
            $chip.Padding = New-Object Windows.Thickness 6,1,6,1
            $chip.Width = 108
            $chip.VerticalAlignment = 'Center'
            $chip.Margin = New-Object Windows.Thickness 12,0,0,0
            $ct = New-Object Windows.Controls.TextBlock
            $ct.Text = $script:GuiTierName[$item.Tier]
            $ct.FontSize = 9.5
            $ct.FontWeight = 'Bold'
            $ct.Foreground = $tierBrush[$item.Tier]
            $ct.HorizontalAlignment = 'Center'
            $chip.Child = $ct
            [Windows.Controls.Grid]::SetColumn($chip, 3)

            $g.Children.Add($cb)   | Out-Null
            $g.Children.Add($size) | Out-Null
            $g.Children.Add($path) | Out-Null
            $g.Children.Add($chip) | Out-Null
            $row.Child = $g
            $ui.PanelItems.Children.Add($row) | Out-Null
        }
    }
}

function Update-GuiCleanTotals {
    $total = [double](($script:GuiCleanItems | Measure-Object Bytes -Sum).Sum)
    $sel   = [double](($script:GuiCleanItems | Where-Object { $_.Selected } | Measure-Object Bytes -Sum).Sum)
    $script:GuiUi.TxtPhaseSub.Text = "$(Format-Bytes $sel) selected of $(Format-Bytes $total) found"
}

function Invoke-GuiCleanScan {
    $script:GuiUi.TxtPhaseSub.Text = 'Scanning every drive...'
    $script:GuiWin.Dispatcher.Invoke([action]{}, 'Render')
    $script:GuiCleanItems = @(Get-CleanupScan -Quiet)
    $script:GuiCleanScanned = $true
    Update-GuiItems
}

$script:GuiLargeFiles = @()
$script:LargeScanTruncated = $false
$script:LargeScanSeconds   = 0

<#
.SYNOPSIS
    Find the biggest files on the machine. Report only.

.DESCRIPTION
    Deliberately kept out of $script:GuiCleanItems, which is the list the Delete
    button acts on. A large file is not a junk file - a 40 GB game, a 40 GB video
    project and a 40 GB forgotten ISO are indistinguishable from here - so these
    are shown and never selected.
#>
function Invoke-GuiLargeFileScan {
    $script:GuiUi.TxtPhaseSub.Text = 'Looking for large files across every drive. This can take a minute...'
    $script:GuiWin.Dispatcher.Invoke([action]{}, 'Render')
    $script:GuiLargeFiles = @(Get-LargeFileScan)
    Update-GuiItems
}

function Invoke-GuiDuplicateScan {
    $script:GuiUi.TxtPhaseSub.Text = 'Hashing files to find duplicates. This can take a minute...'
    $script:GuiWin.Dispatcher.Invoke([action]{}, 'Render')
    $existing = @($script:GuiCleanItems | Where-Object { $_.Key -notlike 'dupe|*' })
    $script:GuiCleanItems = @($existing) + @(Get-DuplicateScan)
    Update-GuiItems
}

<#
.SYNOPSIS
    The large-file report. No checkboxes, on purpose.
#>
function Show-GuiLargeFiles {
    if (-not $script:GuiLargeFiles.Count) { return }

    $ui      = $script:GuiUi
    $brInk   = Get-GuiBrush '#E6EDEB'
    $brFaint = Get-GuiBrush '#8C9A97'
    $brRule  = Get-GuiBrush '#2E3937'

    Add-GuiParagraph -Text "Largest files  -  $($script:GuiLargeFiles.Count) found" `
        -Colour '#E6EDEB' -Size 14 -Weight 'SemiBold' -Top 6
    Add-GuiParagraph -Text ('Shown so you can see what is using the space. Nothing here is selected ' +
        'or deleted by Trim - a large file is not the same thing as a junk file, and only you can ' +
        'tell which is which. Windows and Program Files are left out.') `
        -Colour '#8C9A97' -Size 12 -Top 4

    # The walk gives up after a fixed time, and until now said so only in the
    # log. A partial list presented as a complete one is the wrong answer to
    # "where did my disk go", and the person reading it has no way to tell.
    if ($script:LargeScanTruncated) {
        Add-GuiParagraph -Text ("This list is incomplete. The scan stopped after $($script:LargeScanSeconds) seconds " +
            'and these are the largest it had found by then, so there may be bigger files it never reached.') `
            -Colour '#E4B45C' -Size 12 -Top 8
    }

    foreach ($f in $script:GuiLargeFiles) {
        $row = New-Object Windows.Controls.Border
        $row.BorderBrush = $brRule
        $row.BorderThickness = New-Object Windows.Thickness 0,0,0,1
        $row.Padding = New-Object Windows.Thickness 4,6,4,7

        $g = New-Object Windows.Controls.Grid
        foreach ($w in @('Auto','Star','Auto')) {
            $cd = New-Object Windows.Controls.ColumnDefinition
            $cd.Width = if ($w -eq 'Star') { New-Object Windows.GridLength 1, 'Star' } else { 'Auto' }
            $g.ColumnDefinitions.Add($cd)
        }

        $size = New-Object Windows.Controls.TextBlock
        $size.Text = $f.Size
        $size.FontFamily = New-Object Windows.Media.FontFamily 'Cascadia Mono, Consolas, monospace'
        $size.FontSize = 12
        $size.Foreground = $brInk
        $size.MinWidth = 78
        [Windows.Controls.Grid]::SetColumn($size, 0)

        $path = New-Object Windows.Controls.TextBlock
        $path.Text = $f.Path
        $path.FontSize = 12
        $path.Foreground = $brFaint
        $path.TextTrimming = 'CharacterEllipsis'
        $path.Margin = New-Object Windows.Thickness 12,0,12,0
        $path.ToolTip = $f.Path
        [Windows.Controls.Grid]::SetColumn($path, 1)

        $kind = New-Object Windows.Controls.TextBlock
        $kind.Text = "$($f.Kind)  -  $($f.Age)d old"
        $kind.FontSize = 11.5
        $kind.Foreground = $brFaint
        [Windows.Controls.Grid]::SetColumn($kind, 2)

        $g.Children.Add($size) | Out-Null
        $g.Children.Add($path) | Out-Null
        $g.Children.Add($kind) | Out-Null
        $row.Child = $g
        $ui.PanelItems.Children.Add($row) | Out-Null
    }
}

<#
.SYNOPSIS
    Delete what is ticked, elevating first if the selection includes system paths.
#>
function Invoke-GuiCleanDelete {
    $sel = @($script:GuiCleanItems | Where-Object { $_.Selected })
    if ($sel.Count -eq 0) { return }

    $bytes = [double](($sel | Measure-Object Bytes -Sum).Sum)
    $files = ($sel | Measure-Object Count -Sum).Sum
    $answer = [Windows.MessageBox]::Show(
        "Delete $files file(s) from $($sel.Count) location(s), freeing about $(Format-Bytes $bytes)?" +
        [Environment]::NewLine + [Environment]::NewLine +
        'This cannot be undone by Trim. Files already in the Recycle Bin are removed permanently.',
        'Trim - confirm deletion', 'YesNo', 'Warning', 'No')
    if ($answer -ne 'Yes') { return }

    $script:GuiUi.TxtPhaseSub.Text = 'Deleting...'
    $script:GuiWin.Dispatcher.Invoke([action]{}, 'Render')

    $result = Invoke-Cleanup -Items $sel
    $script:GuiCleanItems = @(Get-CleanupScan -Quiet)
    Update-GuiItems

    $msg = "Freed $(Format-Bytes ([double]$result.Freed))."
    if ($result.Skipped -gt 0) {
        $msg += [Environment]::NewLine + [Environment]::NewLine +
                "$($result.Skipped) file(s) were in use or needed administrator rights and were left alone."
        if (-not $isAdmin) {
            $msg += ' Running Trim as administrator would clear the system locations too.'
        }
    }
    [void][Windows.MessageBox]::Show($msg, 'Trim - cleanup finished', 'OK', 'Information')
}


# ---------------------------------------------------------------------------
#  Uninstall apps
# ---------------------------------------------------------------------------

# Icons for the uninstall list. The point is not decoration: two entries called
# "Microsoft Visual C++ 2015-2022 Redistributable (x64)" and "(x86)" are one
# careless click apart, and the icon is what tells them apart at a glance.
#
# The rule throughout: show the app's OWN icon or show a neutral placeholder.
# Never substitute something that could be read as a different app's mark.
$script:GuiIconCache  = @{}
$script:GuiIconBudget = $null

function Convert-IconToImageSource {
    param([string]$Path, [int]$Index = 0)

    try { Add-Type -AssemblyName System.Drawing -ErrorAction Stop } catch { return $null }

    $ico = $null; $bmp = $null; $ms = $null
    try {
        if ($Path -match '\.ico$') { $ico = New-Object System.Drawing.Icon($Path, 48, 48) }
        else                       { $ico = [System.Drawing.Icon]::ExtractAssociatedIcon($Path) }
        if (-not $ico) { return $null }

        $bmp = $ico.ToBitmap()
        $ms  = New-Object System.IO.MemoryStream
        $bmp.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
        $ms.Position = 0

        $img = New-Object Windows.Media.Imaging.BitmapImage
        $img.BeginInit()
        $img.StreamSource = $ms
        # OnLoad reads the stream fully here, so disposing it below is safe.
        $img.CacheOption  = 'OnLoad'
        $img.EndInit()
        $img.Freeze()
        return $img
    }
    catch { return $null }
    finally {
        if ($bmp) { $bmp.Dispose() }
        if ($ico) { $ico.Dispose() }
        if ($ms)  { $ms.Dispose() }
    }
}

function Get-GuiAppIcon {
    param($App)

    $src = "$($App.IconSource)".Trim()
    if (-not $src) { return $null }
    if ($script:GuiIconCache.ContainsKey($src)) { return $script:GuiIconCache[$src] }

    # An install directory on a disconnected network share turns every miss
    # into a timeout. Past the budget the rest of the list gets placeholders
    # rather than a frozen window.
    if ($null -eq $script:GuiIconBudget) { $script:GuiIconBudget = [Diagnostics.Stopwatch]::StartNew() }
    if ($script:GuiIconBudget.Elapsed.TotalSeconds -gt 6) { return $null }

    $img = $null
    try {
        # DisplayIcon is a path, optionally quoted, optionally with a resource
        # index: "C:\Program Files\App\app.exe",0
        $path  = $src
        $index = 0
        if ($path -match '^\s*"([^"]+)"\s*,\s*(-?\d+)\s*$') { $path = $Matches[1]; $index = [int]$Matches[2] }
        elseif ($path -match '^\s*"([^"]+)"\s*$')           { $path = $Matches[1] }
        elseif ($path -match '^(.+?)\s*,\s*(-?\d+)\s*$')    { $path = $Matches[1]; $index = [int]$Matches[2] }
        $path = $path.Trim()

        if ($path -and (Test-Path -LiteralPath $path -PathType Leaf)) {
            if ($path -match '\.(png|jpg|jpeg|bmp|gif)$') {
                $img = New-Object Windows.Media.Imaging.BitmapImage
                $img.BeginInit()
                $img.UriSource        = New-Object Uri $path
                $img.DecodePixelWidth = 48
                $img.CacheOption      = 'OnLoad'
                $img.EndInit()
                $img.Freeze()
            }
            else {
                $img = Convert-IconToImageSource -Path $path -Index $index
            }
        }
    }
    catch { $img = $null }

    $script:GuiIconCache[$src] = $img
    return $img
}

# A 26px slot that always renders something, so the column never collapses and
# rows stay aligned. Real icon when there is one; otherwise a plain tile with
# the app's initial - visibly a placeholder rather than somebody's logo.
function New-GuiAppIconTile {
    param($App)

    $host_ = New-Object Windows.Controls.Border
    $host_.Width  = 26
    $host_.Height = 26
    $host_.VerticalAlignment = 'Center'
    $host_.Margin = New-Object Windows.Thickness 0,0,12,0

    $icon = Get-GuiAppIcon -App $App
    if ($icon) {
        $im = New-Object Windows.Controls.Image
        $im.Source  = $icon
        $im.Width   = 24
        $im.Height  = 24
        $im.Stretch = 'Uniform'
        [Windows.Media.RenderOptions]::SetBitmapScalingMode($im, 'HighQuality')
        $host_.Child = $im
        return $host_
    }

    $host_.Background   = Get-GuiBrush '#263130'
    $host_.BorderBrush  = Get-GuiBrush '#2E3937'
    $host_.BorderThickness = New-Object Windows.Thickness 1
    $host_.CornerRadius = New-Object Windows.CornerRadius 5

    $letter = New-Object Windows.Controls.TextBlock
    $name = "$($App.DisplayName)".Trim()
    $letter.Text = if ($name) { $name.Substring(0,1).ToUpper() } else { '?' }
    $letter.FontSize   = 12
    $letter.FontWeight = 'SemiBold'
    $letter.Foreground = Get-GuiBrush '#98A6A3'
    $letter.HorizontalAlignment = 'Center'
    $letter.VerticalAlignment   = 'Center'
    $host_.Child = $letter
    return $host_
}

<#
.SYNOPSIS
    Remove an application and then the traces it leaves behind.

.DESCRIPTION
    Two stages, and the second never happens implicitly. Stage one runs the
    vendor's own uninstaller. Stage two lists every folder and registry key that
    survived it, with full paths, and removes only what is ticked.

    Nothing is deleted that was not on screen first. Registry keys are exported
    to .reg files before removal, so a mistake is recoverable.
#>
$script:GuiStartupItems  = @()
$script:GuiStartupLoaded = $false

function Invoke-GuiLoadStartup {
    $script:GuiStartupItems = @(Invoke-WithProgress -Title 'Reading startup items' -Work { Get-StartupItems })
    $script:GuiStartupLoaded = $true
    Update-GuiItems
}

function Invoke-GuiToggleStartup {
    param($Item, $Button)

    $ok = if ($Item.State -eq 'Enabled') { Disable-StartupItem -Item $Item } else { Enable-StartupItem -Item $Item }
    if (-not $ok) { return }

    # Re-read rather than assuming the write landed. Disabling a machine-wide
    # entry without administrator rights fails, and a button that lies about it
    # is worse than one that does nothing.
    $script:GuiStartupItems = @(Get-StartupItems)
    Update-GuiItems
}

<#
.SYNOPSIS
    What runs when you log in, and a switch for each of it.
#>
function Show-GuiStartup {
    $ui = $script:GuiUi
    $ui.TxtPhase.Text = 'Startup apps'

    if (-not $script:GuiStartupLoaded) {
        $ui.TxtPhaseSub.Text = ''
        Add-GuiParagraph -Text 'What starts with Windows' -Colour '#E6EDEB' -Size 14.5 -Weight 'SemiBold'
        Add-GuiParagraph -Text ('Every program that launches when you sign in, from all four places Windows ' +
            'keeps them: your account, the machine-wide list, the two Startup folders, and scheduled tasks ' +
            'that trigger at logon.') -Top 6
        # Three mechanisms, and this used to describe them as one. "The same
        # switch Task Manager uses" is true of the registry entries only; a
        # Startup folder shortcut is moved, and a logon scheduled task cannot be
        # changed from here at all - it is listed so you know it is there. The
        # rows already show which is which; the paragraph above them did not.
        Add-GuiParagraph -Text ('Registry entries are switched off the way Task Manager does it, so they stay off ' +
            'and you can turn them back on without this tool. Startup folder shortcuts are moved into a ' +
            '"Disabled by Trim" folder rather than deleted. Both go through the undo script. Scheduled tasks ' +
            'are listed so you can see them, but changing one is a job for Task Scheduler.') `
            -Colour '#8C9A97' -Size 12 -Top 10

        $b = New-Object Windows.Controls.Button
        $b.Style = $script:GuiWin.FindResource('Primary')
        $b.Content = 'List startup items'
        $b.HorizontalAlignment = 'Left'
        $b.Margin = New-Object Windows.Thickness 0,20,0,0
        $b.Add_Click({ Invoke-GuiLoadStartup })
        $ui.PanelItems.Children.Add($b) | Out-Null
        return
    }

    $on = @($script:GuiStartupItems | Where-Object { $_.State -eq 'Enabled' }).Count
    $ui.TxtPhaseSub.Text = "$on of $($script:GuiStartupItems.Count) enabled"

    $brInk   = Get-GuiBrush '#E6EDEB'
    $brFaint = Get-GuiBrush '#8C9A97'
    $brRule  = Get-GuiBrush '#2E3937'
    $brMint  = Get-GuiBrush '#46C6B0'

    foreach ($item in $script:GuiStartupItems) {
        $row = New-Object Windows.Controls.Border
        $row.BorderBrush = $brRule
        $row.BorderThickness = New-Object Windows.Thickness 0,0,0,1
        $row.Padding = New-Object Windows.Thickness 4,7,4,8

        $g = New-Object Windows.Controls.Grid
        foreach ($w in @('Star','Auto')) {
            $cd = New-Object Windows.Controls.ColumnDefinition
            $cd.Width = if ($w -eq 'Star') { New-Object Windows.GridLength 1, 'Star' } else { 'Auto' }
            $g.ColumnDefinitions.Add($cd)
        }
        $g.RowDefinitions.Add((New-Object Windows.Controls.RowDefinition))
        $g.RowDefinitions.Add((New-Object Windows.Controls.RowDefinition))

        $name = New-Object Windows.Controls.TextBlock
        $name.Text = $item.Name
        $name.FontWeight = 'SemiBold'
        $name.Foreground = if ($item.State -eq 'Enabled') { $brInk } else { $brFaint }
        $name.TextTrimming = 'CharacterEllipsis'
        [Windows.Controls.Grid]::SetColumn($name, 0)

        $meta = New-Object Windows.Controls.TextBlock
        $bits = @()
        if ($item.Publisher) { $bits += $item.Publisher }
        $bits += $item.Source
        $bits += $item.Scope
        if ($item.State -eq 'Disabled') { $bits += 'already off' }
        $meta.Text = ($bits -join '  -  ')
        $meta.FontSize = 11.5
        $meta.Foreground = $brFaint
        $meta.TextTrimming = 'CharacterEllipsis'
        $meta.Margin = New-Object Windows.Thickness 0,2,0,0
        [Windows.Controls.Grid]::SetColumn($meta, 0)
        [Windows.Controls.Grid]::SetRow($meta, 1)

        $g.Children.Add($name) | Out-Null
        $g.Children.Add($meta) | Out-Null

        if ($item.CanChange) {
            $btn = New-Object Windows.Controls.Button
            $btn.Style = $script:GuiWin.FindResource('Btn')
            $btn.Content = if ($item.State -eq 'Enabled') { 'Turn off' } else { 'Turn on' }
            $btn.VerticalAlignment = 'Center'
            $btn.Margin = New-Object Windows.Thickness 12,0,0,0
            # Captured per row deliberately: the handler must act on this item,
            # not on whatever the loop variable happens to be afterwards.
            $captured = $item
            $btn.Add_Click({ Invoke-GuiToggleStartup -Item $captured }.GetNewClosure())
            [Windows.Controls.Grid]::SetColumn($btn, 1)
            [Windows.Controls.Grid]::SetRowSpan($btn, 2)
            $g.Children.Add($btn) | Out-Null
        } else {
            $note = New-Object Windows.Controls.TextBlock
            $note.Text = 'scheduled task'
            $note.FontSize = 11
            $note.Foreground = $brFaint
            $note.VerticalAlignment = 'Center'
            $note.Margin = New-Object Windows.Thickness 12,0,0,0
            [Windows.Controls.Grid]::SetColumn($note, 1)
            [Windows.Controls.Grid]::SetRowSpan($note, 2)
            $g.Children.Add($note) | Out-Null
        }

        $row.Child = $g
        $ui.PanelItems.Children.Add($row) | Out-Null
    }
}

function Show-GuiUninstall {
    $ui = $script:GuiUi
    $ui.TxtPhase.Text = 'Uninstall apps'

    if ($script:GuiUninstallStage -eq 'leftovers') { Show-GuiLeftovers; return }

    $ui.TxtPhaseSub.Text = ''

    if (-not $script:GuiAppsLoaded) {
        Add-GuiParagraph -Text 'Remove an app properly' -Colour '#E6EDEB' -Size 14.5 -Weight 'SemiBold'
        Add-GuiParagraph -Text ('Windows uninstallers routinely leave folders and registry keys behind. ' +
            'Trim runs the app''s own uninstaller, then shows you exactly what survived it - every folder ' +
            'and every registry key, with its full path - and removes only what you tick.') -Top 6
        Add-GuiParagraph -Text ('Registry keys are exported to a .reg file before they are deleted, and ' +
            'anything that does not clearly belong to the app you removed is left alone and reported.') `
            -Colour '#8C9A97' -Size 12 -Top 10

        $b = New-Object Windows.Controls.Button
        $b.Style = $script:GuiWin.FindResource('Primary')
        $b.Content = 'List installed apps'
        $b.HorizontalAlignment = 'Left'
        $b.Margin = New-Object Windows.Thickness 0,20,0,0
        $b.Add_Click({ Invoke-GuiLoadApps })
        $ui.PanelItems.Children.Add($b) | Out-Null
        return
    }

    $ui.TxtPhaseSub.Text = "$($script:GuiApps.Count) installed"

    $brInk   = Get-GuiBrush '#E6EDEB'
    $brFaint = Get-GuiBrush '#8C9A97'
    $brRule  = Get-GuiBrush '#2E3937'

    foreach ($app in $script:GuiApps) {
        $row = New-Object Windows.Controls.Border
        $row.BorderBrush = $brRule
        $row.BorderThickness = New-Object Windows.Thickness 0,0,0,1
        $row.Padding = New-Object Windows.Thickness 4,7,4,8

        $g = New-Object Windows.Controls.Grid
        foreach ($w in @('Auto','Star','Auto','Auto')) {
            $cd = New-Object Windows.Controls.ColumnDefinition
            $cd.Width = if ($w -eq 'Star') { New-Object Windows.GridLength 1, 'Star' } else { 'Auto' }
            $g.ColumnDefinitions.Add($cd)
        }
        $g.RowDefinitions.Add((New-Object Windows.Controls.RowDefinition))
        $g.RowDefinitions.Add((New-Object Windows.Controls.RowDefinition))

        $tile = New-GuiAppIconTile -App $app
        [Windows.Controls.Grid]::SetColumn($tile, 0)
        [Windows.Controls.Grid]::SetRowSpan($tile, 2)

        $name = New-Object Windows.Controls.TextBlock
        # The display fields, never the identity ones. A Store app's identity
        # is '5319275A.WhatsAppDesktop' or a bare GUID, and its publisher is a
        # certificate subject - neither helps anyone decide what to remove.
        $name.Text = $app.DisplayName
        $name.FontWeight = 'SemiBold'
        $name.Foreground = $brInk
        $name.TextTrimming = 'CharacterEllipsis'
        $name.ToolTip = if ($app.DisplayName -ne $app.Name) { "$($app.DisplayName)`n$($app.Name)" } else { $app.Name }
        [Windows.Controls.Grid]::SetColumn($name, 1)

        $meta = New-Object Windows.Controls.TextBlock
        $bits = @()
        if ($app.PublisherDisplay) { $bits += $app.PublisherDisplay }
        if ($app.Version)   { $bits += "v$($app.Version)" }
        if ($app.Kind -eq 'appx') { $bits += 'Store app' }
        $meta.Text = ($bits -join '  -  ')
        $meta.FontSize = 11.5
        $meta.Foreground = $brFaint
        $meta.TextTrimming = 'CharacterEllipsis'
        $meta.Margin = New-Object Windows.Thickness 0,2,0,0
        [Windows.Controls.Grid]::SetColumn($meta, 1)
        [Windows.Controls.Grid]::SetRow($meta, 1)

        $size = New-Object Windows.Controls.TextBlock
        $size.Text = if ($app.SizeMB -gt 0) { "$($app.SizeMB) MB" } else { '' }
        $size.Foreground = $brFaint
        $size.FontSize = 12
        $size.Width = 90
        $size.TextAlignment = 'Right'
        $size.VerticalAlignment = 'Center'
        $size.Margin = New-Object Windows.Thickness 10,0,14,0
        [Windows.Controls.Grid]::SetColumn($size, 2)
        [Windows.Controls.Grid]::SetRowSpan($size, 2)

        $btn = New-Object Windows.Controls.Button
        $btn.Style = $script:GuiWin.FindResource('Btn')
        $btn.Content = 'Remove'
        $btn.Tag = $app
        $btn.VerticalAlignment = 'Center'
        $btn.Add_Click({ Invoke-GuiUninstallApp $this.Tag })
        [Windows.Controls.Grid]::SetColumn($btn, 3)
        [Windows.Controls.Grid]::SetRowSpan($btn, 2)

        $g.Children.Add($tile) | Out-Null
        $g.Children.Add($name) | Out-Null
        $g.Children.Add($meta) | Out-Null
        $g.Children.Add($size) | Out-Null
        $g.Children.Add($btn)  | Out-Null
        $row.Child = $g
        $ui.PanelItems.Children.Add($row) | Out-Null
    }
}

function Invoke-GuiLoadApps {
    $script:GuiUi.TxtPhaseSub.Text = 'Reading installed applications...'
    $script:GuiWin.Dispatcher.Invoke([action]{}, 'Render')
    $script:GuiApps = @(Get-InstalledApplications)
    $script:GuiAppsLoaded = $true
    Update-GuiItems
}

function Invoke-GuiUninstallApp {
    param([Parameter(Mandatory)]$App)

    $answer = [Windows.MessageBox]::Show(
        "Uninstall $($App.DisplayName)?" + [Environment]::NewLine + [Environment]::NewLine +
        'Its own uninstaller runs first and may ask you questions. Afterwards Trim will show you ' +
        'anything it left behind, and remove only what you tick.',
        'Trim - uninstall', 'YesNo', 'Question', 'No')
    if ($answer -ne 'Yes') { return }

    $script:GuiUi.TxtPhaseSub.Text = "Uninstalling $($App.DisplayName)..."
    $script:GuiWin.Dispatcher.Invoke([action]{}, 'Render')
    [void](Invoke-AppUninstaller -App $App)

    $script:GuiUi.TxtPhaseSub.Text = 'Looking for leftovers...'
    $script:GuiWin.Dispatcher.Invoke([action]{}, 'Render')
    $script:GuiUninstallTarget = $App
    $script:GuiLeftovers = @(Get-AppLeftovers -App $App)
    $script:GuiUninstallStage = 'leftovers'
    Update-GuiItems
}

function Show-GuiLeftovers {
    $ui  = $script:GuiUi
    $app = $script:GuiUninstallTarget
    $ui.TxtPhase.Text = "Leftovers from $($app.DisplayName)"

    $back = New-Object Windows.Controls.Button
    $back.Style = $script:GuiWin.FindResource('Btn')
    $back.Content = 'Back to the app list'
    $back.HorizontalAlignment = 'Left'
    $back.Margin = New-Object Windows.Thickness 0,0,0,14
    $back.Add_Click({
        $script:GuiUninstallStage = 'list'
        $script:GuiAppsLoaded = $false
        Update-GuiItems
    })
    $ui.PanelItems.Children.Add($back) | Out-Null

    if ($script:GuiLeftovers.Count -eq 0) {
        $ui.TxtPhaseSub.Text = ''
        Add-GuiParagraph -Text 'Nothing left behind.' -Colour '#4FBFA4' -Size 14 -Weight 'SemiBold'
        Add-GuiParagraph -Text ('Either the uninstaller cleaned up after itself, or anything remaining did ' +
            'not clearly belong to this app - in which case Trim leaves it alone rather than guessing.') -Top 6
        return
    }

    $total = [double](($script:GuiLeftovers | Measure-Object Bytes -Sum).Sum)
    $ui.TxtPhaseSub.Text = "$($script:GuiLeftovers.Count) item(s), $(Format-Bytes $total)"

    Add-GuiParagraph -Text ('These survived the uninstaller. Every one is shown in full. ' +
        'Registry keys are exported to a .reg file before removal.') -Colour '#98A6A3' -Size 12
    Add-GuiParagraph -Text ' ' -Size 4

    $brInk   = Get-GuiBrush '#E6EDEB'
    $brFaint = Get-GuiBrush '#8C9A97'
    $brRule  = Get-GuiBrush '#2E3937'

    foreach ($l in $script:GuiLeftovers) {
        $row = New-Object Windows.Controls.Border
        $row.BorderBrush = $brRule
        $row.BorderThickness = New-Object Windows.Thickness 0,0,0,1
        $row.Padding = New-Object Windows.Thickness 4,6,4,7

        $g = New-Object Windows.Controls.Grid
        foreach ($w in @('Auto','Auto','Star','Auto')) {
            $cd = New-Object Windows.Controls.ColumnDefinition
            $cd.Width = if ($w -eq 'Star') { New-Object Windows.GridLength 1, 'Star' } else { 'Auto' }
            $g.ColumnDefinitions.Add($cd)
        }

        $cb = New-Object Windows.Controls.CheckBox
        $cb.IsChecked = [bool]$l.Selected
        $cb.Tag = $l
        $cb.VerticalAlignment = 'Center'
        $cb.Margin = New-Object Windows.Thickness 0,1,12,0
        $cb.Add_Click({ $this.Tag.Selected = [bool]$this.IsChecked })
        [Windows.Controls.Grid]::SetColumn($cb, 0)

        $kind = New-Object Windows.Controls.TextBlock
        $kind.Text = if ($l.Kind -eq 'registry') { 'REGISTRY' } else { 'FOLDER' }
        $kind.FontSize = 9.5
        $kind.FontWeight = 'Bold'
        $kind.Width = 68
        $kind.Foreground = if ($l.Kind -eq 'registry') { Get-GuiBrush '#D4A23E' } else { Get-GuiBrush '#4FBFA4' }
        $kind.VerticalAlignment = 'Center'
        [Windows.Controls.Grid]::SetColumn($kind, 1)

        $path = New-Object Windows.Controls.TextBlock
        $path.Text = $l.Path
        $path.FontFamily = New-Object Windows.Media.FontFamily 'Cascadia Mono, Consolas'
        $path.FontSize = 11.5
        $path.Foreground = $brInk
        $path.TextTrimming = 'CharacterEllipsis'
        $path.VerticalAlignment = 'Center'
        $path.ToolTip = $l.Path
        [Windows.Controls.Grid]::SetColumn($path, 2)

        $size = New-Object Windows.Controls.TextBlock
        $size.Text = $l.Size
        $size.FontSize = 12
        $size.Width = 84
        $size.TextAlignment = 'Right'
        $size.Foreground = $brFaint
        $size.VerticalAlignment = 'Center'
        [Windows.Controls.Grid]::SetColumn($size, 3)

        $g.Children.Add($cb)   | Out-Null
        $g.Children.Add($kind) | Out-Null
        $g.Children.Add($path) | Out-Null
        $g.Children.Add($size) | Out-Null
        $row.Child = $g
        $ui.PanelItems.Children.Add($row) | Out-Null
    }

    $del = New-Object Windows.Controls.Button
    $del.Style = $script:GuiWin.FindResource('Primary')
    $del.Content = 'Remove the ticked leftovers'
    $del.HorizontalAlignment = 'Left'
    $del.Margin = New-Object Windows.Thickness 0,18,0,0
    $del.Add_Click({ Invoke-GuiRemoveLeftovers })
    $ui.PanelItems.Children.Add($del) | Out-Null
}

function Invoke-GuiRemoveLeftovers {
    $sel = @($script:GuiLeftovers | Where-Object { $_.Selected })
    if ($sel.Count -eq 0) { return }
    $app = $script:GuiUninstallTarget

    $folders = @($sel | Where-Object { $_.Kind -eq 'folder' }).Count
    $keys    = @($sel | Where-Object { $_.Kind -eq 'registry' }).Count
    $answer = [Windows.MessageBox]::Show(
        "Permanently remove $folders folder(s) and $keys registry key(s) belonging to $($app.DisplayName)?" +
        [Environment]::NewLine + [Environment]::NewLine +
        'Registry keys are exported to .reg files first. Folders are not recoverable.',
        'Trim - confirm removal', 'YesNo', 'Warning', 'No')
    if ($answer -ne 'Yes') { return }

    $result = Remove-AppLeftovers -Leftovers $sel -AppName $app.Name -Publisher $app.Publisher
    $script:GuiLeftovers = @(Get-AppLeftovers -App $app)
    Update-GuiItems

    $msg = "$($result.Removed) item(s) removed, $(Format-Bytes ([double]$result.Freed)) freed."
    if ($result.Skipped -gt 0) { $msg += [Environment]::NewLine + "$($result.Skipped) left alone - in use, or refused by the safety check." }
    $msg += [Environment]::NewLine + [Environment]::NewLine + "Registry backups: $($result.BackupDir)"
    [void][Windows.MessageBox]::Show($msg, 'Trim - leftovers removed', 'OK', 'Information')
}

function Update-GuiItems {
    $ui = $script:GuiUi
    $ui.PanelItems.Children.Clear()
    $ui.ItemScroll.ScrollToTop()

    if ($script:GuiCurrent -eq 'Overview')     { Show-GuiOverview; return }
    if ($script:GuiCurrent -eq 'Disk cleanup')    { Show-GuiCleanup;   return }
    if ($script:GuiCurrent -eq 'Startup apps')   { Show-GuiStartup;   return }
    if ($script:GuiCurrent -eq 'Uninstall apps') { Show-GuiUninstall; return }

    $inPhase = @($script:GuiItems | Where-Object { $_.Phase -eq $script:GuiCurrent })
    $ui.TxtPhase.Text = $script:GuiCurrent

    $brInk   = Get-GuiBrush '#E6EDEB'
    $brFaint = Get-GuiBrush '#8C9A97'
    $brRule  = Get-GuiBrush '#2E3937'
    $tierBrush = @{
        safe  = Get-GuiBrush '#4FBFA4'
        op    = Get-GuiBrush '#D4A23E'
        trade = Get-GuiBrush '#E4785C'
    }

    foreach ($item in $inPhase) {
        $row = New-Object Windows.Controls.Border
        $row.BorderBrush     = $brRule
        $row.BorderThickness = New-Object Windows.Thickness 0,0,0,1
        # No left padding: the tier edge occupies that space instead, and the
        # content is inset from it by its own column.
        $row.Padding         = New-Object Windows.Thickness 0,8,4,9

        # A coloured left edge carries the tier where the eye already is. The
        # chip says the same thing 1100px away on a maximised window, which is
        # a long way to travel to find out whether a change is risky.
        $edge = New-Object Windows.Controls.Border
        $edge.Width  = 3
        $edge.CornerRadius = New-Object Windows.CornerRadius 1.5
        $edge.Background = $tierBrush[$item.Tier]
        $edge.Opacity = if ($item.Tier -eq 'safe') { 0.35 } else { 0.9 }
        $edge.VerticalAlignment = 'Stretch'
        $edge.Margin = New-Object Windows.Thickness 0,1,0,1

        $g = New-Object Windows.Controls.Grid
        foreach ($w in @('Auto','Star','Auto')) {
            $cd = New-Object Windows.Controls.ColumnDefinition
            $cd.Width = if ($w -eq 'Star') { New-Object Windows.GridLength 1, 'Star' } else { 'Auto' }
            $g.ColumnDefinitions.Add($cd)
        }
        $g.RowDefinitions.Add((New-Object Windows.Controls.RowDefinition))
        $g.RowDefinitions.Add((New-Object Windows.Controls.RowDefinition))

        $cb = New-Object Windows.Controls.CheckBox
        $cb.IsChecked = [bool]$item.Selected
        $cb.VerticalAlignment = 'Top'
        $cb.Margin = New-Object Windows.Thickness 0,2,12,0
        $cb.Tag = $item
        [Windows.Controls.Grid]::SetColumn($cb, 0)
        [Windows.Controls.Grid]::SetRow($cb, 0)
        [Windows.Controls.Grid]::SetRowSpan($cb, 2)
        # Counts only. Rebuilding this list from here destroys the very control
        # raising the event.
        $cb.Add_Click({ $this.Tag.Selected = [bool]$this.IsChecked; Update-GuiCounts })

        $title = New-Object Windows.Controls.TextBlock
        $title.Text = $item.Title
        $title.FontWeight = 'SemiBold'
        $title.TextWrapping = 'Wrap'
        $title.Foreground = $brInk
        [Windows.Controls.Grid]::SetColumn($title, 1)
        [Windows.Controls.Grid]::SetRow($title, 0)

        $detail = New-Object Windows.Controls.TextBlock
        $detail.Text = $item.Detail
        $detail.FontFamily = New-Object Windows.Media.FontFamily 'Cascadia Mono, Consolas'
        $detail.FontSize = 11.5
        $detail.Foreground = $brFaint
        $detail.TextTrimming = 'CharacterEllipsis'
        $detail.Margin = New-Object Windows.Thickness 0,3,0,0
        $detail.ToolTip = $item.Detail
        [Windows.Controls.Grid]::SetColumn($detail, 1)
        [Windows.Controls.Grid]::SetRow($detail, 1)
        [Windows.Controls.Grid]::SetColumnSpan($detail, 2)

        $chip = New-Object Windows.Controls.Border
        $chip.BorderBrush     = $tierBrush[$item.Tier]
        $chip.BorderThickness = New-Object Windows.Thickness 1
        $chip.CornerRadius    = New-Object Windows.CornerRadius 2
        $chip.Padding         = New-Object Windows.Thickness 6,1,6,1
        $chip.Margin          = New-Object Windows.Thickness 12,1,0,0
        $chip.Width           = 108
        $chip.VerticalAlignment = 'Top'
        $chipText = New-Object Windows.Controls.TextBlock
        $chipText.Text = $script:GuiTierName[$item.Tier]
        $chipText.FontSize = 9.5
        $chipText.FontWeight = 'Bold'
        $chipText.Foreground = $tierBrush[$item.Tier]
        $chipText.HorizontalAlignment = 'Center'
        $chip.Child = $chipText
        [Windows.Controls.Grid]::SetColumn($chip, 2)
        [Windows.Controls.Grid]::SetRow($chip, 0)

        $g.Children.Add($cb)     | Out-Null
        $g.Children.Add($title)  | Out-Null
        $g.Children.Add($detail) | Out-Null
        $g.Children.Add($chip)   | Out-Null

        # Two real columns rather than overlaid children. Stacking them in one
        # cell put the 3px edge underneath the checkbox, where it rendered as a
        # stray tick hanging off it.
        $wrap = New-Object Windows.Controls.Grid
        $cEdge = New-Object Windows.Controls.ColumnDefinition
        $cEdge.Width = 'Auto'
        $cBody = New-Object Windows.Controls.ColumnDefinition
        $cBody.Width = New-Object Windows.GridLength 1, 'Star'
        $wrap.ColumnDefinitions.Add($cEdge)
        $wrap.ColumnDefinitions.Add($cBody)

        [Windows.Controls.Grid]::SetColumn($edge, 0)
        $g.Margin = New-Object Windows.Thickness 13,0,0,0
        [Windows.Controls.Grid]::SetColumn($g, 1)

        $wrap.Children.Add($edge) | Out-Null
        $wrap.Children.Add($g)    | Out-Null
        $row.Child = $wrap

        # Hover feedback. A dense list gives no sense of which row the pointer
        # is on without it.
        $row.Add_MouseEnter({ $this.Background = $script:GuiRowHover })
        $row.Add_MouseLeave({ $this.Background = $null })

        $ui.PanelItems.Children.Add($row) | Out-Null
    }
}

function Set-GuiPhase {
    param([Parameter(Mandatory)][string]$Phase)
    $script:GuiCurrent = $Phase
    Update-GuiPhases
    Update-GuiItems
    Update-GuiCounts
}

function Set-GuiPreset {
    param([Parameter(Mandatory)][ValidateSet('recommended','advanced','everything','none')][string]$Name)

    $script:GuiPreset = $Name
    foreach ($i in $script:GuiItems) {
        # Three presets, three genuinely different sets.
        #
        # Recommended used to mean safe + caution, which on a normal machine is
        # every item there is - so it ticked everything and there was nothing
        # left to opt into. A change labelled "proceed with caution" has no
        # business being ticked on somebody's behalf anyway, so Caution moved up
        # a step and Recommended is now exactly what is safe anywhere.
        $i.Selected = switch ($Name) {
            'recommended' { $i.Tier -eq 'safe' }
            'advanced'    { $i.Tier -in @('safe','op') }
            'everything'  { $true }
            'none'        { $false }
        }
    }

    $ui = $script:GuiUi
    $brRaise  = Get-GuiBrush '#263130'
    $brAccent = Get-GuiBrush '#46C6B0'
    $brRule   = Get-GuiBrush '#2E3937'
    $brInk    = Get-GuiBrush '#E6EDEB'
    foreach ($pair in @(@('recommended',$ui.BtnRecommended), @('advanced',$ui.BtnAdvanced),
                        @('everything',$ui.BtnEverything), @('none',$ui.BtnClear))) {
        $on = ($pair[0] -eq $Name)
        $pair[1].BorderBrush = if ($on) { $brAccent } else { $brRule }
        $pair[1].Foreground  = if ($on) { $brAccent } else { $brInk }
        $pair[1].Background  = $brRaise
    }
    $ui.TxtPresetHint.Text = switch ($Name) {
        'recommended' { 'Only the changes that are safe on any system. The default.' }
        'advanced'    { 'Adds everything marked Caution. Read those first.' }
        'everything'  { 'Everything, risky changes included. Read the warning.' }
        'none'        { 'Nothing selected. Tick exactly what you want.' }
    }

    Update-GuiItems
    Update-GuiCounts
}


# ---------------------------------------------------------------------------
#  Applying: a window with a bar, not a wall of scrolling text
# ---------------------------------------------------------------------------

$script:ProgXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Trim" Height="260" Width="620" ResizeMode="NoResize"
        WindowStartupLocation="CenterScreen" Background="#171C1B"
        TextOptions.TextFormattingMode="Display" UseLayoutRounding="True">
  <Grid Margin="26,22,26,20">
    <Grid.RowDefinitions>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="*"/>
      <RowDefinition Height="Auto"/>
    </Grid.RowDefinitions>

    <StackPanel Grid.Row="0" Orientation="Horizontal" Margin="0,0,0,18">
      <Canvas Width="26" Height="26" Margin="0,0,12,0" VerticalAlignment="Center">
        <Rectangle Canvas.Left="1" Canvas.Top="3"    Width="24" Height="4.5" RadiusX="2.25" RadiusY="2.25" Fill="#46C6B0"/>
        <Rectangle Canvas.Left="1" Canvas.Top="10.5" Width="16" Height="4.5" RadiusX="2.25" RadiusY="2.25" Fill="#46C6B0" Opacity="0.72"/>
        <Rectangle Canvas.Left="1" Canvas.Top="18"   Width="9"  Height="4.5" RadiusX="2.25" RadiusY="2.25" Fill="#46C6B0" Opacity="0.45"/>
      </Canvas>
      <StackPanel VerticalAlignment="Center">
        <TextBlock x:Name="ProgTitle" Text="Applying changes" FontSize="17" FontWeight="SemiBold"
                   Foreground="#E6EDEB" FontFamily="Segoe UI Variable Text, Segoe UI"/>
        <TextBlock x:Name="ProgSub" Text="Do not turn off your PC." FontSize="12" Foreground="#8C9A97"
                   Margin="0,2,0,0" FontFamily="Segoe UI Variable Text, Segoe UI"/>
      </StackPanel>
    </StackPanel>

    <ProgressBar x:Name="ProgBar" Grid.Row="1" Height="8" Minimum="0" Maximum="100" Value="0"
                 Background="#263130" BorderThickness="0" Foreground="#46C6B0"/>

    <StackPanel Grid.Row="2" Margin="0,14,0,0">
      <TextBlock x:Name="ProgStatus" Text="Starting..." FontSize="13" Foreground="#E6EDEB"
                 TextTrimming="CharacterEllipsis" FontFamily="Segoe UI Variable Text, Segoe UI"/>
      <TextBlock x:Name="ProgCount" Text="" FontSize="11.5" Foreground="#8C9A97" Margin="0,5,0,0"
                 FontFamily="Segoe UI Variable Text, Segoe UI"/>
    </StackPanel>

    <Button x:Name="ProgClose" Grid.Row="3" Content="Close" HorizontalAlignment="Right"
            IsEnabled="False" Cursor="Hand"
            FontFamily="Segoe UI Variable Text, Segoe UI" FontSize="13" FontWeight="SemiBold">
      <Button.Style>
        <Style TargetType="Button">
          <Setter Property="Foreground" Value="#06211D"/>
          <Setter Property="Background" Value="#46C6B0"/>
          <Setter Property="Template">
            <Setter.Value>
              <ControlTemplate TargetType="Button">
                <Border Background="{TemplateBinding Background}" CornerRadius="4" Padding="22,7">
                  <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                </Border>
              </ControlTemplate>
            </Setter.Value>
          </Setter>
          <Style.Triggers>
            <!-- A button that looks pressable while the work is still running
                 invites a click that does nothing. -->
            <Trigger Property="IsEnabled" Value="False">
              <Setter Property="Background" Value="#263130"/>
              <Setter Property="Foreground" Value="#5A6B68"/>
              <Setter Property="Cursor" Value="Arrow"/>
            </Trigger>
          </Style.Triggers>
        </Style>
      </Button.Style>
    </Button>
  </Grid>
</Window>
'@

<#
.SYNOPSIS
    Show a progress window and run the work behind it.

.DESCRIPTION
    The status line is a plain description of the change being made right now,
    not the registry path being written - "Game Bar off", not
    "HKCU:\Software\Microsoft\GameBar\ShowStartupPanel".

    The work runs on the UI thread with the dispatcher pumped between steps.
    That is deliberate: a background runspace would need the whole module state
    marshalled into it, and this work is seconds of registry writes punctuated
    by processes we are waiting on anyway.
#>
function Invoke-WithProgress {
    param(
        [Parameter(Mandatory)][scriptblock]$Work,
        [Parameter(Mandatory)][int]$Total,
        [string]$Title = 'Applying changes'
    )

    Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
    [xml]$x = $script:ProgXaml
    $win = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $x))

    # NOT $title. PowerShell variable names are case-insensitive, so $title and
    # the $Title parameter are one variable - assigning the control destroys the
    # argument before it can be used.
    $bar     = $win.FindName('ProgBar')
    $status  = $win.FindName('ProgStatus')
    $counter = $win.FindName('ProgCount')
    $close   = $win.FindName('ProgClose')
    $heading = $win.FindName('ProgTitle')
    $sub     = $win.FindName('ProgSub')
    $heading.Text = $Title

    $icon = New-TrimIcon
    if ($icon) { $win.Icon = $icon }
    $win.Add_SourceInitialized({ Set-DarkTitleBar -Window $win })

    $frame = New-Object Windows.Threading.DispatcherFrame
    $win.Add_Closed({ $frame.Continue = $false }.GetNewClosure())
    $close.Add_Click({ $win.Close() }.GetNewClosure())

    $script:ProgWin      = $win
    $script:ProgBarCtl   = $bar
    $script:ProgStatCtl  = $status
    $script:ProgCountCtl = $counter

    Set-ProgressTotal -Total $Total
    $script:ProgressHook = {
        param($pct, $text)
        $script:ProgBarCtl.Value = $pct
        if ($text) { $script:ProgStatCtl.Text = $text }
        $script:ProgCountCtl.Text = "$($script:ProgressDone) of $($script:ProgressTotal)"
        $script:ProgWin.Dispatcher.Invoke([action]{}, 'Render')
    }

    $win.Show()
    $win.Dispatcher.Invoke([action]{}, 'Render')

    $failed = $null
    try { & $Work } catch { $failed = $_ }

    $script:ProgressHook = $null
    $bar.Value = 100

    if ($failed) {
        $heading.Text = 'Something went wrong'
        $sub.Text     = 'Nothing further was applied. The log has the detail.'
        $status.Text  = "$($failed.Exception.Message)"
        $bar.Foreground = [Windows.Media.BrushConverter]::new().ConvertFrom('#E4785C')
    } else {
        $heading.Text = 'Finished'
        # Not a foregone conclusion: Checkpoint-Computer fails on machines
        # where System Protection is blocked by policy, and this screen used to
        # promise a restore point on those runs too. Telling someone they have
        # a rollback they do not have is the worst thing on this screen to get
        # wrong.
        $sub.Text     = if ($script:RestorePointCreated -eq $false) {
            'Windows would not make a restore point, so the undo script is your way back.'
        } else {
            'A restore point was taken, and an undo script is waiting if you need it.'
        }
        $status.Text  = "$($script:Applied) change(s) applied."
        $counter.Text = "Undo script: $($script:UndoPath)"
    }
    $close.IsEnabled = $true
    $close.Focus() | Out-Null

    [Windows.Threading.Dispatcher]::PushFrame($frame)
    if ($failed) { throw $failed }
}

<#
.SYNOPSIS
    Show the window. Returns the selected items, or $null if it was closed.
#>
<#
.SYNOPSIS
    Open the window immediately, then fill it in.

.DESCRIPTION
    Building the plan takes a few seconds - enumerating scheduled tasks, walking
    game libraries, asking the driver what it supports. Doing that before the
    window appears means several seconds of nothing after a double click, which
    reads as a program that has not started.

    So the window opens first, on an empty plan, showing what it is doing. The
    scan runs on the UI thread with the dispatcher pumped between phases, which
    keeps the window painted and the phase name current.
#>
function Show-TrimWindow {
    param(
        [Parameter(Mandatory)]$Facts,
        [Parameter(Mandatory)][scriptblock]$BuildPlan
    )

    Initialize-TrimWindow -Items @() -Facts $Facts -AlreadyCorrect 0
    $script:GuiScanning = $true

    $frame = New-Object Windows.Threading.DispatcherFrame
    $script:GuiWin.Add_Closed({ $frame.Continue = $false }.GetNewClosure())

    $script:GuiWin.Show()
    Set-GuiPhase 'Overview'
    $script:GuiWin.Dispatcher.Invoke([action]{}, 'Render')

    # Each phase announces itself as it starts, so the window is never silent.
    $script:PhaseHook = {
        param($name)
        $script:GuiUi.TxtPhaseSub.Text = "Checking $name..."
        $script:GuiWin.Dispatcher.Invoke([action]{}, 'Render')
    }
    try { $plan = & $BuildPlan } finally { $script:PhaseHook = $null }

    $script:GuiItems   = @($plan.Items)
    $script:GuiPhases  = @($plan.Items | Select-Object -ExpandProperty Phase -Unique)
    $script:GuiAlready = [int]$plan.AlreadyCorrect
    $script:GuiScanning = $false

    Update-GuiPhases
    Set-GuiPreset 'recommended'
    Set-GuiPhase 'Overview'

    [Windows.Threading.Dispatcher]::PushFrame($frame)
    if (-not $script:GuiApplied) { return $null }
    return @($script:GuiItems | Where-Object { $_.Selected })
}

<#
.SYNOPSIS
    Build the window and wire it up, without showing it.

.DESCRIPTION
    Separate from Show-TrimWindow so the interaction test can drive presets,
    navigation and checkbox clicks without a human and without a visible window.
    The crash this file's header describes was only ever reachable by clicking,
    so it needed a test that clicks.
#>
function Initialize-TrimWindow {
    param(
        [Parameter(Mandatory)]$Items,
        [Parameter(Mandatory)]$Facts,
        [int]$AlreadyCorrect = 0
    )

    Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase

    [xml]$x = $script:GuiXaml
    $script:GuiWin = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $x))

    $ui = @{}
    foreach ($n in @('TxtMachine','PanelPhases','PanelItems','ItemScroll','TxtPhase','TxtPhaseSub',
                     'TxtCount','TxtNote','BannerBox','TxtBanner','TxtPresetHint',
                     'BtnRecommended','BtnAdvanced','BtnEverything','BtnClear','BtnApply','BtnCancel')) {
        $ui[$n] = $script:GuiWin.FindName($n)
        if (-not $ui[$n]) { throw "Window is missing control '$n'." }
    }

    if (-not $script:GuiRowHover) {
        $script:GuiRowHover = New-Object Windows.Media.SolidColorBrush (
            [Windows.Media.Color]::FromArgb(38, 0x46, 0xC6, 0xB0))
        $script:GuiRowHover.Freeze()
    }

    $script:GuiUi      = $ui
    $script:GuiItems   = @($Items)
    $script:GuiPhases  = @($Items | Select-Object -ExpandProperty Phase -Unique)
    $script:GuiFacts   = $Facts
    $script:GuiAlready = $AlreadyCorrect
    $script:GuiCurrent = 'Overview'
    $script:GuiApplied = $false

    $ui.TxtMachine.Text = "$($Facts.OSCaption) $($Facts.DisplayVersion)  -  " +
        "$(if ($Facts.IsLaptop) { 'laptop' } else { 'desktop' })  -  $($Facts.GpuNames -join ', ')"

    $ui.BtnRecommended.Add_Click({ Set-GuiPreset 'recommended' })
    $ui.BtnAdvanced.Add_Click({    Set-GuiPreset 'advanced' })
    $ui.BtnEverything.Add_Click({  Set-GuiPreset 'everything' })
    $ui.BtnClear.Add_Click({       Set-GuiPreset 'none' })
    $ui.BtnApply.Add_Click({  $script:GuiApplied = $true;  $script:GuiWin.Close() })
    $ui.BtnCancel.Add_Click({ $script:GuiApplied = $false; $script:GuiWin.Close() })

    $icon = New-TrimIcon
    if ($icon) { $script:GuiWin.Icon = $icon }
    $script:GuiWin.Add_SourceInitialized({ Set-DarkTitleBar -Window $script:GuiWin })

    Update-GuiPhases
    Set-GuiPreset 'recommended'
    Set-GuiPhase 'Overview'
    return $script:GuiWin
}

<#
.SYNOPSIS
    WPF needs a single-threaded apartment. PowerShell does not always provide one.
#>
function Test-CanShowGui {
    if ([Threading.Thread]::CurrentThread.GetApartmentState() -eq 'STA') { return $true }
    Write-Log -Level WARN -Message 'This PowerShell host is running MTA, which cannot host a window.'
    Write-Log -Level WARN -Message '  Relaunch with:  powershell.exe -STA -File trim.ps1 -Gui'
    return $false
}

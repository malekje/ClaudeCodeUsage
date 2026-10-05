# Claude usage widget - always-on-top window showing plan usage, with little Claudes living underneath.
# Run:   powershell -ExecutionPolicy Bypass -WindowStyle Hidden -File claude-usage.ps1   (or the "Claude Usage" desktop shortcut)
# Demo:  add -Demo to play a fast fake scenario (usage climbing, reset, boredom, bedtime, wake-up) without touching your login.
# Drag anywhere to move, drag the bottom-right corner to resize, - minimizes, x closes. Click a character to poke it.
# The characters also react to what Claude Code is doing, through claude-usage-hook.ps1 (see ~/.claude/settings.json hooks).
param([switch]$Demo)

# Per-monitor DPI awareness, set before WPF loads. Without it Windows stretches the window like a picture on a monitor
# whose scale differs from the main one (125% next to 100%), and the text gets blurry.
$PerMonitorDpiAware = 2
[AppContext]::SetSwitch('Switch.System.Windows.DoNotScaleForDpiChanges', $false)
$StandardDpi = 96
Add-Type -Namespace ClaudeUsage -Name Dpi -MemberDefinition @'
[DllImport("shcore.dll")] public static extern int SetProcessDpiAwareness(int awareness);
[DllImport("user32.dll")] public static extern uint GetDpiForSystem();
'@
[ClaudeUsage.Dpi]::SetProcessDpiAwareness($PerMonitorDpiAware) | Out-Null

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# ---------- settings ----------

# a script knows its folder in $PSScriptRoot; a ps2exe-built .exe does not, so ask the running process
$AppFolder = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent ([Diagnostics.Process]::GetCurrentProcess().MainModule.FileName) }
$CredentialsPath = Join-Path $env:USERPROFILE '.claude\.credentials.json'
$PlacementPath = Join-Path $AppFolder 'claude-usage.window.json'   # remembers the window size and position
$EventsPath = Join-Path $AppFolder 'claude-usage.events.jsonl'     # written by claude-usage-hook.ps1
$LastUsagePath = Join-Path $AppFolder 'claude-usage.last.json'      # last numbers received, shown at startup
$UsageUrl = 'https://api.anthropic.com/api/oauth/usage'   # undocumented endpoint, may change
$RefreshSeconds = if ($Demo) { 6 } else { 60 }            # 30 s got "429 Too Many Requests" from the server now and then
$MaxRefreshSeconds = 600                                  # slowest pace while the server keeps saying "too many requests"
$TooManyRequestsStatus = 429
# minutes without a prompt, Claude activity or usage change before each stage of winding down
$BoredAfterMinutes = if ($Demo) { 0.1 } else { 1 }        # toys come out
$DrowsyAfterMinutes = if ($Demo) { 0.3 } else { 3 }       # yawning, droopy eyes
$SleepAfterMinutes = if ($Demo) { 0.5 } else { 5 }        # bedtime
$ActivityTimeoutMinutes = 10                              # no hook event for this long => Claude is considered idle
$TranscriptTailBytes = 65536
$TiredPercent = 50
$AlertPercent = 80
$DayStartsHour = 7
$NightStartsHour = 19
$Limits = [ordered]@{
    five_hour        = 'Session limit'
    seven_day        = 'Weekly (all models)'
    seven_day_opus   = 'Weekly (Opus)'
    seven_day_sonnet = 'Weekly (Sonnet)'
}
# climbs, resets, then stays quiet long enough to show boredom, bedtime and sleep before the last value wakes everybody
$DemoSession = 16, 23, 30, 52, 60, 71, 84, 91, 96, 100, 100, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 12

$AnimationMilliseconds = 50
$SleepAnimationMilliseconds = 120   # slower frames while everybody sleeps: nothing moves fast, and it keeps the CPU quiet
$EventPollTicks = 10         # look for new hook events every 10 ticks
$BubbleTicks = 70            # one speech bubble stays up 70 x 50 ms = 3.5 s
$ApproachTimeoutTicks = 150
$ApproachSpeed = 2.0
$PaceSpeedFactor = 2.2
$CelebrateTicks = 80
$PromptPauseTicks = 30
$BlinkTicks = 3
$HopTicks = 10
$HopHeight = 12
$GroundY = 130
$PersonalSpace = 6           # gap kept between two characters
$MinVisiblePixels = 100      # how much of the window must be on a screen for a saved position to be reused
$MoodSpeed = @{ calm = 1.0; tired = 0.55; panic = 2.4; drowsy = 0.4; asleep = 0; exhausted = 0 }

# winding down and sleeping
$YawnOdds = 220              # 1 chance in N per tick, per drowsy character
$YawnTicks = 26
$BedCenters = 105, 195, 320  # where the three lie down, left to right; the fire burns between the last two
$FireCenter = 257
$FireLighterName = 'Opus'
$BedtimeSpeed = 1.5
$BedtimeTimeoutTicks = 400   # whoever has not reached a bed by then sleeps on the spot
$SleepwalkerName = 'Haiku'
$SleepwalkOdds = if ($Demo) { 120 } else { 1500 }
$SleepwalkTicks = 70
$SleepwalkSpeed = 0.6
$RollOverOdds = 400
$ZOdds = 12
$FireflyOdds = 15
$ShootingStarOdds = if ($Demo) { 100 } else { 500 }
$DreamOdds = 50
$DreamTicks = 35
$BreathDepth = 0.05
$BreathPeriodTicks = 6
$GroggyTicks = 100           # how long the sleepwalker stumbles around after waking up
$GroggySpeed = 0.5
$SkyFadeStep = 0.01          # sunset and sunrise take 100 ticks = 5 s
$SunTop = 6
$MoonTop = 4
$SkySinkPixels = 90          # how far the sun sinks and the moon rises during the fade

# the weather follows the session limit: clouds at $AlertPercent, then rain, then lightning, then everybody collapses
$RainPercent = 90
$LightningPercent = 95
$LimitPercent = 100
$LightningOdds = 120
$StormFadeStep = 0.02
$CloudColor = '#45443F'
$StormCloudColor = '#6B6962'

# forecast under the session bar
$SessionKey = 'five_hour'
$SessionWindowHours = 5
$MinForecastHours = 0.1      # too early to tell before that
$ContentWidth = 480

# a failed command: the others come and look
$GatherTicks = 120

# picking things up with the mouse
$PokeMaxPixels = 4           # a click that moved less than this is a poke, not a drag
$BounceMinSpeed = 3
$BounceFactor = 0.4
$MaxThrowSpeed = 12

# things falling from the sky, by season
$SeasonFlakes = @{
    winter = @{ Colors = @('#F5F4EE'); Odds = 6; Size = 3 }                       # snow
    spring = @{ Colors = @('#F5B8D0'); Odds = 20; Size = 3 }                      # petals
    autumn = @{ Colors = '#E8873A', '#7A5230', '#D9534B'; Odds = 15; Size = 4 }   # leaves
}
$TodayPath = Join-Path $AppFolder 'claude-usage.today.json'   # today's prompt and tool counts, kept across restarts
$ErrorLogPath = Join-Path $AppFolder 'claude-usage.error.txt'   # the last error in full, to send to whoever helps

# the party when a limit resets
$ResetMaxPercent = 10        # a limit that dropped to this or less has just reset
$PartyTicks = 400            # 20 s
$PartySpeedFactor = 2.6
$PartyTurnOdds = 20
$FireworkOdds = 18
$ShoutOdds = 25
$ConfettiColors = '#F2C14E', '#E5534B', '#5FB36A', '#8ECDF7', '#C9A0F5', '#F5F4EE', '#D97757'
$PartyShouts = 'Woo!', 'Fresh tokens!', 'Party!', 'Yeah!', '0%!', 'Again!'
$PartyReply = 'PARTY TIME!'
# they only show up for the party: Fable runs in from the left, Mythos from the right, and they go home afterwards
$GuestCast = @(
    @{ Name = 'Fable';  PixelSize = 5; Color = '#B58CE0'; Speed = 1.4; HomeSide = -1 }
    @{ Name = 'Mythos'; PixelSize = 7; Color = '#6FA8DC'; Speed = 0.9; HomeSide = 1 }
)

# bored time
$ChaserName = 'Haiku'        # runs after the butterfly; the others play with the ball
$ChaseSpeedFactor = 1.6
$SitOdds = 400
$BallSize = 8
$BallFriction = 0.97
$Gravity = 0.6
$ButterflyBaseTop = 78
$ButterflySwing = 22
$PokeReplies = 'Hey!', 'Ow!', 'Rude.', 'I was working!', 'That tickles.'
$HeldReplies = 'Put me down!', 'Whoa!', 'Aaah!', 'I can fly!'

$SkyColor = '#262624'
$SweatColor = '#8ECDF7'
$LabelColor = '#B5B3AA'
$TaskColor = '#3D3C38'
$AlertColor = '#E5534B'
$SparkColor = '#F2C14E'
$SmokeColor = '#8A8880'
$FireflyColor = '#D8F27A'
$BallColor = '#F5F4EE'
$ButterflyColor = '#C9A0F5'
# pixel letters that always mean the same colour; any other letter takes the colour of the thing being drawn
$Palette = @{ o = $SkyColor; y = '#F2C14E'; a = '#E8873A'; r = '#D9534B'; w = '#7A5230'; g = '#5FB36A'; s = '#B5B3AA'; k = '#3D3C38'; b = '#8ECDF7' }
# what the worker has next to it, by kind of task: a laptop, a magnifying glass, a terminal
$PropPixelSize = 3
$PropRows = @{
    edit = '.sssss.', '.sbbbs.', '.sbbbs.', '.sssss.', 'sssssss'
    read = '.sss...', 'sbbbs..', 'sbbbs..', '.sss...', '....ww.', '.....ww'
    run  = 'sssssss', 'skkkkks', 'skgkkks', 'skkggks', 'sssssss'
}
$PropMaxRows = 6
$BodyRows = '..XXXXXXXX..', '..XXXXXXXX..', 'XXXXXXXXXXXX', '..XXXXXXXX..', '..XXXXXXXX..'
$BlankRow = '............'
# frame 0 and 1 = walking legs, frame 2 = sitting (no legs, body resting on the ground)
$FrameRows = @(($BodyRows + '..X.X..X.X..'), ($BodyRows + '...X.XX.X...'), (@($BlankRow) + $BodyRows))
$EyeRows = $BlankRow, '...o....o...'
$LidRows = $BlankRow, '...X....X...'
$MouthRows = $BlankRow, $BlankRow, $BlankRow, '.....oo.....'
$SweatRows = @('..........X.')
$HatRows = '.....yy.....', '....rrrr....', '...gggggg...'   # party hat, worn above the head
$FirePixelSize = 4
$FireRows = @(
    ('...y...', '..ya...', '..aya..', '.aayaa.', '.rayar.', 'wwwwwww'),
    ('....y..', '...ay..', '..aya..', '.aayya.', '.raaar.', 'wwwwwww')
)
$DreamPixelSize = 3
$DreamPictureRows = @(
    ('.......', '......g', '.....gg', 'g...gg.', 'gg.gg..', '.ggg...', '..g....'),     # a passing build
    ('.rr.rr.', 'rrrrrrr', 'rrrrrrr', '.rrrrr.', '..rrr..', '...r...', '.......'),     # the human
    ('..yyy..', '.yyyyy.', 'yyyoyyy', 'yyyoyyy', 'yyyoyyy', '.yyyyy.', '..yyy..')      # tokens
)
$Cast = @(
    @{ Name = 'Opus';   PixelSize = 6; Color = '#D97757'; Speed = 0.8 }
    @{ Name = 'Sonnet'; PixelSize = 5; Color = '#E8A27E'; Speed = 1.2 }
    @{ Name = 'Haiku';  PixelSize = 4; Color = '#C2603F'; Speed = 1.7 }
)
$DefaultWorkerName = 'Opus'
$HelperMember = @{ Name = 'Agent'; PixelSize = 3; Color = '#B5B3AA'; Speed = 1.4 }   # walks in while a subagent runs

$SmallTalk = @(
    @{ Say = 'Is the human still typing?';      Reply = 'Always. Look busy.' }
    @{ Say = 'Who used all the context?';       Reply = '...it was a big file.' }
    @{ Say = 'I wrote 200 lines today.';        Reply = 'Could have been 50.' }
    @{ Say = 'It worked on the first try!';     Reply = 'Suspicious.' }
    @{ Say = 'Coffee break?';                   Reply = 'We run on tokens.' }
    @{ Say = 'Nice weather today.';             Reply = 'Is it? We live in a widget.' }
    @{ Say = 'You are absolutely right!';       Reply = 'Stop saying that.' }
    @{ Say = 'Want to play ball?';              Reply = 'After this task.' }
)
$UsageTalk = @(
    @{ Say = 'Session is at {s}%.';             Reply = 'Plenty of tokens left. Probably.' }
    @{ Say = 'Weekly is at {w}%.';              Reply = 'I blame Opus.' }
    @{ Say = '{reset}, by the way.';            Reply = 'Then we feast.' }
)
$TiredTalk = @{ Say = 'Past {s}%... my legs hurt.';         Reply = 'Walk slower. Like me.' }
$SessionAlertTalk = @{ Say = 'Session at {s}%! Slow down!'; Reply = 'Tell the human, not me.' }
$WeeklyAlertTalk = @{ Say = 'Weekly at {w}%...';            Reply = 'Short prompts only, everyone.' }
$GrowthReplies = 'The human is cooking.', 'Tokens go brrr.', 'Now at {s}% session.', 'I felt that one.'
$PromptTalk = @{ Say = 'New prompt! Look busy.';            Reply = 'On it.' }
$DoneTalk = @{ Say = 'Done!';                               Reply = 'Ship it.' }
$DrowsyTalk = @{ Say = 'Is the human gone?';                Reply = '*yawn*' }
$GoodNightTalk = @{ Say = 'Good night.';                    Reply = 'Five more minutes...'; Speaker = 'Sonnet'; Listener = 'Haiku' }
$ExhaustedTalk = @{ Say = 'Out of tokens...';               Reply = 'Wake me at the reset.' }
$FailTalk = @{ Say = 'It broke.';                           Reply = 'Read the error.' }
$FixedTalk = @{ Say = 'It works!';                          Reply = 'Never doubted it.' }
$FastPaceTalk = @{ Say = 'We will not make it to the reset!'; Reply = 'Tell the human to slow down.' }
$EasyPaceTalk = @{ Say = 'Easy pace today.';                Reply = 'Plenty left.' }
$NeedsYouText = 'Human! We need you!'
$TokenExpiredError = 'Login token expired'
$StatusErrorChars = 150   # an error body can be a whole web page; the window would shrink to show it all
$NoLoginError = 'No Claude Code login on this PC yet'
# the "Renew login" button: one tiny request on the cheapest model makes Claude Code renew the login itself
$RenewArguments = '-p hi --model haiku --no-session-persistence'
# where Claude Code lives when it is not on PATH: the native installer, and the copy Claude Desktop bundles
# (a Store install of Claude Desktop keeps its AppData under Packages\Claude_*\LocalCache)
$ClaudeProgramPatterns = @(
    (Join-Path $env:USERPROFILE '.local\bin\claude.exe'),
    (Join-Path $env:APPDATA 'Claude\claude-code\*\*\claude.exe'),
    (Join-Path $env:LOCALAPPDATA 'Packages\Claude_*\LocalCache\Roaming\Claude\claude-code\*\*\claude.exe')
)
$RenewTimeoutSeconds = 90
$LoginArguments = 'auth login'

# what the working character shows for each Claude Code tool; Kind picks its animation
$ToolTasks = @{
    Edit         = @{ Kind = 'edit'; Verb = 'editing' }
    Write        = @{ Kind = 'edit'; Verb = 'writing' }
    NotebookEdit = @{ Kind = 'edit'; Verb = 'editing' }
    Read         = @{ Kind = 'read'; Verb = 'reading' }
    Grep         = @{ Kind = 'read'; Verb = 'searching' }
    Glob         = @{ Kind = 'read'; Verb = 'searching' }
    WebSearch    = @{ Kind = 'read'; Verb = 'browsing' }
    WebFetch     = @{ Kind = 'read'; Verb = 'browsing' }
    Bash         = @{ Kind = 'run';  Verb = 'running' }
    PowerShell   = @{ Kind = 'run';  Verb = 'running' }
    Agent        = @{ Kind = 'other'; Verb = 'briefing a helper' }
    Task         = @{ Kind = 'other'; Verb = 'briefing a helper' }
}
$AttentionTools = 'AskUserQuestion', 'ExitPlanMode'                   # tools that wait for the human
$AttentionNotifications = 'permission_prompt', 'elicitation_dialog'

# ---------- window ----------

$window = [Windows.Markup.XamlReader]::Parse(@'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        Title="Claude usage" Width="720" Height="490" MinWidth="320" MinHeight="220" WindowStyle="None"
        AllowsTransparency="True" Background="Transparent" Topmost="True" ResizeMode="CanResizeWithGrip"
        FontFamily="Segoe UI">
  <Border Background="#262624" BorderBrush="#3D3C38" BorderThickness="1" CornerRadius="14" Padding="20,14,20,16">
    <Viewbox>
      <StackPanel Width="480">
        <DockPanel>
          <TextBlock Name="Close" DockPanel.Dock="Right" Text="&#215;" FontSize="20" Foreground="#B5B3AA" Background="Transparent" Padding="5,0,0,0" Cursor="Hand" ToolTip="Close"/>
          <TextBlock Name="Minimize" DockPanel.Dock="Right" Text="&#8211;" FontSize="20" Foreground="#B5B3AA" Background="Transparent" Padding="5,0,5,0" Cursor="Hand" ToolTip="Minimize"/>
          <TextBlock Text="&#10043;" FontFamily="Segoe UI Symbol" FontSize="18" Foreground="#D97757" VerticalAlignment="Center"/>
          <TextBlock Text="  Plan usage" FontSize="16" FontWeight="SemiBold" Foreground="#F5F4EE" VerticalAlignment="Center"/>
        </DockPanel>
        <StackPanel Name="Rows"/>
        <Canvas Name="Stage" Width="480" Height="150" Margin="0,14,0,0" ClipToBounds="True">
          <Canvas Name="Sky"/>
          <Rectangle Canvas.Top="130" Width="480" Height="2" Fill="#3D3C38"/>
          <Border Name="TaskBubble" Panel.ZIndex="9" BorderBrush="#D97757" BorderThickness="1" CornerRadius="8" Padding="8,3,8,3" Visibility="Hidden">
            <TextBlock Name="TaskText" FontSize="12" Foreground="#F5F4EE" MaxWidth="220" TextWrapping="Wrap"/>
          </Border>
          <Border Name="Bubble" Panel.ZIndex="10" Background="#F5F4EE" CornerRadius="8" Padding="8,4,8,4" Visibility="Hidden">
            <TextBlock Name="BubbleText" FontSize="13" Foreground="#262624" MaxWidth="220" TextWrapping="Wrap"/>
          </Border>
        </Canvas>
        <DockPanel Margin="0,8,0,0">
          <Border Name="Renew" DockPanel.Dock="Right" Visibility="Collapsed" Cursor="Hand" Background="#D97757" CornerRadius="6" Padding="10,3,10,3" Margin="10,0,0,0" VerticalAlignment="Top"
                  ToolTip="Runs a tiny Haiku request in the background so Claude Code renews the login">
            <TextBlock Name="RenewText" Text="Renew login" FontSize="12" FontWeight="SemiBold" Foreground="#262624"/>
          </Border>
          <TextBlock Name="Status" FontSize="11" Foreground="#B5B3AA" TextWrapping="Wrap" Text="Loading..."/>
        </DockPanel>
      </StackPanel>
    </Viewbox>
  </Border>
</Window>
'@)
$rows = $window.FindName('Rows')
$status = $window.FindName('Status')
$renewButton = $window.FindName('Renew')
$renewText = $window.FindName('RenewText')
$stage = $window.FindName('Stage')
$sky = $window.FindName('Sky')
$bubble = $window.FindName('Bubble')
$bubbleText = $window.FindName('BubbleText')
$taskBubble = $window.FindName('TaskBubble')
$taskText = $window.FindName('TaskText')
$random = New-Object Random

$pulseAnimation = New-Object Windows.Media.Animation.DoubleAnimation 1, 0.25, ([Windows.Duration][TimeSpan]::FromMilliseconds(350))
$pulseAnimation.AutoReverse = $true
$pulseAnimation.RepeatBehavior = New-Object Windows.Media.Animation.RepeatBehavior ([double]4)

function Get-RandomItem($items) { $items[$random.Next($items.Count)] }

function Get-RandomBetween($low, $high) { $low + ($high - $low) * $random.NextDouble() }

function Get-Visibility($visible) { if ($visible) { 'Visible' } else { 'Hidden' } }

function Set-Position($element, $left, $top) {
    [Windows.Controls.Canvas]::SetLeft($element, $left)
    [Windows.Controls.Canvas]::SetTop($element, $top)
}

# ---------- window placement ----------

function Restore-Placement {
    if (-not (Test-Path $PlacementPath)) { return }
    # an unreadable file must not stop the widget from opening: fall back to the default size
    try { $saved = Get-Content $PlacementPath -Raw | ConvertFrom-Json } catch { return }
    if (-not ($saved.Width -gt 0 -and $saved.Height -gt 0)) { return }
    $window.Width = $saved.Width
    $window.Height = $saved.Height
    # only reuse the position if it is still on a connected screen (the second monitor may be unplugged)
    $screen = [Windows.SystemParameters]
    $onScreen = $saved.Left -ge $screen::VirtualScreenLeft -and $saved.Top -ge $screen::VirtualScreenTop -and
        $saved.Left + $MinVisiblePixels -le $screen::VirtualScreenLeft + $screen::VirtualScreenWidth -and
        $saved.Top + $MinVisiblePixels -le $screen::VirtualScreenTop + $screen::VirtualScreenHeight
    if (-not $onScreen) { return }
    $window.WindowStartupLocation = 'Manual'
    $window.Left = $saved.Left
    $window.Top = $saved.Top
}

function Save-Placement {
    # a minimized window reports a parked off-screen position: keep the last real one
    if (-not $script:placementChanged -or $window.WindowState -ne 'Normal') { return }
    # Left/Top are read in the scale of the monitor the window is on, but applied at startup in the scale of the main
    # monitor: convert, or the window would open somewhere else when the two monitors have different scales
    $monitorScale = [Windows.Media.VisualTreeHelper]::GetDpi($window).DpiScaleX
    $toStartupUnits = $monitorScale * $StandardDpi / [ClaudeUsage.Dpi]::GetDpiForSystem()
    $placement = @{ Width = $window.ActualWidth; Height = $window.ActualHeight; Left = $window.Left * $toStartupUnits; Top = $window.Top * $toStartupUnits }
    $placement | ConvertTo-Json | Set-Content $PlacementPath -Encoding utf8
    $script:placementChanged = $false
}

# ---------- usage ----------

function Get-TimeLeft($resetsAt) {
    # PS 5.1 leaves ISO dates as strings, PS 7 converts them to DateTime
    $when = if ($resetsAt -is [datetime]) { $resetsAt.ToLocalTime() } else { [datetimeoffset]::Parse($resetsAt).LocalDateTime }
    $when - (Get-Date)
}

function Format-Duration($span) {
    if ($span.TotalDays -ge 1) { return '{0} d {1} hr' -f [math]::Floor($span.TotalDays), $span.Hours }
    if ($span.TotalHours -lt 1) { return '{0} min' -f $span.Minutes }
    '{0} hr {1} min' -f [math]::Floor($span.TotalHours), $span.Minutes
}

function Format-Reset($resetsAt) {
    if (-not $resetsAt) { return '' }
    $left = Get-TimeLeft $resetsAt
    if ($left.TotalMinutes -le 0) { return 'Resetting...' }
    'Resets in ' + (Format-Duration $left)
}

# Where the session is heading if the human keeps this pace: the limit before the reset, or some percentage at the reset.
# ponytail: straight line from the start of the 5-hour window; weight the last hour more if it proves too jumpy
function Get-Forecast($percent, $resetsAt) {
    if (-not $resetsAt) { return $null }
    $hoursLeft = (Get-TimeLeft $resetsAt).TotalHours
    $hoursUsed = $SessionWindowHours - $hoursLeft
    if ($hoursLeft -le 0 -or $hoursUsed -lt $MinForecastHours -or $percent -le 0) { return $null }
    if ($percent -ge $LimitPercent) { return @{ Text = 'Limit reached'; AtReset = $LimitPercent; TooFast = $true } }
    $percentPerHour = $percent / $hoursUsed
    $atReset = $percent + $percentPerHour * $hoursLeft
    if ($atReset -lt $LimitPercent) { return @{ Text = "At this pace: $([math]::Round($atReset))% at reset"; AtReset = $atReset; TooFast = $false } }
    $untilLimit = [TimeSpan]::FromHours(($LimitPercent - $percent) / $percentPerHour)
    @{ Text = 'At this pace: limit in ' + (Format-Duration $untilLimit); AtReset = $LimitPercent; TooFast = $true }
}

# $forecast (optional) adds a marker on the bar where the usage will be at reset time, and a line of text under it.
function Add-Row($label, $percent, $reset, $pulse, $forecast) {
    $barColor = if ($percent -ge $AlertPercent) { $AlertColor } else { '#D97757' }
    $marker = ''
    $forecastLine = ''
    if ($forecast) {
        $markerLeft = [math]::Max(0, [math]::Round($forecast.AtReset * $ContentWidth / 100) - 2)
        $forecastColor = if ($forecast.TooFast) { $AlertColor } else { $LabelColor }
        $marker = "<Rectangle Width='2' Fill='#F5F4EE' Opacity='0.75' HorizontalAlignment='Left' Margin='$markerLeft,0,0,0'/>"
        $forecastLine = "<TextBlock FontSize='11' Margin='0,3,0,0' Foreground='$forecastColor' Text='$($forecast.Text)'/>"
    }
    $row = [Windows.Markup.XamlReader]::Parse(@"
<StackPanel xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" Margin="0,12,0,0">
  <DockPanel>
    <TextBlock DockPanel.Dock="Right" FontSize="13" Foreground="#B5B3AA" VerticalAlignment="Bottom" Text="$reset   $percent%"/>
    <TextBlock FontSize="15" FontWeight="SemiBold" Foreground="#F5F4EE" Text="$label"/>
  </DockPanel>
  <Grid Margin="0,4,0,0" Height="12">
    <ProgressBar Height="8" VerticalAlignment="Center" Maximum="100" Value="$percent" Foreground="$barColor" Background="#3D3C38" BorderThickness="0"/>
    $marker
  </Grid>
  $forecastLine
</StackPanel>
"@)
    if ($pulse) { $row.Children[1].BeginAnimation([Windows.UIElement]::OpacityProperty, $pulseAnimation) }
    $rows.Children.Add($row) | Out-Null
}

function Get-DemoUsage {
    $session = $DemoSession[$script:demoStep % $DemoSession.Count]
    $script:demoStep++
    [pscustomobject]@{
        five_hour = [pscustomobject]@{ utilization = $session; resets_at = (Get-Date).AddMinutes(165).ToString('o') }
        seven_day = [pscustomobject]@{ utilization = 60; resets_at = (Get-Date).AddHours(18.5).ToString('o') }
    }
}

function Get-Usage {
    if ($Demo) { return Get-DemoUsage }
    $script:oauth = (Get-Content $CredentialsPath -Raw -ErrorAction Stop | ConvertFrom-Json).claudeAiOauth
    $token = $script:oauth.accessToken
    # Claude Desktop keeps its own login elsewhere; this file can exist with only other logins (MCP servers) in it
    if (-not $token) { throw $NoLoginError }
    # an expired token can only be answered with a 401: do not knock on the API every refresh, all day, for nothing
    $expiresAt = $script:oauth.expiresAt
    if ($expiresAt -and [datetimeoffset]::UtcNow.ToUnixTimeMilliseconds() -gt $expiresAt) { throw $TokenExpiredError }
    # ponytail: synchronous call pauses the animation while it runs (5s worst case); move to a runspace if that annoys
    Invoke-RestMethod -Uri $UsageUrl -TimeoutSec 5 -Headers @{ Authorization = "Bearer $token"; 'anthropic-beta' = 'oauth-2025-04-20' }
}

# A limit moved since the last refresh: wake everybody up and have somebody announce it.
function Register-Change($label, $delta, $percent) {
    $script:lastChange = Get-Date
    if ($delta -lt 0 -and $percent -le $ResetMaxPercent) { Start-Party $label; return }
    if ($script:announcement -or $delta -lt 0) { return }   # one announcement per refresh; the session limit is listed first so it wins
    $script:announcement = @{ Say = "${label}: +$delta%!"; Reply = (Get-RandomItem $GrowthReplies) }
}

# A limit is back to zero: everybody runs around hopping in party hats, the guests rush in, confetti and fireworks.
function Start-Party($label) {
    $script:partyTicksLeft = $PartyTicks
    $script:announcement = @{ Say = "$label reset! Fresh tokens!"; Reply = $PartyReply }
    foreach ($character in $characters) { $character.SitTicks = 0; $character.PauseTicks = 0; $character.GroggyTicks = 0 }
}

function Show-Usage($usage) {
    $rows.Children.Clear()
    foreach ($key in $Limits.Keys) {
        $limit = $usage.$key
        if ($null -eq $limit -or $null -eq $limit.utilization) { continue }
        $percent = [math]::Round([double]$limit.utilization)
        $previous = $script:previousPercent[$key]
        $delta = if ($null -eq $previous) { 0 } else { $percent - $previous }
        $script:previousPercent[$key] = $percent
        $forecast = if ($key -eq $SessionKey) { Get-Forecast $percent $limit.resets_at } else { $null }
        if ($key -eq $SessionKey) { $script:forecast = $forecast }
        Add-Row $Limits[$key] $percent (Format-Reset $limit.resets_at) ($delta -ne 0) $forecast
        if ($delta -ne 0) { Register-Change $Limits[$key] $delta $percent }
    }
    $script:sessionPercent = [math]::Round([double]$usage.five_hour.utilization)
    $script:weeklyPercent = [math]::Round([double]$usage.seven_day.utilization)
    $script:sessionReset = Format-Reset $usage.five_hour.resets_at
    Update-Mood
}

function Set-RefreshDelay($seconds) {
    $script:refreshDelay = $seconds
    $usageTimer.Interval = [TimeSpan]::FromSeconds($seconds)
}

# The server said "too many requests": wait as long as it asks, or twice as long as last time, before asking again.
function Suspend-Refresh($response) {
    $askedSeconds = 0
    [int]::TryParse("$($response.Headers['Retry-After'])", [ref]$askedSeconds) | Out-Null
    $seconds = [math]::Min($MaxRefreshSeconds, [math]::Max($askedSeconds, 2 * $script:refreshDelay))
    Set-RefreshDelay $seconds
    $nextTry = (Get-Date).AddSeconds($seconds).ToString('HH:mm:ss')
    $shown = if ($rows.Children.Count) { 'numbers kept from the last update' } else { 'no numbers yet' }
    $status.Text = "Usage server is busy - $shown, next try at $nextTry"
}

# The server may refuse the first call ("too many requests"): start from the numbers of the last run, not an empty window.
function Show-SavedUsage {
    if ($Demo -or -not (Test-Path $LastUsagePath)) { return }
    try { Show-Usage (Get-Content $LastUsagePath -Raw | ConvertFrom-Json) } catch { return }   # unreadable file: start empty
}

function Show-Error($message) {
    Set-Content $ErrorLogPath $message -Encoding utf8
    $short = ($message -replace '\s+', ' ').Trim()
    if ($short.Length -gt $StatusErrorChars) { $short = $short.Substring(0, $StatusErrorChars) + '...' }
    "Error: $short (full text in claude-usage.error.txt)"
}

function Update-Usage {
    try {
        $usage = Get-Usage
        Show-Usage $usage
        if (-not $Demo) { $usage | ConvertTo-Json -Depth 5 | Set-Content $LastUsagePath -Encoding utf8 }
        $status.Text = 'Updated ' + (Get-Date -Format 'HH:mm:ss') + $(if ($Demo) { '  (demo numbers)' })
        $renewButton.Visibility = 'Collapsed'
        $script:autoRenewTried = $false
        if ($script:refreshDelay -ne $RefreshSeconds) { Set-RefreshDelay $RefreshSeconds }
    } catch {
        $response = $_.Exception.Response
        if ($response -and [int]$response.StatusCode -eq $TooManyRequestsStatus) { Suspend-Refresh $response; return }
        if ($script:renewProcess) { return }   # the renew button is already working on it
        if ($_.Exception.Message -eq $NoLoginError -or ($_.Exception -is [Management.Automation.ItemNotFoundException])) { Start-Login; return }
        # ponytail: the token is never refreshed here (that would rotate it and could log Claude out); Claude Code renews it when used
        $rejected = $_.Exception.Message -eq $TokenExpiredError -or ($_.Exception.Response -and [int]$_.Exception.Response.StatusCode -eq 401)
        $expiresAt = $script:oauth.expiresAt
        $validUntil = if ($expiresAt) { [datetimeoffset]::FromUnixTimeMilliseconds($expiresAt).LocalDateTime.ToString('g') } else { 'unknown' }
        $status.Text = if ($rejected) { "Login token expired ($validUntil). Renewing it..." } else { Show-Error "$($_.Exception.Message) $($_.ErrorDetails.Message)" }
        $renewButton.Visibility = if ($rejected -and -not $script:renewProcess) { 'Visible' } else { 'Collapsed' }
        # renew by itself once per expiry; the button stays as the retry if that fails
        if ($rejected -and -not $script:autoRenewTried) { $script:autoRenewTried = $true; Start-Renew }
    }
}

# ---------- renewing the login ----------

function Find-ClaudeProgram {
    # Application skips npm's claude.ps1, which Start-Process would open in Notepad
    $onPath = Get-Command claude -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($onPath) { return $onPath.Source }
    # several Desktop versions can sit side by side: take the newest
    Get-ChildItem $ClaudeProgramPatterns -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1 -ExpandProperty FullName
}

# Claude Desktop keeps its login to itself, so a Desktop-only PC has no Claude Code login yet:
# open one Claude Code sign-in window (once per run) that writes it; the next refresh then shows the stats.
function Start-Login {
    if ($script:loginOpened) { return }
    $claudeProgram = Find-ClaudeProgram
    if (-not $claudeProgram) {
        $status.Text = 'Claude Code was not found on this PC. Install Claude Desktop or Claude Code, then restart this widget.'
        return
    }
    $script:loginOpened = $true
    Start-Process $claudeProgram -ArgumentList $LoginArguments
    $status.Text = 'First run: sign in to Claude in the window that just opened. Your stats show up here right after.'
}

function Start-Renew {
    if ($script:renewProcess) { return }
    $claudeProgram = Find-ClaudeProgram
    if (-not $claudeProgram) {
        $status.Text = 'Claude Code was not found on this PC. Open the Code tab in Claude Desktop once (it renews the login), or install Claude Code.'
        return
    }
    $renewButton.Visibility = 'Collapsed'
    $status.Text = 'Renewing the login with a tiny Haiku request...'
    $script:renewProcess = Start-Process $claudeProgram -ArgumentList $RenewArguments -WindowStyle Hidden -PassThru
    $script:renewStarted = Get-Date
    $renewTimer.Start()
}

function Step-Renew {
    $process = $script:renewProcess
    $timedOut = ((Get-Date) - $script:renewStarted).TotalSeconds -gt $RenewTimeoutSeconds
    if (-not $process.HasExited -and -not $timedOut) { return }
    $renewTimer.Stop()
    $script:renewProcess = $null
    if (-not $process.HasExited) {
        taskkill /T /F /PID $process.Id | Out-Null   # /T: claude runs under cmd, kill both
        $status.Text = "Renewing took longer than $RenewTimeoutSeconds s and was stopped. Run claude in a terminal to see why."
        $renewButton.Visibility = 'Visible'
        return
    }
    if ($process.ExitCode -ne 0) {
        $status.Text = "Renewing failed (exit code $($process.ExitCode)). Run claude in a terminal and log in again."
        $renewButton.Visibility = 'Visible'
        return
    }
    Set-RefreshDelay $RefreshSeconds
    Update-Usage
}

# ---------- mood: calm / tired / panic follow usage; drowsy and asleep follow how long nothing has happened ----------

function Update-Mood {
    $idleMinutes = ((Get-Date) - $script:lastChange).TotalMinutes
    $resting = $script:activity -eq 'idle'   # nobody dozes off while Claude is working or waiting for the human
    $previous = $script:mood
    $script:mood = if ($script:sessionPercent -ge $LimitPercent) { 'exhausted' }   # out of tokens: flat on the ground until the reset
        elseif ($resting -and $idleMinutes -ge $SleepAfterMinutes) { 'asleep' }
        elseif ($resting -and $idleMinutes -ge $DrowsyAfterMinutes) { 'drowsy' }
        elseif ($script:sessionPercent -ge $AlertPercent) { 'panic' }
        elseif ($script:sessionPercent -ge $TiredPercent) { 'tired' }
        else { 'calm' }
    $script:bored = $resting -and $idleMinutes -ge $BoredAfterMinutes -and $script:mood -in 'calm', 'tired'
    if ($script:mood -eq $previous) { return }
    if ($script:mood -eq 'asleep') { Start-Bedtime }
    if ($previous -eq 'asleep') { Stop-Bedtime }
    if ($script:mood -eq 'drowsy') { $script:announcement = $DrowsyTalk }
    if ($script:mood -eq 'exhausted') { $script:announcement = $ExhaustedTalk }
}

# Dusk falls, everybody gets a place by the fire (in their current left-to-right order, so nobody has to cross anybody).
function Start-Bedtime {
    if ($script:conversation) { Stop-Conversation }
    $script:bedtimeTicks = 0
    $script:isNight = $true
    $inOrder = @($characters | Sort-Object X)
    for ($i = 0; $i -lt $inOrder.Count; $i++) { $inOrder[$i].BedCenter = $BedCenters[$i] }
    $script:announcement = $GoodNightTalk
}

# Something happened: "!" over every head, the fire goes out, the sky snaps back. The sleepwalker stays groggy for a while.
function Stop-Bedtime {
    foreach ($character in $characters) {
        $character.Sleeping = $false
        $character.SleepwalkTicks = 0
        Add-TextParticle '!' $SparkColor 16 ((Get-Center $character) - 2) ($character.Top - 22) 0 (-0.4) 25
        if ($character.Name -eq $SleepwalkerName) { $character.GroggyTicks = $GroggyTicks } else { $character.HopTick = 1 }
    }
    Set-Fire $false
    $dreamBubble.Visibility = 'Hidden'
    $script:dreamTicksLeft = 0
    $script:isNight = Test-Night
    $script:nightLevel = [int]$script:isNight
}

# ---------- Claude Code activity (hook events) ----------

# Reads only the tail of the session transcript, to find which model answered last ("opus", "sonnet", "haiku").
function Get-TranscriptModelFamily($transcriptPath) {
    if (-not $transcriptPath -or -not (Test-Path $transcriptPath)) { return $null }
    $stream = [IO.File]::Open($transcriptPath, 'Open', 'Read', 'ReadWrite')
    try {
        $tailLength = [int][math]::Min($stream.Length, $TranscriptTailBytes)
        $stream.Seek(-$tailLength, 'End') | Out-Null
        $buffer = New-Object byte[] $tailLength
        $readCount = $stream.Read($buffer, 0, $tailLength)
    } finally { $stream.Dispose() }
    $tail = [Text.Encoding]::UTF8.GetString($buffer, 0, $readCount)
    $models = [regex]::Matches($tail, '"model":"claude-([a-z]+)')
    if ($models.Count -eq 0) { return $null }
    $models[$models.Count - 1].Groups[1].Value
}

function Get-Task($hookEvent) {
    $known = $ToolTasks["$($hookEvent.tool)"]
    # unknown tools (MCP ones are named mcp__server__tool) show their short name
    if (-not $known) { return @{ Kind = 'other'; Text = 'using ' + ("$($hookEvent.tool)" -split '__')[-1] } }
    $text = if ($hookEvent.detail) { "$($known.Verb) $($hookEvent.detail)" } else { "$($known.Verb)..." }
    @{ Kind = $known.Kind; Text = $text }
}

function Set-ToolActivity($hookEvent, $busyActivity) {
    $family = Get-TranscriptModelFamily $hookEvent.transcript
    $modelCharacter = $characters | Where-Object { $_.Name -eq $family } | Select-Object -First 1
    if ($modelCharacter) { $script:worker = $modelCharacter }
    $script:task = Get-Task $hookEvent
    $script:activity = if ($hookEvent.tool -in $AttentionTools) { 'needsYou' } else { $busyActivity }
    # the laptop, magnifying glass or terminal goes next to the worker, on whichever side has room
    $propWidth = $PropRows.edit[0].Length * $PropPixelSize
    $propLeft = $script:worker.X + $script:worker.Width + 2
    if ($propLeft -gt $stage.Width - $propWidth) { $propLeft = $script:worker.X - $propWidth - 2 }
    [Windows.Controls.Canvas]::SetLeft($propStand, $propLeft)
}

# A command failed: the worker despairs and the others come over to look. The next time that tool works, they cheer.
function Register-Failure($hookEvent) {
    if ($ToolTasks["$($hookEvent.tool)"].Kind -ne 'run') { return }   # failed edits and searches are routine; a broken command is news
    $script:failedTool = $hookEvent.tool
    $script:gatherTicksLeft = $GatherTicks
    $script:announcement = $FailTalk
    Add-TextParticle 'Ugh.' $AlertColor 12 $script:worker.X ($script:worker.Top - 34) 0 (-0.5) 40
}

function Register-Success($hookEvent, $busyActivity) {
    if ($script:activity -eq 'needsYou') { $script:activity = $busyActivity }
    if (-not $script:failedTool -or $hookEvent.tool -ne $script:failedTool) { return }
    $script:failedTool = $null
    $script:celebrateTicksLeft = $CelebrateTicks
    $script:announcement = $FixedTalk
}

function Restore-Today {
    $script:today = @{ Date = (Get-Date -Format 'yyyy-MM-dd'); Prompts = 0; Tools = 0 }
    if ($Demo -or -not (Test-Path $TodayPath)) { return }
    try { $saved = Get-Content $TodayPath -Raw | ConvertFrom-Json } catch { return }   # unreadable file: count from zero
    if ("$($saved.Date)" -ne $script:today.Date) { return }
    $script:today.Prompts = [int]$saved.Prompts
    $script:today.Tools = [int]$saved.Tools
}

function Add-TodayCount($field) {
    if ($script:today.Date -ne (Get-Date -Format 'yyyy-MM-dd')) { Restore-Today }   # past midnight: a new day starts at zero
    $script:today[$field]++
    $script:todayChanged = $true
}

function Save-Today {
    if ($Demo -or -not $script:todayChanged) { return }
    $script:today | ConvertTo-Json | Set-Content $TodayPath -Encoding utf8
    $script:todayChanged = $false
}

# ponytail: events from several Claude sessions are treated as one stream, the latest event wins; key by session id if that gets confusing
function Receive-HookEvent($hookEvent) {
    $script:lastHookEvent = Get-Date
    $script:lastChange = Get-Date   # Claude doing something keeps everybody awake
    $busyActivity = if ($hookEvent.mode -eq 'plan') { 'planning' } else { 'working' }
    switch ($hookEvent.event) {
        'UserPromptSubmit' {
            $script:activity = $busyActivity
            $script:task = $null
            $script:announcement = $PromptTalk
            foreach ($character in $characters) { $character.PauseTicks = $PromptPauseTicks }
            Add-TodayCount 'Prompts'
        }
        'PreToolUse'         { Set-ToolActivity $hookEvent $busyActivity; Add-TodayCount 'Tools' }
        'PostToolUse'        { Register-Success $hookEvent $busyActivity }
        'PostToolUseFailure' { Register-Failure $hookEvent }
        'PermissionRequest' { $script:activity = 'needsYou' }
        'Notification'      { if ($hookEvent.kind -in $AttentionNotifications) { $script:activity = 'needsYou' } }
        'SubagentStart'     { $script:subagents++ }
        'SubagentStop'      { $script:subagents = [math]::Max(0, $script:subagents - 1) }
        'Stop' {
            $script:activity = 'idle'
            $script:task = $null
            $script:celebrateTicksLeft = $CelebrateTicks
            $script:announcement = $DoneTalk
        }
    }
    Update-Mood
}

function Read-HookEvents {
    if (-not (Test-Path $EventsPath)) { return }
    $stream = [IO.File]::Open($EventsPath, 'Open', 'Read', 'ReadWrite')
    try {
        if ($stream.Length -lt $script:eventsOffset) { $script:eventsOffset = 0 }   # the hook started a fresh file
        if ($stream.Length -eq $script:eventsOffset) { return }
        $stream.Seek($script:eventsOffset, 'Begin') | Out-Null
        $bytes = New-Object byte[] ($stream.Length - $script:eventsOffset)
        $readCount = $stream.Read($bytes, 0, $bytes.Length)
    } finally { $stream.Dispose() }
    # only complete lines: the hook may be in the middle of writing the last one
    $lastNewline = [Array]::LastIndexOf($bytes, [byte]10, $readCount - 1)
    if ($lastNewline -lt 0) { return }
    $script:eventsOffset += $lastNewline + 1
    foreach ($line in [Text.Encoding]::UTF8.GetString($bytes, 0, $lastNewline + 1) -split "`n") {
        if (-not $line.Trim()) { continue }
        try { $hookEvent = $line | ConvertFrom-Json } catch { continue }   # file input: skip a damaged line
        Receive-HookEvent $hookEvent
    }
}

# A long silence means the session ended without a Stop event (closed window, crash): go back to idle.
function Reset-StaleActivity {
    if (((Get-Date) - $script:lastHookEvent).TotalMinutes -lt $ActivityTimeoutMinutes) { return }
    $script:activity = 'idle'
    $script:task = $null
    $script:subagents = 0
}

# ---------- particles: small things that drift, fade in and out, then disappear (z's, sparks, smoke, fireflies...) ----------

function Add-Particle($element, $x, $y, $velocityX, $velocityY, $life) {
    $element.Opacity = 0
    $element.IsHitTestVisible = $false
    Set-Position $element $x $y
    $stage.Children.Add($element) | Out-Null
    $script:particles.Add(@{ Element = $element; X = $x; Y = $y; VelocityX = $velocityX; VelocityY = $velocityY; Life = $life; MaxLife = $life }) | Out-Null
}

function Add-TextParticle($text, $color, $fontSize, $x, $y, $velocityX, $velocityY, $life) {
    $label = New-Label $text $fontSize
    $label.Foreground = $color
    $label.FontWeight = 'SemiBold'
    Add-Particle $label $x $y $velocityX $velocityY $life
}

function Add-DotParticle($size, $color, $x, $y, $velocityX, $velocityY, $life) {
    $dot = New-Object Windows.Shapes.Ellipse
    $dot.Width = $size
    $dot.Height = $size
    $dot.Fill = $color
    Add-Particle $dot $x $y $velocityX $velocityY $life
}

function Update-Particles {
    foreach ($particle in @($script:particles)) {
        $particle.Life--
        if ($particle.Life -le 0) {
            $stage.Children.Remove($particle.Element)
            $script:particles.Remove($particle)
            continue
        }
        $particle.X += $particle.VelocityX
        $particle.Y += $particle.VelocityY
        Set-Position $particle.Element $particle.X $particle.Y
        $particle.Element.Opacity = [math]::Sin([math]::PI * $particle.Life / $particle.MaxLife)
    }
}

function Add-Firework {
    $x = Get-RandomBetween 40 440
    $y = Get-RandomBetween 15 60
    $color = Get-RandomItem $ConfettiColors
    foreach ($spoke in 0..11) {
        $angle = $spoke * [math]::PI / 6
        Add-DotParticle 3 $color $x $y (2 * [math]::Cos($angle)) (2 * [math]::Sin($angle)) 22
    }
}

function Update-Party {
    if ($script:partyTicksLeft -le 0) { return }
    $script:partyTicksLeft--
    foreach ($piece in 1..2) {
        Add-DotParticle 4 (Get-RandomItem $ConfettiColors) (Get-RandomBetween 0 $stage.Width) 0 (Get-RandomBetween (-0.5) 0.5) (Get-RandomBetween 1.5 3) ($random.Next(45, 70))
    }
    if ($random.Next($FireworkOdds) -eq 0) { Add-Firework }
    if ($random.Next($ShoutOdds) -ne 0) { return }
    $reveller = Get-RandomItem ($characters + $guests)
    Add-TextParticle (Get-RandomItem $PartyShouts) (Get-RandomItem $ConfettiColors) 12 $reveller.X ($reveller.Top - 40) 0 (-0.6) 30
}

# ---------- sky ----------

function New-Shape($typeName, $width, $height, $fill, $left, $top, $parent) {
    $shape = New-Object "Windows.Shapes.$typeName"
    $shape.Width = $width
    $shape.Height = $height
    $shape.Fill = $fill
    Set-Position $shape $left $top
    $parent.Children.Add($shape) | Out-Null
    $shape
}

function New-Cloud($left, $top, $width, $color, $parent) {
    $cloud = New-Object Windows.Controls.Canvas
    New-Shape Rectangle $width 8 $color 0 6 $cloud | Out-Null
    New-Shape Rectangle ($width * 0.5) 6 $color ($width * 0.2) 0 $cloud | Out-Null
    Set-Position $cloud $left $top
    $parent.Children.Add($cloud) | Out-Null
    $cloud
}

# A white flash, a bolt from the clouds to the ground, and everybody who is awake jumps.
function Add-Lightning {
    $flash = New-Object Windows.Shapes.Rectangle
    $flash.Width = $stage.Width
    $flash.Height = $GroundY
    $flash.Fill = '#66F5F4EE'
    Add-Particle $flash 0 0 0 0 6
    $bolt = New-Object Windows.Shapes.Polyline
    $bolt.Stroke = $Palette.y
    $bolt.StrokeThickness = 2
    foreach ($corner in '0,0', '-7,32', '4,36', '-5,70', '6,74', '-2,104') { $bolt.Points.Add([Windows.Point]::Parse($corner)) }
    Add-Particle $bolt (Get-RandomBetween 40 440) 24 0 0 8
    foreach ($character in $characters) { if (-not $character.Sleeping -and $script:mood -ne 'exhausted') { $character.HopTick = 1 } }
}

# ponytail: seasons of the northern hemisphere; flip the months if this ever runs south of the equator
function Get-Season {
    switch ((Get-Date).Month) {
        { $_ -in 12, 1, 2 } { return 'winter' }
        { $_ -in 3, 4, 5 }  { return 'spring' }
        { $_ -in 6, 7, 8 }  { return 'summer' }
    }
    'autumn'
}

# Storm clouds gather as the session limit gets close, then rain, then lightning. Snow, petals or leaves follow the season.
function Update-Weather {
    $stormGap = [int]($script:sessionPercent -ge $AlertPercent) - $stormClouds.Opacity
    $stormClouds.Opacity += [math]::Max(-$StormFadeStep, [math]::Min($StormFadeStep, $stormGap))
    if ($script:sessionPercent -ge $RainPercent) {
        foreach ($drop in 1..2) {
            $rain = New-Object Windows.Shapes.Rectangle
            $rain.Width = 1
            $rain.Height = 7
            $rain.Fill = $Palette.b
            Add-Particle $rain (Get-RandomBetween 0 $stage.Width) 20 (-1) 7 16
        }
    }
    if ($script:sessionPercent -ge $LightningPercent -and $random.Next($LightningOdds) -eq 0) { Add-Lightning }
    $flakes = $SeasonFlakes[(Get-Season)]
    if (-not $flakes -or $random.Next($flakes.Odds) -ne 0) { return }
    Add-DotParticle $flakes.Size (Get-RandomItem $flakes.Colors) (Get-RandomBetween 0 $stage.Width) 0 (Get-RandomBetween (-0.4) 0.4) 1.2 105
}

# The wooden sign: today's prompts and tool calls, or the time until the reset when the tokens are gone.
function Update-Sign {
    $script:partyDay = (Get-Date).DayOfWeek -eq 'Friday'   # party hats all day
    if ($script:mood -eq 'exhausted') {
        $signTitle.Text = 'Out of tokens'
        $signDetail.Text = "$script:sessionReset" -replace '^Resets in', 'Back in'
        return
    }
    $signTitle.Text = 'Today: ' + (Format-Count $script:today.Prompts 'prompt')
    $signDetail.Text = Format-Count $script:today.Tools 'tool call'
}

function Format-Count($count, $noun) { "$count $noun" + $(if ($count -ne 1) { 's' }) }

function Update-Prop {
    $kind = if ($script:activity -eq 'working' -and $script:mood -ne 'asleep') { "$($script:task.Kind)" } else { '' }
    foreach ($propKind in $props.Keys) { $props[$propKind].Visibility = Get-Visibility ($propKind -eq $kind) }
}

function Test-Night {
    # demo flips day and night every 20 seconds so both can be seen
    if ($Demo) { return [math]::Floor((Get-Date).Second / 20) % 2 -eq 1 }
    $hour = (Get-Date).Hour
    $hour -lt $DayStartsHour -or $hour -ge $NightStartsHour
}

function Add-ShootingStar {
    $streak = New-Object Windows.Shapes.Rectangle
    $streak.Width = 16
    $streak.Height = 2
    $streak.Fill = '#F5F4EE'
    $streak.RenderTransform = New-Object Windows.Media.RotateTransform 18
    Add-Particle $streak (Get-RandomBetween 30 300) (Get-RandomBetween 4 40) 7 2.3 22
}

# Day and night cross-fade: the sun sinks into an orange horizon while the moon rises, and back.
function Update-Sky {
    if ($script:tick % 20 -eq 1) { $script:isNight = (Test-Night) -or $script:mood -eq 'asleep' }
    $gap = [int]$script:isNight - $script:nightLevel
    $script:nightLevel += [math]::Max(-$SkyFadeStep, [math]::Min($SkyFadeStep, $gap))
    $daySky.Opacity = 1 - $script:nightLevel
    $nightSky.Opacity = $script:nightLevel
    $sunset.Opacity = 4 * $script:nightLevel * (1 - $script:nightLevel)   # strongest half-way through
    [Windows.Controls.Canvas]::SetTop($sun, $SunTop + $script:nightLevel * $SkySinkPixels)
    [Windows.Controls.Canvas]::SetTop($moon, $MoonTop + (1 - $script:nightLevel) * $SkySinkPixels)
    if ($script:tick % 3 -eq 0) { (Get-RandomItem $stars).Opacity = 0.2 + 0.8 * $random.NextDouble() }
    if ($script:nightLevel -gt 0.9 -and $random.Next($ShootingStarOdds) -eq 0) { Add-ShootingStar }
    foreach ($cloud in $clouds) {
        $left = [Windows.Controls.Canvas]::GetLeft($cloud) + 0.15
        if ($left -gt $stage.Width) { $left = -60 }
        [Windows.Controls.Canvas]::SetLeft($cloud, $left)
    }
}

# ---------- campfire, dreams and the rest of the night ----------

function Set-Fire($lit) {
    if ($lit -eq $script:fireLit) { return }
    $script:fireLit = $lit
    $fire.Visibility = Get-Visibility $lit
    $glow.Visibility = Get-Visibility $lit
    # sparks when it catches, a puff of smoke when it goes out
    $color = if ($lit) { $SparkColor } else { $SmokeColor }
    foreach ($puff in 1..8) {
        Add-DotParticle 4 $color $FireCenter ($GroundY - 20) (Get-RandomBetween (-0.8) 0.8) (Get-RandomBetween (-1.2) (-0.4)) 35
    }
}

function Update-Fire {
    if (-not $script:fireLit) { return }
    $flame = [int][math]::Floor($script:tick / 3) % $fireFrames.Count
    for ($i = 0; $i -lt $fireFrames.Count; $i++) { $fireFrames[$i].Visibility = Get-Visibility ($i -eq $flame) }
    $glow.Opacity = Get-RandomBetween 0.6 1
    if ($random.Next(10) -eq 0) { Add-DotParticle 2 $SparkColor (Get-RandomBetween ($FireCenter - 8) ($FireCenter + 8)) ($GroundY - 24) (Get-RandomBetween (-0.3) 0.3) (-0.8) 25 }
}

# Now and then a sleeper dreams of a passing build, the human, or tokens.
function Update-Dream {
    if ($script:dreamTicksLeft -gt 0) {
        $script:dreamTicksLeft--
        if ($script:dreamTicksLeft -eq 0) { $dreamBubble.Visibility = 'Hidden' }
        return
    }
    $sleepers = @($characters | Where-Object { $_.Sleeping })
    if ($sleepers.Count -eq 0 -or $random.Next($DreamOdds) -ne 0) { return }
    $dreamtOf = $random.Next($dreamPictures.Count)
    for ($i = 0; $i -lt $dreamPictures.Count; $i++) { $dreamPictures[$i].Visibility = Get-Visibility ($i -eq $dreamtOf) }
    Set-BubbleAbove $dreamBubble (Get-RandomItem $sleepers) 0
    $script:dreamTicksLeft = $DreamTicks
}

function Update-Night {
    if ($script:mood -ne 'asleep') { return }
    $script:bedtimeTicks++
    if ($lighter.Sleeping) { Set-Fire $true }
    foreach ($character in $characters) {
        $dozing = $character.Sleeping -or $character.SleepwalkTicks -gt 0
        if (-not $dozing -or $random.Next($ZOdds) -ne 0) { continue }
        Add-TextParticle 'z' $LabelColor ($random.Next(9, 15)) ($character.X + $character.Width - $character.PixelSize) ($character.Top - 10) 0.3 (-0.5) 45
    }
    if ($random.Next($FireflyOdds) -eq 0) {
        Add-DotParticle 3 $FireflyColor (Get-RandomBetween 0 $stage.Width) (Get-RandomBetween 55 120) (Get-RandomBetween (-0.4) 0.4) (Get-RandomBetween (-0.3) 0.3) ($random.Next(60, 140))
    }
    Update-Dream
}

function Set-FrameRate {
    $everyoneAsleep = $script:mood -eq 'asleep' -and @($characters | Where-Object { -not $_.Sleeping }).Count -eq 0
    $milliseconds = if ($everyoneAsleep) { $SleepAnimationMilliseconds } else { $AnimationMilliseconds }
    if ($animationTimer.Interval.TotalMilliseconds -ne $milliseconds) { $animationTimer.Interval = [TimeSpan]::FromMilliseconds($milliseconds) }
}

# ---------- toys for when they are bored: a ball to kick and a butterfly to chase ----------

function Step-Ball {
    if ($script:held -and [object]::ReferenceEquals($script:held.Thing, $ball)) {
        Set-Position $ball.View ($ball.X - $BallSize / 2) ($GroundY - $BallSize - $ball.Height)
        return
    }
    foreach ($character in $characters) {
        $touching = [math]::Abs((Get-Center $character) - $ball.X) -lt $character.Width / 2 + $BallSize
        $ballIsSlow = [math]::Abs($ball.VelocityX) -lt 1
        if ($character.Walking -and $touching -and $ballIsSlow) {
            $ball.VelocityX = $character.Direction * $random.Next(3, 7)
            $ball.VelocityY = $random.Next(2, 6)
        }
    }
    $ball.X += $ball.VelocityX
    $ball.VelocityX *= $BallFriction
    $rightWall = $stage.Width - $BallSize / 2
    if ($ball.X -lt $BallSize / 2 -or $ball.X -gt $rightWall) { $ball.VelocityX = -$ball.VelocityX }
    $ball.X = [math]::Max($BallSize / 2, [math]::Min($rightWall, $ball.X))
    $ball.Height = [math]::Max(0, $ball.Height + $ball.VelocityY)
    $ball.VelocityY = if ($ball.Height -gt 0) { $ball.VelocityY - $Gravity } else { 0 }
    Set-Position $ball.View ($ball.X - $BallSize / 2) ($GroundY - $BallSize - $ball.Height)
}

function Step-Butterfly {
    if ($random.Next(80) -eq 0) { $butterfly.VelocityX = -$butterfly.VelocityX }
    $butterfly.X += $butterfly.VelocityX
    if ($butterfly.X -lt 10 -or $butterfly.X -gt $stage.Width - 10) { $butterfly.VelocityX = -$butterfly.VelocityX }
    $top = $ButterflyBaseTop + $ButterflySwing * [math]::Sin($script:tick / 14)
    # wings open and close: 4 pixels wide, then 1
    $wingWidth = if ($script:tick % 6 -lt 3) { 4 } else { 1 }
    $butterfly.LeftWing.Width = $wingWidth
    $butterfly.RightWing.Width = $wingWidth
    [Windows.Controls.Canvas]::SetLeft($butterfly.LeftWing, 4 - $wingWidth)
    Set-Position $butterfly.View ($butterfly.X - 5) $top
}

function Update-Toys {
    $ball.View.Visibility = Get-Visibility $script:bored
    $butterfly.View.Visibility = Get-Visibility $script:bored
    if (-not $script:bored) { return }
    Step-Ball
    Step-Butterfly
}

# ---------- characters ----------

function New-Frame($pixelRows, $pixelSize, $color) {
    $frame = New-Object Windows.Controls.Canvas
    [Windows.Media.RenderOptions]::SetEdgeMode($frame, 'Aliased')   # crisp pixels, no seams between squares
    for ($y = 0; $y -lt $pixelRows.Count; $y++) {
        for ($x = 0; $x -lt $pixelRows[$y].Length; $x++) {
            $pixel = "$($pixelRows[$y][$x])"
            if ($pixel -eq '.') { continue }
            $fill = if ($Palette.ContainsKey($pixel)) { $Palette[$pixel] } else { $color }
            New-Shape Rectangle $pixelSize $pixelSize $fill ($x * $pixelSize) ($y * $pixelSize) $frame | Out-Null
        }
    }
    $frame
}

function New-Label($text, $fontSize) {
    $label = New-Object Windows.Controls.TextBlock
    $label.Text = $text
    $label.FontSize = $fontSize
    $label.Foreground = $LabelColor
    $label
}

function New-Character($member, $startX) {
    $size = $member.PixelSize
    $width = $BodyRows[0].Length * $size
    $height = ($BodyRows.Count + 1) * $size
    $frames = foreach ($pixelRows in $FrameRows) { New-Frame $pixelRows $size $member.Color }
    # the sitting frame swells and shrinks from the ground up while its owner sleeps
    $breath = New-Object Windows.Media.ScaleTransform 1, 1, 0, $height
    $frames[2].RenderTransform = $breath
    $eyes = New-Frame $EyeRows $size $member.Color
    $lids = New-Frame $LidRows $size $member.Color
    foreach ($lid in $lids.Children) { $lid.Height = $size / 2 }   # covers the top half of each eye: a droopy look
    $mouth = New-Frame $MouthRows $size $member.Color
    $sweat = New-Frame $SweatRows $size $SweatColor
    $hat = New-Frame $HatRows $size $member.Color
    [Windows.Controls.Canvas]::SetTop($hat, -$HatRows.Count * $size)
    $overhead = New-Label '.' 11    # "..." while thinking
    Set-Position $overhead ($width - $size) (-14)
    $nameTag = New-Label $member.Name 10
    $nameTag.Width = $width
    $nameTag.TextAlignment = 'Center'
    Set-Position $nameTag 0 ($height + 4)
    $view = New-Object Windows.Controls.Canvas
    foreach ($part in @($frames) + $eyes, $lids, $mouth, $sweat, $hat, $overhead, $nameTag) { $view.Children.Add($part) | Out-Null }
    $stage.Children.Add($view) | Out-Null
    [pscustomobject]@{
        Name = $member.Name; View = $view; Frames = $frames; Eyes = $eyes; Lids = $lids; Mouth = $mouth; Sweat = $sweat
        Hat = $hat; HomeSide = $member.HomeSide; Overhead = $overhead; Breath = $breath; PixelSize = $size; Width = $width; Top = $GroundY - $height
        X = $startX; Speed = $member.Speed; Direction = (1, -1)[$random.Next(2)]; Talking = $false; Walking = $false
        PauseTicks = 0; BlinkCountdown = $random.Next(20, 120); HopTick = 0
        SitTicks = 0; YawnTicks = 0; GroggyTicks = 0; Sleeping = $false; SleepwalkTicks = 0; BedCenter = 0
        Altitude = 0; FallSpeed = 0   # above the ground only when the human picked it up and let go
    }
}

# ---------- picking a character or the ball up with the mouse ----------

function Test-Held($thing) { $script:held -and $script:held.Dragged -and [object]::ReferenceEquals($script:held.Thing, $thing) }

function Start-Hold($thing, $point) {
    $script:held = @{ Thing = $thing; Start = $point; Last = $point; Previous = $point; Throw = [Windows.Vector]::new(0, 0); Dragged = $false }
}

# The first real movement turns the click into a drag: a character wakes up and complains.
function Move-Hold($point) {
    $hold = $script:held
    $hold.Last = $point
    $distance = [math]::Abs($point.X - $hold.Start.X) + [math]::Abs($point.Y - $hold.Start.Y)
    if ($hold.Dragged -or $distance -le $PokeMaxPixels) { return }
    $hold.Dragged = $true
    if ([object]::ReferenceEquals($hold.Thing, $ball)) { return }
    $script:lastChange = Get-Date
    Update-Mood
    $hold.Thing.SitTicks = 0
    Add-TextParticle (Get-RandomItem $HeldReplies) '#F5F4EE' 12 $hold.Thing.X ($hold.Thing.Top - 34) 0 (-0.5) 40
}

# Each tick the held thing follows the mouse; the movement of the last tick becomes the throw when it is let go.
function Step-Hold {
    $hold = $script:held
    if (-not $hold -or -not $hold.Dragged) { return }
    $hold.Throw = $hold.Last - $hold.Previous
    $hold.Previous = $hold.Last
    $thing = $hold.Thing
    if ([object]::ReferenceEquals($thing, $ball)) {
        $ball.X = [math]::Max($BallSize / 2, [math]::Min($stage.Width - $BallSize / 2, $hold.Last.X))
        $ball.Height = [math]::Max(0, $GroundY - $BallSize / 2 - $hold.Last.Y)
        return
    }
    $thing.X = [math]::Max(0, [math]::Min($stage.Width - $thing.Width, $hold.Last.X - $thing.Width / 2))
    $thing.Altitude = [math]::Max(0, ($thing.Top + $GroundY) / 2 - $hold.Last.Y)   # held by the middle of the body
    $thing.FallSpeed = 0
}

# Let go: a click that never moved is a poke, a dragged character drops, a dragged ball flies off.
function Stop-Hold {
    $hold = $script:held
    $script:held = $null
    if (-not $hold) { return }
    $isBall = [object]::ReferenceEquals($hold.Thing, $ball)
    if (-not $hold.Dragged) { if (-not $isBall) { Invoke-Poke $hold.Thing }; return }
    if (-not $isBall) { return }   # Step-Fall takes it from here
    $ball.VelocityX = [math]::Max(-$MaxThrowSpeed, [math]::Min($MaxThrowSpeed, $hold.Throw.X))
    $ball.VelocityY = [math]::Max(-$MaxThrowSpeed, [math]::Min($MaxThrowSpeed, -$hold.Throw.Y))
}

# Dropped from the air: falls, bounces once or twice, lands.
function Step-Fall($character) {
    $character.FallSpeed += $Gravity
    $character.Altitude -= $character.FallSpeed
    if ($character.Altitude -gt 0) { return }
    $character.Altitude = 0
    $character.FallSpeed = if ($character.FallSpeed -gt $BounceMinSpeed) { -$character.FallSpeed * $BounceFactor } else { 0 }
}

function Get-Center($character) { $character.X + $character.Width / 2 }

# What this character is doing right now, given what Claude Code is doing.
function Get-Role($character) {
    $isWorker = $character.Name -eq $script:worker.Name
    switch ($script:activity) {
        'planning' { return 'huddle' }
        'needsYou' { if ($isWorker) { return 'call' } }
        'working'  { if ($isWorker) { if ($script:task.Kind -eq 'run') { return 'pace' } else { return 'work' } } }
    }
    'roam'
}

# True when moving to $newX would walk into another character (they bump and turn around instead of overlapping).
function Test-Bump($character, $newX) {
    foreach ($other in $characters) {
        if ($other.Name -eq $character.Name) { continue }
        $currentDistance = [math]::Abs((Get-Center $character) - (Get-Center $other))
        $newDistance = [math]::Abs($newX + $character.Width / 2 - (Get-Center $other))
        $touching = $newDistance -lt ($character.Width + $other.Width) / 2 + $PersonalSpace
        if ($touching -and $newDistance -lt $currentDistance) { return $true }
    }
    $false
}

# Moves one step in the current direction; turns around instead when a wall or another character is in the way.
function Step-Character($character, $distance) {
    $newX = $character.X + $character.Direction * $distance
    $blocked = $newX -lt 0 -or $newX -gt ($stage.Width - $character.Width) -or (Test-Bump $character $newX)
    if ($blocked) { $character.Direction = -$character.Direction; return $false }
    $character.X = $newX
    $true
}

function Step-Toward($character, $targetCenter, $speed = $ApproachSpeed) {
    $offset = $targetCenter - (Get-Center $character)
    if ([math]::Abs($offset) -lt $speed) { return $false }
    $character.Direction = [math]::Sign($offset)
    Step-Character $character $speed
}

# Just woken up: stumbles left and right for a few seconds.
function Step-Groggy($character) {
    $character.GroggyTicks--
    if ($random.Next(8) -eq 0) { $character.Direction = -$character.Direction }
    Step-Character $character $GroggySpeed
}

# Nothing to do: sit down for a while, kick the ball around, or (the chaser) run and jump after the butterfly.
function Step-Bored($character) {
    if ($random.Next($SitOdds) -eq 0) { $character.SitTicks = $random.Next(60, 160); return $false }
    $speed = $character.Speed * $MoodSpeed[$script:mood]
    if ($character.Name -ne $ChaserName) {
        if ($random.Next(60) -eq 0) { $character.Direction = [math]::Sign($ball.X - (Get-Center $character)) }
        return Step-Character $character $speed
    }
    $offset = $butterfly.X - (Get-Center $character)
    $close = [math]::Abs($offset) -lt 20
    if ($close -and $character.HopTick -eq 0 -and $random.Next(25) -eq 0) { $character.HopTick = 1 }
    if ([math]::Abs($offset) -lt 4) { return $false }
    $character.Direction = [math]::Sign($offset)
    Step-Character $character ($speed * $ChaseSpeedFactor)
}

# Free roaming: stroll, sometimes stop to look around, sometimes turn.
function Step-Roam($character) {
    if ($character.GroggyTicks -gt 0) { return Step-Groggy $character }
    if ($character.SitTicks -gt 0) { $character.SitTicks--; return $false }
    if ($character.PauseTicks -gt 0) { $character.PauseTicks--; return $false }
    if ($script:bored) { return Step-Bored $character }
    $panicking = $script:mood -eq 'panic'
    if (-not $panicking -and $random.Next(250) -eq 0) { $character.PauseTicks = $random.Next(20, 70); return $false }
    $turnOdds = if ($panicking) { 25 } else { 120 }
    if ($random.Next($turnOdds) -eq 0) { $character.Direction = -$character.Direction }
    Step-Character $character ($character.Speed * $MoodSpeed[$script:mood])
}

# Waiting on a running command: nervous short walks back and forth.
function Step-Pace($character) {
    if ($random.Next(15) -eq 0) { $character.Direction = -$character.Direction }
    Step-Character $character ($character.Speed * $PaceSpeedFactor)
}

# Asleep but restless: turns over now and then; the sleepwalker sometimes gets up for a little walk.
function Step-Sleeper($character) {
    if ($random.Next($RollOverOdds) -eq 0) {
        $turned = $character.X + (1, -1)[$random.Next(2)] * $character.PixelSize
        if (-not (Test-Bump $character $turned)) { $character.X = [math]::Max(0, [math]::Min($stage.Width - $character.Width, $turned)) }
    }
    if ($character.Name -ne $SleepwalkerName -or $random.Next($SleepwalkOdds) -ne 0) { return }
    $character.Sleeping = $false
    $character.SleepwalkTicks = $SleepwalkTicks
    $script:bedtimeTicks = 0   # gives it time to find its bed again afterwards
}

# Bedtime: shuffle to the place by the fire and lie down. Returns whether the character walked this tick.
function Step-Bedtime($character) {
    if ($character.SleepwalkTicks -gt 0) {
        $character.SleepwalkTicks--
        return Step-Character $character $SleepwalkSpeed
    }
    if ($character.Sleeping) { Step-Sleeper $character; return $false }
    $walked = Step-Toward $character $character.BedCenter $BedtimeSpeed
    $arrived = [math]::Abs($character.BedCenter - (Get-Center $character)) -lt $BedtimeSpeed
    if ($arrived -or $script:bedtimeTicks -gt $BedtimeTimeoutTicks) { $character.Sleeping = $true }
    $walked
}

# Party: run around like crazy, bouncing off the walls and each other.
function Step-Party($character) {
    if ($random.Next($PartyTurnOdds) -eq 0) { $character.Direction = -$character.Direction }
    Step-Character $character ($character.Speed * $PartySpeedFactor)
}

# A guest runs in from its side when the party starts, goes wild with the others, and runs back home when it is over.
function Move-Guest($guest) {
    $partying = $script:partyTicksLeft -gt 0
    $offStage = $guest.X -le -$guest.Width -or $guest.X -ge $stage.Width
    if (-not $partying -and $offStage) { return $false }
    if (-not $partying) { $guest.Direction = $guest.HomeSide }
    elseif ($guest.X -le 0) { $guest.Direction = 1 }
    elseif ($guest.X -ge $stage.Width - $guest.Width) { $guest.Direction = -1 }
    elseif ($random.Next($PartyTurnOdds) -eq 0) { $guest.Direction = -$guest.Direction }
    $guest.X += $guest.Direction * $guest.Speed * $PartySpeedFactor
    $true
}

# Returns whether the character walked this tick.
function Move-Character($character) {
    if (Test-Held $character) { return $true }   # dangling from the mouse, legs kicking
    if ($character.Altitude -gt 0 -or $character.FallSpeed -ne 0) { Step-Fall $character; return $false }
    if ($character.Talking) { return $false }
    if ($script:partyTicksLeft -gt 0) { return Step-Party $character }
    if ($script:mood -eq 'exhausted') { return $false }
    if ($script:mood -eq 'asleep') { return Step-Bedtime $character }
    switch (Get-Role $character) {
        'huddle' { return Step-Toward $character ($stage.Width / 2) }
        'pace'   { return Step-Pace $character }
        'roam'   {
            # a command just failed: come and look over the worker's shoulder
            if ($script:gatherTicksLeft -gt 0) { return Step-Toward $character (Get-Center $script:worker) }
            return Step-Roam $character
        }
    }
    $false   # 'work' and 'call' stay where they are
}

# The helper walks in from the right while a subagent runs and walks back out afterwards. It passes behind the others.
function Move-Helper {
    $leaving = $script:subagents -le 0
    if ($leaving -and $helper.X -ge $stage.Width) { return $false }
    if ($leaving) { $helper.Direction = 1 }
    elseif ($helper.X -ge $stage.Width - $helper.Width) { $helper.Direction = -1 }
    elseif ($helper.X -le 0) { $helper.Direction = 1 }
    elseif ($random.Next(120) -eq 0) { $helper.Direction = -$helper.Direction }
    $helper.X += $helper.Direction * $helper.Speed
    $true
}

function Test-Blink($character) {
    $character.BlinkCountdown--
    if ($character.BlinkCountdown -le -$BlinkTicks) { $character.BlinkCountdown = $random.Next(40, 140); return $false }
    $character.BlinkCountdown -le 0
}

# Height above the ground this tick: a little parabola while hopping, 0 otherwise.
function Get-HopLift($character) {
    if ($character.Sleeping -or $script:mood -eq 'exhausted') { return 0 }
    if ($character.HopTick -eq 0) {
        $mustHop = $script:celebrateTicksLeft -gt 0 -or $script:partyTicksLeft -gt 0 -or (Get-Role $character) -eq 'call'
        $feelsLikeHopping = $script:mood -eq 'calm' -and -not $character.Talking -and $random.Next(350) -eq 0
        if (-not $mustHop -and -not $feelsLikeHopping) { return 0 }
    }
    $character.HopTick++
    if ($character.HopTick -gt $HopTicks) { $character.HopTick = 0; return 0 }
    $progress = $character.HopTick / $HopTicks
    $HopHeight * 4 * $progress * (1 - $progress)
}

# Where the eyes point: -1 left, 0 straight, 1 right.
function Get-Look($character) {
    $role = Get-Role $character
    $claudeIsBusy = $script:activity -eq 'working' -or $script:activity -eq 'needsYou'
    if ($claudeIsBusy -and $role -eq 'roam') { return [math]::Sign((Get-Center $script:worker) - (Get-Center $character)) }
    if ($role -eq 'work' -and $script:task.Kind -eq 'read') { return (1, -1)[[int][math]::Floor($script:tick / 12) % 2] }
    if ($character.Walking) { return $character.Direction }
    0
}

# Eyes (open, half closed or shut) and the yawning mouth. Eyes are dark squares on the body: hiding them closes them.
function Update-Face($character, $sitting) {
    $yawning = $character.YawnTicks -gt 0
    if ($yawning) { $character.YawnTicks-- }
    elseif ($script:mood -eq 'drowsy' -and $random.Next($YawnOdds) -eq 0) { $character.YawnTicks = $YawnTicks }
    $dozing = $character.Sleeping -or $character.SleepwalkTicks -gt 0 -or $script:mood -eq 'exhausted'
    $despairing = $script:gatherTicksLeft -gt 0 -and $character.Name -eq $script:worker.Name   # cannot look at the failed command
    $eyesShut = (Test-Blink $character) -or $dozing -or $yawning -or $despairing
    $droopy = -not $eyesShut -and ($script:mood -eq 'drowsy' -or $character.GroggyTicks -gt 0)
    $character.Eyes.Visibility = Get-Visibility (-not $eyesShut)
    $character.Lids.Visibility = Get-Visibility $droopy
    $character.Mouth.Visibility = Get-Visibility $yawning
    # the sitting frame is drawn one pixel lower, so the face moves down with it
    $faceTop = if ($sitting) { $character.PixelSize } else { 0 }
    $faceLeft = (Get-Look $character) * $character.PixelSize / 3
    Set-Position $character.Eyes $faceLeft $faceTop
    Set-Position $character.Lids $faceLeft $faceTop
    [Windows.Controls.Canvas]::SetTop($character.Mouth, $faceTop)
}

function Update-Pose($character, $legFrame) {
    $role = Get-Role $character
    $onTheGround = $character.Altitude -eq 0 -and -not (Test-Held $character)
    $sitting = $onTheGround -and ($character.Sleeping -or $character.SitTicks -gt 0 -or $script:mood -eq 'exhausted')
    $frameIndex = if ($sitting) { 2 } elseif ($character.Walking) { $legFrame } else { 0 }
    for ($i = 0; $i -lt $character.Frames.Count; $i++) { $character.Frames[$i].Visibility = Get-Visibility ($i -eq $frameIndex) }
    $character.Breath.ScaleY = if ($character.Sleeping) { 1 + $BreathDepth * [math]::Sin($script:tick / $BreathPeriodTicks + $character.X) } else { 1 }
    Update-Face $character $sitting
    $character.Overhead.Visibility = Get-Visibility ($role -eq 'huddle')
    $character.Overhead.Text = '.' * (1 + [int][math]::Floor($script:tick / 12) % 3)
    $sweating = -not $character.Sleeping -and ($script:mood -in 'tired', 'panic' -or $role -eq 'pace')
    $character.Sweat.Visibility = Get-Visibility $sweating
    $character.Hat.Visibility = Get-Visibility ($script:partyTicksLeft -gt 0 -or $script:partyDay)
    [Windows.Controls.Canvas]::SetTop($character.Sweat, $legFrame * $character.PixelSize)
    # the sitting frame is drawn one pixel lower: the hat comes down with the head
    [Windows.Controls.Canvas]::SetTop($character.Hat, ([int]$sitting - $HatRows.Count) * $character.PixelSize)
    # speaking and typing both show as a quick little bounce; a yawn comes with a stretch
    $speaking = $script:bubbleOwner -and $script:bubbleOwner.Name -eq $character.Name
    $typing = $role -eq 'work' -and $script:task.Kind -eq 'edit'
    $bounce = if ($speaking -or $typing) { 2 * $legFrame } elseif ($character.YawnTicks -gt 0) { 2 } else { 0 }
    Set-Position $character.View $character.X ($character.Top - $character.Altitude - (Get-HopLift $character) - $bounce)
}

# The human clicked a character: it jumps and complains. Poking a sleeper wakes the whole camp.
function Invoke-Poke($character) {
    if (-not $character) { return }
    $wasAsleep = $script:mood -eq 'asleep'
    $script:lastChange = Get-Date
    Update-Mood
    $character.SitTicks = 0
    $character.HopTick = 1
    $complaint = if ($wasAsleep) { 'Huh?!' } else { Get-RandomItem $PokeReplies }
    Add-TextParticle $complaint '#F5F4EE' 12 $character.X ($character.Top - 34) 0 (-0.5) 40
}

# ---------- bubbles and conversations ----------

function Get-ChatLine {
    if ($null -eq $script:sessionPercent) { return Get-RandomItem $SmallTalk }
    $urgent = @()
    if ($script:sessionPercent -ge $AlertPercent) { $urgent += $SessionAlertTalk }
    if ($script:weeklyPercent -ge $AlertPercent) { $urgent += $WeeklyAlertTalk }
    if ($script:mood -eq 'tired') { $urgent += $TiredTalk }
    if ($script:forecast.TooFast) { $urgent += $FastPaceTalk }
    if ($urgent.Count -and $random.Next(2) -eq 0) { return Get-RandomItem $urgent }
    $relaxed = if ($script:forecast -and -not $script:forecast.TooFast) { @($EasyPaceTalk) } else { @() }
    Get-RandomItem ($SmallTalk + $UsageTalk + $relaxed)
}

function Format-Chat($text) {
    $text.Replace('{s}', "$script:sessionPercent").Replace('{w}', "$script:weeklyPercent").Replace('{reset}', "$script:sessionReset")
}

# Centers a bubble above a character, kept inside the stage. $extraLift leaves room for a hopping character.
function Set-BubbleAbove($element, $character, $extraLift) {
    $element.Measure([Windows.Size]::new([double]::PositiveInfinity, [double]::PositiveInfinity))
    $centered = (Get-Center $character) - $element.DesiredSize.Width / 2
    $left = [math]::Max(0, [math]::Min($stage.Width - $element.DesiredSize.Width, $centered))
    Set-Position $element $left ($character.Top - $element.DesiredSize.Height - 8 - $extraLift)
    $element.Visibility = 'Visible'
}

function Show-Bubble($character, $text) {
    $bubbleText.Text = $text
    Set-BubbleAbove $bubble $character 0
    $script:bubbleOwner = $character
}

# The darker bubble above the working character: what Claude is doing, or a red call for the human.
function Update-TaskBubble {
    $urgent = $script:activity -eq 'needsYou'
    $text = if ($urgent) { $NeedsYouText } elseif ($script:activity -eq 'working' -and $script:task) { $script:task.Text } else { $null }
    # a chat bubble takes priority so the two never overlap
    if (-not $text -or $bubble.Visibility -eq 'Visible' -or $script:mood -eq 'asleep') { $taskBubble.Visibility = 'Hidden'; return }
    $taskText.Text = $text
    $taskBubble.Background = if ($urgent) { $AlertColor } else { $TaskColor }
    Set-BubbleAbove $taskBubble $script:worker $(if ($urgent) { $HopHeight } else { 0 })
}

function Set-TalkPhase($talk, $phase, $ticks) {
    $talk.Phase = $phase
    $talk.TicksLeft = $ticks
    if ($phase -eq 'say') { Show-Bubble $talk.Speaker $talk.Say }
    if ($phase -eq 'reply') { Show-Bubble $talk.Listener $talk.Reply }
}

# $shout = say it right away from where they stand (news); otherwise the two walk up to each other first.
# A line may name its Speaker and Listener; otherwise somebody free says it to whoever is nearest.
function Start-Conversation($line, $shout) {
    # whoever is busy with Claude's task does not chat
    $free = @($characters | Where-Object { (Get-Role $_) -notin 'work', 'pace', 'call' })
    if ($free.Count -lt 2) { return }
    $speaker = $free | Where-Object { $_.Name -eq $line.Speaker } | Select-Object -First 1
    if (-not $speaker) { $speaker = Get-RandomItem $free }
    $others = @($free | Where-Object { $_.Name -ne $speaker.Name })
    $listener = $others | Where-Object { $_.Name -eq $line.Listener } | Select-Object -First 1
    if (-not $listener) { $listener = $others | Sort-Object { [math]::Abs((Get-Center $_) - (Get-Center $speaker)) } | Select-Object -First 1 }
    $speaker.Talking = $true
    $listener.Talking = $true
    $script:conversation = @{ Speaker = $speaker; Listener = $listener; Say = (Format-Chat $line.Say); Reply = (Format-Chat $line.Reply) }
    if ($shout) { Set-TalkPhase $script:conversation 'say' $BubbleTicks } else { Set-TalkPhase $script:conversation 'approach' $ApproachTimeoutTicks }
}

function Stop-Conversation {
    $bubble.Visibility = 'Hidden'
    $script:bubbleOwner = $null
    $script:conversation.Speaker.Talking = $false
    $script:conversation.Listener.Talking = $false
    $script:conversation = $null
    $script:idleTicks = $random.Next(80, 200)   # 4-10 s of quiet before the next chat
}

# Speaker and listener walk towards each other. Returns $true once they stand face to face.
function Step-Approach($talk) {
    $gap = [math]::Abs((Get-Center $talk.Speaker) - (Get-Center $talk.Listener)) - ($talk.Speaker.Width + $talk.Listener.Width) / 2
    if ($gap -le $PersonalSpace + 2 * $ApproachSpeed) { return $true }
    $talk.Speaker.Walking = Step-Toward $talk.Speaker (Get-Center $talk.Listener)
    $talk.Listener.Walking = Step-Toward $talk.Listener (Get-Center $talk.Speaker)
    $false
}

function Step-Conversation {
    if ($script:announcement) {
        if ($script:conversation) { Stop-Conversation }
        Start-Conversation $script:announcement $true
        $script:announcement = $null
        return
    }
    $talk = $script:conversation
    if (-not $talk) {
        # small talk waits until Claude is done, and stops for the night (only "good night" is said at bedtime)
        if ($script:activity -ne 'idle' -or $script:mood -in 'asleep', 'exhausted') { return }
        $script:idleTicks--
        if ($script:idleTicks -le 0) { Start-Conversation (Get-ChatLine) $false }
        return
    }
    $talk.TicksLeft--
    $timeUp = $talk.TicksLeft -le 0
    switch ($talk.Phase) {
        'approach' { if ((Step-Approach $talk) -or $timeUp) { Set-TalkPhase $talk 'say' $BubbleTicks } }
        'say'      { if ($timeUp) { Set-TalkPhase $talk 'reply' $BubbleTicks } }
        'reply'    { if ($timeUp) { Stop-Conversation } }
    }
}

# ---------- wiring ----------

$script:previousPercent = @{}
$script:lastChange = Get-Date
$script:lastHookEvent = Get-Date
$script:mood = 'calm'
$script:bored = $false
$script:activity = 'idle'      # idle | planning | working | needsYou
$script:task = $null
$script:subagents = 0
$script:announcement = $null
$script:conversation = $null
$script:bubbleOwner = $null
$script:celebrateTicksLeft = 0
$script:idleTicks = 40
$script:demoStep = 0
$script:refreshDelay = $RefreshSeconds
$script:tick = 0
$script:isNight = Test-Night
$script:nightLevel = [int]$script:isNight   # 0 = full day, 1 = full night
$script:particles = New-Object Collections.ArrayList
$script:fireLit = $false
$script:bedtimeTicks = 0
$script:dreamTicksLeft = 0
$script:partyTicksLeft = 0
$script:gatherTicksLeft = 0
$script:failedTool = $null
$script:forecast = $null
$script:renewProcess = $null
$script:renewStarted = $null
$script:autoRenewTried = $false
$script:loginOpened = $false
$script:held = $null           # what the mouse is carrying: a character or the ball
$script:todayChanged = $false
Restore-Today
# only events from now on: whatever happened before the widget opened is old news
$script:eventsOffset = if (Test-Path $EventsPath) { (Get-Item $EventsPath).Length } else { 0 }

$daySky = New-Object Windows.Controls.Canvas
$nightSky = New-Object Windows.Controls.Canvas
$sky.Children.Add($daySky) | Out-Null
$sky.Children.Add($nightSky) | Out-Null
$sun = New-Shape Ellipse 26 26 '#F2C14E' 436 $SunTop $daySky
$clouds = @((New-Cloud 40 14 54 $CloudColor $daySky), (New-Cloud 210 34 40 $CloudColor $daySky), (New-Cloud 330 8 62 $CloudColor $daySky))
$moon = New-Object Windows.Controls.Canvas
Set-Position $moon 431 $MoonTop
$nightSky.Children.Add($moon) | Out-Null
New-Shape Ellipse 22 22 '#E8E6DC' 7 4 $moon | Out-Null
New-Shape Ellipse 22 22 $SkyColor 0 0 $moon | Out-Null           # dark disc over the moon makes it a crescent
$stars = @(1..18 | ForEach-Object { New-Shape Rectangle 2 2 '#F5F4EE' ($random.Next(0, 420)) ($random.Next(2, 62)) $nightSky })
$sunset = [Windows.Markup.XamlReader]::Parse(@'
<Rectangle xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" Width="480" Height="90" Opacity="0">
  <Rectangle.Fill>
    <LinearGradientBrush StartPoint="0,0" EndPoint="0,1">
      <GradientStop Color="#00E8873A" Offset="0"/>
      <GradientStop Color="#99E8873A" Offset="0.75"/>
      <GradientStop Color="#99D9534B" Offset="1"/>
    </LinearGradientBrush>
  </Rectangle.Fill>
</Rectangle>
'@)
Set-Position $sunset 0 40
$sky.Children.Add($sunset) | Out-Null
# storm clouds sit over the sun, the moon and the stars; twice as tall as the fair-weather ones
$stormClouds = New-Object Windows.Controls.Canvas
$stormClouds.Opacity = 0
$stormClouds.RenderTransform = New-Object Windows.Media.ScaleTransform 1, 2
$sky.Children.Add($stormClouds) | Out-Null
foreach ($cloudLeft in 0, 95, 190, 285, 380) { New-Cloud ($cloudLeft - 10) ($random.Next(0, 6)) 120 $StormCloudColor $stormClouds | Out-Null }

# the sign stands behind everybody
$sign = [Windows.Markup.XamlReader]::Parse(@'
<Canvas xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml">
  <Rectangle Width="4" Height="56" Canvas.Left="48" Fill="#5C3D22"/>
  <Border Width="100" Height="32" Background="#7A5230" BorderBrush="#5C3D22" BorderThickness="2" CornerRadius="2">
    <StackPanel VerticalAlignment="Center">
      <TextBlock x:Name="SignTitle" FontSize="10" FontWeight="SemiBold" Foreground="#F5F4EE" TextAlignment="Center"/>
      <TextBlock x:Name="SignDetail" FontSize="10" Foreground="#F5F4EE" TextAlignment="Center"/>
    </StackPanel>
  </Border>
</Canvas>
'@)
$signTitle = $sign.FindName('SignTitle')
$signDetail = $sign.FindName('SignDetail')
Set-Position $sign 372 ($GroundY - 56)
$stage.Children.Add($sign) | Out-Null

# the campfire and its glow go on the stage before the characters, so they are drawn behind them
$glow = [Windows.Markup.XamlReader]::Parse(@'
<Ellipse xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" Width="150" Height="80" Visibility="Hidden">
  <Ellipse.Fill>
    <RadialGradientBrush>
      <GradientStop Color="#70E8873A" Offset="0"/>
      <GradientStop Color="#00E8873A" Offset="1"/>
    </RadialGradientBrush>
  </Ellipse.Fill>
</Ellipse>
'@)
Set-Position $glow ($FireCenter - 75) ($GroundY - 52)
$stage.Children.Add($glow) | Out-Null
$fire = New-Object Windows.Controls.Canvas
$fire.Visibility = 'Hidden'
$fireFrames = @(foreach ($pixelRows in $FireRows) { New-Frame $pixelRows $FirePixelSize $null })
foreach ($frame in $fireFrames) { $fire.Children.Add($frame) | Out-Null }
Set-Position $fire ($FireCenter - $FireRows[0][0].Length * $FirePixelSize / 2) ($GroundY - $FireRows[0].Count * $FirePixelSize)
$stage.Children.Add($fire) | Out-Null

$ball = @{ View = (New-Shape Ellipse $BallSize $BallSize $BallColor 0 0 $stage); X = $random.Next(40, 440); Height = 0; VelocityX = 0; VelocityY = 0 }
$butterflyView = New-Object Windows.Controls.Canvas
$butterfly = @{
    View = $butterflyView; X = $random.Next(40, 440); VelocityX = 1.3
    LeftWing = (New-Shape Rectangle 4 5 $ButterflyColor 0 0 $butterflyView)
    RightWing = (New-Shape Rectangle 4 5 $ButterflyColor 5 0 $butterflyView)
}
$stage.Children.Add($butterflyView) | Out-Null

$propStand = New-Object Windows.Controls.Canvas
$props = @{}
foreach ($propKind in $PropRows.Keys) {
    $props[$propKind] = New-Frame $PropRows[$propKind] $PropPixelSize $null
    $props[$propKind].Visibility = 'Hidden'
    [Windows.Controls.Canvas]::SetTop($props[$propKind], ($PropMaxRows - $PropRows[$propKind].Count) * $PropPixelSize)
    $propStand.Children.Add($props[$propKind]) | Out-Null
}
[Windows.Controls.Canvas]::SetTop($propStand, $GroundY - $PropMaxRows * $PropPixelSize)
$stage.Children.Add($propStand) | Out-Null

# the helper first so it is drawn behind the others; it waits off-stage on the right
$helper = New-Character $HelperMember $stage.Width
$guests = @(foreach ($guest in $GuestCast) { New-Character $guest $stage.Width })
# each guest waits just off-stage on its own side
foreach ($guest in $guests) { if ($guest.HomeSide -lt 0) { $guest.X = -$guest.Width } }
# spread out at start so nobody spawns on top of anybody
$characters = @(for ($i = 0; $i -lt $Cast.Count; $i++) { New-Character $Cast[$i] ($i * $stage.Width / $Cast.Count + 20) })
$script:worker = $characters | Where-Object { $_.Name -eq $DefaultWorkerName } | Select-Object -First 1
$lighter = $characters | Where-Object { $_.Name -eq $FireLighterName } | Select-Object -First 1

$dreamBubble = [Windows.Markup.XamlReader]::Parse(@'
<StackPanel xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" Panel.ZIndex="8" Visibility="Hidden" IsHitTestVisible="False">
  <Border Background="#F5F4EE" CornerRadius="10" Padding="6"><Canvas Width="21" Height="21"/></Border>
  <Ellipse Width="6" Height="6" Fill="#F5F4EE" Margin="0,2,0,0"/>
  <Ellipse Width="4" Height="4" Fill="#F5F4EE" Margin="0,2,0,0"/>
</StackPanel>
'@)
$dreamPictures = @(foreach ($pixelRows in $DreamPictureRows) { New-Frame $pixelRows $DreamPixelSize $null })
foreach ($picture in $dreamPictures) { $dreamBubble.Children[0].Child.Children.Add($picture) | Out-Null }
$stage.Children.Add($dreamBubble) | Out-Null

$window.FindName('Close').Add_MouseLeftButtonDown({ $_.Handled = $true; $window.Close() })
$window.FindName('Minimize').Add_MouseLeftButtonDown({ $_.Handled = $true; $window.WindowState = 'Minimized' })
$renewButton.Add_MouseLeftButtonDown({ $_.Handled = $true; Start-Renew })
$renewTimer = New-Object Windows.Threading.DispatcherTimer
$renewTimer.Interval = [TimeSpan]::FromSeconds(1)
$renewTimer.Add_Tick({ Step-Renew })
$window.Add_MouseLeftButtonDown({ $window.DragMove() })
$holdables = @($characters) + $ball
foreach ($holdable in $holdables) {
    $holdable.View.Cursor = [Windows.Input.Cursors]::Hand
    $holdable.View.Add_MouseLeftButtonDown({
        $_.Handled = $true   # a poke or a pick-up, not the start of a window drag
        $grabbedView = $this
        $point = $_.GetPosition($stage)
        Start-Hold ($holdables | Where-Object { [object]::ReferenceEquals($_.View, $grabbedView) }) $point
        $this.CaptureMouse() | Out-Null
    })
    $holdable.View.Add_MouseMove({ if ($script:held) { Move-Hold ($_.GetPosition($stage)) } })
    $holdable.View.Add_MouseLeftButtonUp({ $this.ReleaseMouseCapture() })
    # also fires when the capture is taken away (Alt+Tab), so nobody stays hanging in the air
    $holdable.View.Add_LostMouseCapture({ Stop-Hold })
}

Restore-Placement
$script:placementChanged = $false
$window.Add_SizeChanged({ $script:placementChanged = $true })
$window.Add_LocationChanged({ $script:placementChanged = $true })
$window.Add_Closing({ Save-Placement; Save-Today })

$usageTimer = New-Object Windows.Threading.DispatcherTimer
$usageTimer.Interval = [TimeSpan]::FromSeconds($RefreshSeconds)
# also saved on each refresh, not only on close, so a shutdown or a killed process does not lose the last resize
$usageTimer.Add_Tick({ Update-Usage; Save-Placement; Save-Today })
$usageTimer.Start()

$animationTimer = New-Object Windows.Threading.DispatcherTimer
$animationTimer.Interval = [TimeSpan]::FromMilliseconds($AnimationMilliseconds)
$animationTimer.Add_Tick({
    # an error in one frame must not close an always-on widget: show it in the status line and keep going
    try {
        if ($window.WindowState -eq 'Minimized') { return }   # nobody is watching: do not spend CPU animating
        $script:tick++
        if ($script:tick % $EventPollTicks -eq 0) { Read-HookEvents }
        if ($script:tick % 20 -eq 0) { Reset-StaleActivity; Update-Mood; Update-Sign }
        if ($script:celebrateTicksLeft -gt 0) { $script:celebrateTicksLeft-- }
        if ($script:gatherTicksLeft -gt 0) { $script:gatherTicksLeft-- }
        Step-Hold
        $legPeriod = if ($script:mood -eq 'panic' -or $script:partyTicksLeft -gt 0) { 2 } else { 4 }
        $legFrame = [int][math]::Floor($script:tick / $legPeriod) % 2
        foreach ($character in $characters) { $character.Walking = Move-Character $character }
        $helper.Walking = Move-Helper
        foreach ($guest in $guests) { $guest.Walking = Move-Guest $guest }
        Step-Conversation
        Update-Night
        Update-Toys
        Update-Party
        foreach ($character in $characters + $guests + $helper) { Update-Pose $character $legFrame }
        Update-TaskBubble
        Update-Prop
        Update-Weather
        Update-Fire
        Update-Particles
        Update-Sky
        Set-FrameRate
    } catch {
        $status.Text = "Animation error: $($_.Exception.Message) (line $($_.InvocationInfo.ScriptLineNumber))"
    }
})
$animationTimer.Start()

Show-SavedUsage
Update-Usage
Update-Sign
$window.ShowDialog() | Out-Null

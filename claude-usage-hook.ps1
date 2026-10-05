# Claude Code hook for the usage widget: appends one short line per event to claude-usage.events.jsonl.
# It records only the event name, tool name, file name or program name, permission mode and transcript path.
# Never the prompt text, file contents or command arguments.
$EventsPath = Join-Path $PSScriptRoot 'claude-usage.events.jsonl'
$MaxEventsBytes = 1MB
$MaxDetailLength = 28

function Get-Detail($toolInput) {
    if ($toolInput.file_path) { return Split-Path $toolInput.file_path -Leaf }
    if (-not $toolInput.command) { return '' }
    # only the program name and a plain sub-command ("dotnet build"): anything else on the line can hold secrets
    $words = $toolInput.command.Trim() -split '\s+'
    if ($words[0] -notmatch '^[\w.:/\\-]+$') { return '' }
    $program = Split-Path $words[0] -Leaf
    if ($words.Count -gt 1 -and $words[1] -match '^[a-z][a-z-]*$') { return "$program $($words[1])" }
    $program
}

try {
    $reader = New-Object IO.StreamReader([Console]::OpenStandardInput(), [Text.Encoding]::UTF8)
    $hook = $reader.ReadToEnd() | ConvertFrom-Json
    $detail = "$(Get-Detail $hook.tool_input)"
    if ($detail.Length -gt $MaxDetailLength) { $detail = $detail.Substring(0, $MaxDetailLength) }
    $line = [ordered]@{
        event      = $hook.hook_event_name
        tool       = $hook.tool_name
        detail     = $detail
        mode       = $hook.permission_mode
        kind       = $hook.notification_type
        transcript = $hook.transcript_path
    } | ConvertTo-Json -Compress
    # the widget may not be running to consume the file: start over instead of growing forever
    if ((Test-Path $EventsPath) -and (Get-Item $EventsPath).Length -gt $MaxEventsBytes) { Remove-Item $EventsPath -Confirm:$false }
    [IO.File]::AppendAllText($EventsPath, $line + "`n")
} catch {
    # a widget hook must never disturb a Claude session: stay silent, lose the event
}
exit 0

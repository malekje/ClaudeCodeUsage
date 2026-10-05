# Claude Code Usage

A small always-on-top Windows widget that shows your live Claude plan usage (session and weekly limits)
with animated pixel characters (Opus, Sonnet, Haiku) that react to your usage and to what Claude Code is doing.

## Install (Windows)

1. Have [Claude Desktop](https://claude.ai/download) or [Claude Code](https://claude.com/claude-code) installed.
2. Download `ClaudeUsage.zip` from the **Releases** page and unzip it anywhere.
3. Double-click `ClaudeUsage.exe`. Keep `claude-usage.ps1` in the same folder.
4. First run only: if this PC has no Claude Code login yet (common with Claude Desktop only, which keeps its login to itself),
   a black Claude window opens. Sign in there (it opens your browser), then close it. Your stats appear in the widget within a minute.

Windows SmartScreen or your antivirus may warn about the `.exe` because it is not code-signed.
It only starts `claude-usage.ps1` in a hidden PowerShell; its source is in `launcher/ClaudeUsage.cs`.
You can also skip the `.exe` and run: `powershell -ExecutionPolicy Bypass -WindowStyle Hidden -File claude-usage.ps1`.

Try it without your account: add `-Demo` (fake numbers, shows the animations).

Updates: when a newer release is on GitHub, an **Update** button shows up a few seconds after you open the widget.
One click replaces `claude-usage.ps1` and `claude-usage-hook.ps1` with the new ones and restarts the widget (the `.exe` never changes).

## What it reads and sends

- Reads your own login from `~/.claude/.credentials.json` and asks `https://api.anthropic.com/api/oauth/usage` for your numbers, once a minute. Nothing else is sent anywhere.
- It finds Claude Code on PATH, or the copy bundled with Claude Desktop.
- If the login has expired, it renews it by itself with `claude -p hi --model haiku` in the background (one tiny Haiku request).
  If that fails, a **Renew login** button lets you try again.

## Optional: characters react to Claude Code

Copy `claude-usage-hook.ps1` next to the widget and add this command as a hook in `~/.claude/settings.json`
for the events `UserPromptSubmit`, `PreToolUse`, `PostToolUse`, `PostToolUseFailure`, `PermissionRequest`,
`Notification`, `Stop`, `SubagentStart`, `SubagentStop` (use the real path to the script):

    powershell -NoProfile -ExecutionPolicy Bypass -File "C:/path/to/claude-usage-hook.ps1"

The hook only records tool names and file names (never prompt text) in a local file next to the widget.

## Build the launcher yourself

    C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe /target:winexe /win32icon:claude-usage.ico /reference:System.Windows.Forms.dll /out:ClaudeUsage.exe launcher\ClaudeUsage.cs

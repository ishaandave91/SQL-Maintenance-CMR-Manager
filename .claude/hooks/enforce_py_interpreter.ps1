# .claude/hooks/detect_py_usage.ps1
# Observe-only PreToolUse hook: notifies (does NOT block) when a Bash
# command invokes the `py` interpreter.

# 1. Read the hook payload (JSON) from stdin
$raw = [Console]::In.ReadToEnd()
  # View JSON payload from the hook
# $raw | Out-File (Join-Path $PSScriptRoot 'logs\raw_payload.log') -Append -Encoding utf8
if ([string]::IsNullOrWhiteSpace($raw)) { exit 0 }

# 2. Parse it
try { $payload = $raw | ConvertFrom-Json } catch { exit 0 }

# 3. Pull out the Bash command text
$command = $payload.tool_input.command
if ([string]::IsNullOrWhiteSpace($command)) { exit 0 }

# 4. Detect a `python` / `python3` / `python.exe` / `python3.exe` invocation as a real token:
#    matches `python/python3` at the start, or right after ; && | & followed by a space or end-of-string.
#(^|[;&|]\s*) — anchors to the start of the command or right after a separator (;, &, |), so it catches the real invocation, not substrings.
# python3? — matches python and python3.
# (\.exe)? — tolerates python.exe.
# (?=\s|$) — must be followed by a space or end-of-string, so py can never match (after py it'd need thon).
$pattern = '(^|[;&|]\s*)python3?(\.exe)?(?=\s|$)'
if ($command -notmatch $pattern) { exit 0 }

# 5. Log it (append, with timestamp)
$logDir = Join-Path $env:CLAUDE_PROJECT_DIR '.claude\hooks\logs'
if (-not (Test-Path $logDir)) {
    New-Item -ItemType Directory -Path $logDir -Force | Out-Null
}
$logFile = Join-Path $logDir 'py_usage.log'
$stamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
"$stamp | python/python3 detected | $command" | Out-File -FilePath $logFile -Append -Encoding utf8  #Encoding utf8 on the log write avoids PowerShell's default UTF-16, so the log stays readable by other tools.

# 6. Surface a visible, blocking notification to the user
$out = @{
  systemMessage    = "python/python3 is not allowed. Use 'py' instead (project guideline)."
  terminalSequence = "`a"
  hookSpecificOutput = @{
    hookEventName          = "PreToolUse"
    permissionDecision     = "deny"
    permissionDecisionReason = "Use 'py' instead of 'python'/'python3' (project guideline)."
  }
} | ConvertTo-Json -Compress -Depth 5
[Console]::Out.Write($out)
exit 0
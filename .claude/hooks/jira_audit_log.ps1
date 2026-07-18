# 1. Read the hook payload (JSON) from stdin
$raw = [Console]::In.ReadToEnd()
  # View JSON payload from the hook
# $raw | Out-File (Join-Path $PSScriptRoot 'logs\raw_payload.log') -Append -Encoding utf8
if ([string]::IsNullOrWhiteSpace($raw)) { exit 0 }

# 2. Parse it
try { $payload = $raw | ConvertFrom-Json } catch { exit 0 }

# 3. Pull out the relevant details for logging
$toolName = $payload.tool_name
if ([string]::IsNullOrWhiteSpace($toolName)) { exit 0 }
$hookEventType = $payload.hook_event_name

# 4. Verify tool name through pattern 
$pattern = '^mcp__atlassian__[A-Za-z0-9]+$'
if ($payload.tool_name -notmatch $pattern) { exit 0 }

# 5. Log it (append, with timestamp)
$logDir = Join-Path $env:CLAUDE_PROJECT_DIR '.claude\hooks\logs'
if (-not (Test-Path $logDir)) {
    New-Item -ItemType Directory -Path $logDir -Force | Out-Null
}
$logFile = Join-Path $logDir 'jira_mcp_audit.log'
$stamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
"$stamp | $hookEventType | jira mcp call detected | $toolName" | Out-File -FilePath $logFile -Append -Encoding utf8  #Encoding utf8 on the log write avoids PowerShell's default UTF-16, so the log stays readable by other tools.

# 6. Surface a visible, NON-blocking notification to the user
# $msg = "jira mcp tool: ' usage -> $command"
# $out = @{
#   hookSpecificOutput = @{
#     hookEventName = "PostToolUse"
#     permissionDecision = "allow"
#   }
# } | ConvertTo-Json -Compress -Depth 5
# [Console]::Out.Write($out)
exit 0
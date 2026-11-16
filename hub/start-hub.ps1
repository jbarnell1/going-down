# Starts the hub if it is not already listening. Safe to run again at any time.
# Used at logon by the "Going Down hub" scheduled task and by the work loop.
$root = Split-Path -Parent $PSScriptRoot
$port = if ($env:HUB_PORT) { [int]$env:HUB_PORT } else { 8066 }
$logDir = Join-Path $root '.local'
New-Item -ItemType Directory -Force $logDir | Out-Null
if (Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue) {
    "hub: already up on $port"
    exit 0
}
$node = (Get-Command node -ErrorAction Stop).Source
Start-Process -WindowStyle Hidden -FilePath $node -WorkingDirectory $root `
    -ArgumentList 'hub/server.mjs' `
    -RedirectStandardOutput (Join-Path $logDir 'hub.out.log') `
    -RedirectStandardError (Join-Path $logDir 'hub.err.log')
"hub: launched on $port"

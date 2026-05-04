# =========================================================
# Real-time Chrome Download Archiver - Improved Version
# =========================================================
# Fixes applied:
#   1. Dedupe guard prevents duplicate copies from Created+Changed
#   2. Retry timeout prevents infinite lock loop
#   3. CSV is initialized with a header row
#   4. Function is captured via $using: so event scope can access it
#   5. Try/catch around Copy-Item for disk/permission errors
#   6. Millisecond-precision timestamps prevent collision on rapid downloads
# =========================================================

param(
    [string]$Source      = "C:\Users\$env:USERNAME\Downloads",
    [string]$Destination = "C:\ArchiveDownloads",
    [int]   $LockTimeoutSeconds = 15,   # max wait for a file to unlock
    [int]   $DedupeCooldownMs  = 3000   # ms window to suppress duplicate events
)

# ── Setup ────────────────────────────────────────────────
$logFile = Join-Path $Destination "DownloadLog.csv"

if (-not (Test-Path $Destination)) {
    New-Item -Path $Destination -ItemType Directory | Out-Null
    Write-Host "[INFO] Created archive folder: $Destination"
}

# Initialize CSV with header if it doesn't exist yet
if (-not (Test-Path $logFile)) {
    "Timestamp,Username,OriginalName,DestinationPath,SizeBytes,Status" |
        Out-File -FilePath $logFile -Encoding UTF8
    Write-Host "[INFO] Created log file: $logFile"
}

# ── Dedupe tracker (thread-safe hashtable) ───────────────
# Stores the last-processed time for each file path so that
# rapid Created+Changed bursts only result in one copy.
$global:RecentlyCopied = [System.Collections.Concurrent.ConcurrentDictionary[string,datetime]]::new()

# ── Core copy function ───────────────────────────────────
function Copy-DownloadFile {
    param(
        [string]$FilePath,
        [string]$DestDir,
        [string]$LogPath,
        [int]   $TimeoutSec,
        [int]   $CooldownMs
    )

    # 1. Skip Chrome's in-progress temp files
    if ($FilePath -like "*.crdownload" -or $FilePath -like "*.tmp") { return }
    if (-not (Test-Path $FilePath))                                  { return }

    # 2. Dedupe: ignore if we copied this file very recently
    $now = Get-Date
    $lastCopy = $null
    if ($global:RecentlyCopied.TryGetValue($FilePath, [ref]$lastCopy)) {
        $elapsed = ($now - $lastCopy).TotalMilliseconds
        if ($elapsed -lt $CooldownMs) {
            Write-Host "[SKIP] Duplicate event suppressed for: $(Split-Path $FilePath -Leaf)"
            return
        }
    }

    # 3. Wait until the file is fully released, with a timeout
    $ready        = $false
    $retries      = 0
    $maxRetries   = [Math]::Ceiling($TimeoutSec * 1000 / 500)   # 500 ms per attempt

    while (-not $ready -and $retries -lt $maxRetries) {
        try {
            $stream = [System.IO.File]::Open($FilePath, 'Open', 'Read', 'None')
            $stream.Close()
            $ready = $true
        } catch {
            Start-Sleep -Milliseconds 500
            $retries++
        }
    }

    if (-not $ready) {
        Write-Warning "[WARN] Timed out waiting for file to unlock: $FilePath"
        # Log the failure
        $ts       = Get-Date -Format "yyyyMMdd_HHmmss_fff"
        $username = $env:USERNAME
        $name     = [System.IO.Path]::GetFileName($FilePath)
        "$ts,$username,$name,N/A,N/A,LOCK_TIMEOUT" |
            Out-File -Append -FilePath $LogPath -Encoding UTF8
        return
    }

    # 4. Build destination filename: timestamp_username_originalname
    $timestamp = Get-Date -Format "yyyyMMdd_HHmmss_fff"   # fff = milliseconds
    $username  = $env:USERNAME
    $name      = [System.IO.Path]::GetFileName($FilePath)
    $destFile  = Join-Path $DestDir ("${timestamp}_${username}_${name}")

    # 5. Copy with error handling
    $status   = "OK"
    $sizBytes = 0
    try {
        Copy-Item -Path $FilePath -Destination $destFile -Force
        $sizBytes = (Get-Item $destFile).Length
        Write-Host "[COPY] $name  →  $destFile  ($sizBytes bytes)"
    } catch {
        $status = "ERROR: $($_.Exception.Message)"
        Write-Warning "[ERROR] Failed to copy ${name}: $status"
    }

    # 6. Append to CSV log
    "$timestamp,$username,$name,$destFile,$sizBytes,$status" |
        Out-File -Append -FilePath $LogPath -Encoding UTF8

    # 7. Record in dedupe tracker
    $global:RecentlyCopied[$FilePath] = Get-Date

    # 8. Prune old entries from dedupe tracker (keep memory tidy)
    $cutoff = (Get-Date).AddMinutes(-5)
    foreach ($key in @($global:RecentlyCopied.Keys)) {
        if ($global:RecentlyCopied[$key] -lt $cutoff) {
            $removed = $null
            $global:RecentlyCopied.TryRemove($key, [ref]$removed) | Out-Null
        }
    }
}

# ── Capture variables for use inside event scope ─────────
$capturedDest       = $Destination
$capturedLog        = $logFile
$capturedTimeout    = $LockTimeoutSeconds
$capturedCooldown   = $DedupeCooldownMs
$capturedFuncDef    = ${function:Copy-DownloadFile}   # serialize the function

# ── FileSystemWatcher ────────────────────────────────────
$watcher                      = New-Object System.IO.FileSystemWatcher
$watcher.Path                 = $Source
$watcher.Filter               = "*.*"
$watcher.IncludeSubdirectories = $false
$watcher.EnableRaisingEvents  = $true

# Action block — runs in its own scope, so we re-define the function using $using:
$action = {
    # Re-hydrate captured variables and function into this scope
    $dest      = $using:capturedDest
    $log       = $using:capturedLog
    $timeout   = $using:capturedTimeout
    $cooldown  = $using:capturedCooldown
    $funcDef   = $using:capturedFuncDef

    # Define the function in this scope
    New-Item -Path "Function:\Copy-DownloadFile" -Value $funcDef | Out-Null

    Copy-DownloadFile `
        -FilePath  $Event.SourceEventArgs.FullPath `
        -DestDir   $dest `
        -LogPath   $log `
        -TimeoutSec $timeout `
        -CooldownMs $cooldown
}

# Register only Created — Changed is intentionally omitted to prevent duplicates.
# The lock-wait loop already handles files that arrive in parts.
$createdJob = Register-ObjectEvent -InputObject $watcher -EventName "Created" -Action $action

Write-Host ""
Write-Host "=============================================="
Write-Host "  Download Archiver is running"
Write-Host "  Watching : $Source"
Write-Host "  Archiving: $Destination"
Write-Host "  Log file : $logFile"
Write-Host "  Press Ctrl+C to stop."
Write-Host "=============================================="
Write-Host ""

# ── Keep-alive loop ───────────────────────────────────────
try {
    while ($true) { Start-Sleep -Seconds 5 }
} finally {
    # Clean up on Ctrl+C or script termination
    Unregister-Event -SourceIdentifier $createdJob.Name -ErrorAction SilentlyContinue
    $watcher.EnableRaisingEvents = $false
    $watcher.Dispose()
    Write-Host "`n[INFO] Watcher stopped and resources released."
}
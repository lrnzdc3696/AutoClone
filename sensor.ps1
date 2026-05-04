# =========================================================
# Download Archiver - Built on Simple Polling
# =========================================================
# HOW TO RUN:
#   1. Open PowerShell
#   2. Run: .\DownloadArchiver.ps1
#
# OPTIONAL: change the folders at the top to whatever you want
# =========================================================

$watchFolder   = "$env:USERPROFILE\Downloads"
$archiveFolder = "C:\ArchiveDownloads"
$logFile       = "$archiveFolder\DownloadLog.csv"

# -- Setup --------------------------------------------------------------------

# Create the archive folder if it doesn't exist yet
if (-not (Test-Path $archiveFolder)) {
    New-Item -Path $archiveFolder -ItemType Directory | Out-Null
    Write-Host "[INFO] Created archive folder: $archiveFolder"
}

# Create the CSV log with a header row if it doesn't exist yet
if (-not (Test-Path $logFile)) {
    "Timestamp,Username,OriginalName,DestinationPath,SizeBytes,Status" |
        Out-File -FilePath $logFile -Encoding UTF8
    Write-Host "[INFO] Created log file: $logFile"
}

Write-Host ""
Write-Host "=============================================="
Write-Host "  Download Archiver is running"
Write-Host "  Watching : $watchFolder"
Write-Host "  Archiving: $archiveFolder"
Write-Host "  Log      : $logFile"
Write-Host "  Press Ctrl+C to stop."
Write-Host "=============================================="
Write-Host ""

# -- Snapshot of files already in the folder ----------------------------------
# We don't want to archive files that were already there before we started
$knownFiles = Get-ChildItem -Path $watchFolder -File | Select-Object -ExpandProperty FullName
Write-Host "[INFO] Found $($knownFiles.Count) existing file(s). Waiting for new ones..."
Write-Host ""

# -- Polling Loop -------------------------------------------------------------
while ($true) {
    Start-Sleep -Seconds 2

    $currentFiles = Get-ChildItem -Path $watchFolder -File | Select-Object -ExpandProperty FullName
    $newFiles     = $currentFiles | Where-Object { $_ -notin $knownFiles }

    foreach ($f in $newFiles) {

        $name = Split-Path $f -Leaf

        # Skip Chrome temp files and other incomplete downloads
        if ($name -like "*.crdownload" -or $name -like "*.tmp" -or $name -like "*.part") {
            Write-Host "[SKIP] Temp file ignored: $name" -ForegroundColor DarkGray
            continue
        }

        Write-Host "[NEW] $name" -ForegroundColor Cyan

        # Wait until the file is fully written and not locked (max 15 seconds)
        $ready      = $false
        $retries    = 0
        $maxRetries = 30   # 30 x 500ms = 15 seconds max

        while (-not $ready -and $retries -lt $maxRetries) {
            try {
                $stream = [System.IO.File]::Open($f, 'Open', 'Read', 'None')
                $stream.Close()
                $ready = $true
            } catch {
                Start-Sleep -Milliseconds 500
                $retries++
            }
        }

        $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
        $username  = $env:USERNAME

        # If the file never unlocked, log it and move on
        if (-not $ready) {
            Write-Host "[WARN] $name is still locked after 15s - skipping." -ForegroundColor Yellow
            "$timestamp,$username,$name,N/A,0,LOCK_TIMEOUT" |
                Out-File -Append -FilePath $logFile -Encoding UTF8
            continue
        }

        # Build destination filename: timestamp_username_originalname
        $destFile = Join-Path $archiveFolder "${timestamp}_${username}_${name}"

        # Copy the file
        $status   = "OK"
        $sizBytes = 0

        try {
            Copy-Item -LiteralPath $f -Destination $destFile -Force
            $sizBytes = (Get-Item -LiteralPath $destFile).Length
            Write-Host "[COPY] $name  ($sizBytes bytes)" -ForegroundColor Green
            Write-Host "       -> $destFile" -ForegroundColor DarkGray
        } catch {
            $status = "ERROR: $($_.Exception.Message -replace ',', ';')"
            Write-Host "[FAIL] Could not copy $name" -ForegroundColor Red
            Write-Host "       $status" -ForegroundColor Red
        }

        # Append a row to the CSV log
        "$timestamp,$username,$name,$destFile,$sizBytes,$status" |
            Out-File -Append -FilePath $logFile -Encoding UTF8

        Write-Host ""
    }

    # Update our known files list for the next loop
    $knownFiles = $currentFiles
}
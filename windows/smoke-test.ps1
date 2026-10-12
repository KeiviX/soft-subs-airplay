# Starts the built SoftSubs.exe headless, casts Apple's sample stream with test cues (no TV), and checks
# the rebuilt playlists. Used by CI; also handy on a Windows PC: powershell -File windows\smoke-test.ps1
$ErrorActionPreference = "Stop"
$exe = Join-Path $PSScriptRoot "build\dist\SoftSubs\SoftSubs.exe"

# Invoke-WebRequest returns non-text content types (like HLS playlists) as bytes.
function Get-Text([string]$url) {
    $content = (Invoke-WebRequest $url -UseBasicParsing).Content
    if ($content -is [byte[]]) { return [Text.Encoding]::UTF8.GetString($content) }
    return $content
}
$app = Start-Process $exe -ArgumentList "--no-tray" -PassThru
try {
    $api = "http://127.0.0.1:47800/api"
    for ($i = 0; $i -lt 30; $i++) {
        try { $status = Invoke-RestMethod "$api/status"; break } catch { Start-Sleep 1 }
    }
    if (-not $status) { throw "SoftSubs.exe didn't start" }
    Write-Host "status: $($status.phase) ffmpeg=$($status.ffmpeg)"
    if (-not $status.ffmpeg) { throw "bundled ffmpeg not found" }

    $body = @{
        url = "https://devstreaming-cdn.apple.com/videos/streaming/examples/bipbop_16x9/bipbop_16x9_variant.m3u8"
        title = "Smoke test"
        subtitles = @{ label = "English"; language = "en"; cues = @(@{ start = 1; end = 4; text = "hello" }) }
    } | ConvertTo-Json -Depth 5
    $session = (Invoke-RestMethod "$api/cast" -Method Post -ContentType "application/json" -Body $body).session
    for ($i = 0; $i -lt 30; $i++) {
        $status = Invoke-RestMethod "$api/status"
        if ($status.state -ne "preparing") { break }
        Start-Sleep 1
    }
    Write-Host "state: $($status.state) - $($status.phase)"
    if ($status.state -ne "ready") { throw "cast didn't get ready" }

    $base = "http://127.0.0.1:47800/s/$session"
    $master = Get-Text "$base/master.m3u8?subs=1"
    if ($master -notmatch 'GROUP-ID="softsubs"') { throw "subtitle rendition missing:`n$master" }
    $vtt = Get-Text "$base/subs/0.vtt"
    Write-Host $master.Substring(0, [Math]::Min(400, $master.Length))
    Write-Host $vtt
    if ($vtt -notmatch "MPEGTS:900000") { throw "ffprobe timing missing" }
    Write-Host "Smoke test passed"
} finally {
    Stop-Process -Id $app.Id -Force -ErrorAction SilentlyContinue
}

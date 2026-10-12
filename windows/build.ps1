# Builds dist\SoftSubs-Setup-<version>.exe (helper app + bundled ffmpeg + Chrome extension).
#   powershell -ExecutionPolicy Bypass -File windows\build.ps1 -Version 0.1.0
param([string]$Version = "0.1.0")
$ErrorActionPreference = "Stop"
Set-Location $PSScriptRoot

# ffmpeg/ffprobe (GPL "essentials" build by gyan.dev), bundled so friends don't need to install anything.
if (-not (Test-Path "ffmpeg\ffmpeg.exe")) {
    Write-Host "Downloading ffmpeg..."
    $zip = Join-Path $env:TEMP "ffmpeg-essentials.zip"
    Invoke-WebRequest "https://www.gyan.dev/ffmpeg/builds/ffmpeg-release-essentials.zip" -OutFile $zip
    $extracted = Join-Path $env:TEMP "ffmpeg-essentials"
    Remove-Item $extracted -Recurse -Force -ErrorAction SilentlyContinue
    Expand-Archive $zip -DestinationPath $extracted
    $bin = Get-ChildItem $extracted -Recurse -Filter ffmpeg.exe | Select-Object -First 1
    New-Item -ItemType Directory -Force ffmpeg | Out-Null
    Copy-Item (Join-Path $bin.DirectoryName "ffmpeg.exe"), (Join-Path $bin.DirectoryName "ffprobe.exe") ffmpeg\
    Copy-Item (Join-Path $bin.Directory.Parent.FullName "LICENSE") ffmpeg\LICENSE.txt -ErrorAction SilentlyContinue
}

python -m pip install --quiet -r requirements.txt pyinstaller
(Get-Content softsubs\__init__.py) -replace '__version__ = ".*"', "__version__ = `"$Version`"" | Set-Content softsubs\__init__.py

python -m PyInstaller --noconfirm --clean --windowed --name SoftSubs --icon "$PSScriptRoot\softsubs\icon.ico" `
    --distpath build\dist --workpath build\work --specpath build `
    --add-data "$PSScriptRoot\softsubs\panel.html;softsubs" `
    --add-binary "$PSScriptRoot\ffmpeg\ffmpeg.exe;ffmpeg" --add-binary "$PSScriptRoot\ffmpeg\ffprobe.exe;ffmpeg" `
    --collect-all pyatv --collect-all pychromecast --collect-submodules zeroconf --hidden-import pystray._win32 `
    launcher.py
if ($LASTEXITCODE -ne 0) { throw "PyInstaller failed" }

python ..\scripts\build_chrome.py $Version
if ($LASTEXITCODE -ne 0) { throw "Packaging the Chrome extension failed" }

$iscc = "${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe"
if (-not (Test-Path $iscc)) {
    choco install innosetup -y --no-progress | Out-Null
}
$env:SOFTSUBS_VERSION = $Version
& $iscc /Q installer.iss
if ($LASTEXITCODE -ne 0) { throw "Inno Setup failed" }
Write-Host "Built ..\dist\SoftSubs-Setup-$Version.exe"

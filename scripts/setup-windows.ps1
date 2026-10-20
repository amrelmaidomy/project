[CmdletBinding()]
param(
    [string]$UvPath,
    [string]$ModelsDirectory = (Join-Path $env:USERPROFILE 'Ma3akModels'),
    [switch]$UseCuda,
    [switch]$Offline,
    [string]$ReferenceAudio,
    [string]$ReferenceText
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$ProjectRoot = Split-Path $PSScriptRoot -Parent
$Backend = Join-Path $ProjectRoot 'backend'
if (-not $UvPath) {
    $LocalUv = Join-Path $Backend 'uv.exe'
    $InstalledUv = Get-Command uv -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $LocalUv) { $UvPath = $LocalUv }
    elseif ($InstalledUv) { $UvPath = $InstalledUv.Source }
    else { throw 'Put uv.exe inside backend, or install uv and add it to PATH. See docs/android-studio-windows.md.' }
}
# Resolve a supplied relative path before any project command changes directory.
$UvPath = (Get-Command $UvPath -CommandType Application -ErrorAction Stop).Source
if ($UseCuda) {
    $GpuCommand = Get-Command nvidia-smi -ErrorAction SilentlyContinue
    if (-not $GpuCommand) { throw 'Install/update the NVIDIA driver first, or run setup without -UseCuda for CPU mode.' }
    & $GpuCommand.Source --query-gpu=name,memory.total,driver_version --format=csv,noheader
    if ($LASTEXITCODE -ne 0) { throw 'The NVIDIA driver is unavailable. Use CPU setup or fix the driver.' }
}
Write-Host '1/3 Installing API dependencies (Python 3.12)...'
& $UvPath sync --project $Backend --frozen --no-dev --python 3.12
if ($LASTEXITCODE -ne 0) { throw 'API installation failed.' }
$Runtime = Join-Path $Backend 'tts_runtime'
if ($UseCuda) { $Runtime = Join-Path $Runtime 'cuda' }
Write-Host '2/3 Installing the isolated Habibi runtime. This first download can be large...'
& $UvPath sync --project $Runtime --frozen --no-dev --python 3.12
if ($LASTEXITCODE -ne 0) { throw 'Habibi installation failed.' }
Write-Host '3/3 Verifying/downloading Whisper turbo, Egyptian Habibi and Vocos...'
$Prepare = Join-Path $PSScriptRoot 'prepare-models.py'
$ConfigFile = Join-Path $ProjectRoot '.local/model-config.json'
$PrepareArguments = @('--models-dir', $ModelsDirectory, '--config', $ConfigFile)
if ($Offline) { $PrepareArguments += '--offline' }
if ($ReferenceAudio -or $ReferenceText) {
    if (-not $ReferenceAudio -or -not $ReferenceText) { throw 'Supply both -ReferenceAudio and -ReferenceText.' }
    $PrepareArguments += @('--reference-audio', $ReferenceAudio, '--reference-text', $ReferenceText)
}
& $UvPath run --project $Backend --frozen --no-dev python $Prepare @PrepareArguments
if ($LASTEXITCODE -ne 0) { throw 'Model preparation failed. Read the specific message above.' }
$Config = Get-Content -LiteralPath $ConfigFile -Raw -Encoding UTF8 | ConvertFrom-Json
$Config | Add-Member -NotePropertyName TTS_PYTHON -NotePropertyValue (Join-Path $Runtime '.venv/Scripts/python.exe') -Force
$TtsDevice = 'cpu'
if ($UseCuda) { $TtsDevice = 'cuda' }
$Config | Add-Member -NotePropertyName TTS_DEVICE -NotePropertyValue $TtsDevice -Force
$Config | Add-Member -NotePropertyName TTS_NFE_STEPS -NotePropertyValue '32' -Force
$Config | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $ConfigFile -Encoding UTF8
Write-Host 'Setup complete. Run:'
Write-Host 'powershell -ExecutionPolicy Bypass -File .\scripts\start-backend-windows.ps1'
Write-Host 'Then open the mobile folder in Android Studio and select an Android emulator.'

[CmdletBinding()]
param([string]$UvPath, [int]$Port = 8000)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$ProjectRoot = Split-Path $PSScriptRoot -Parent
$Backend = Join-Path $ProjectRoot 'backend'
$ConfigFile = Join-Path $ProjectRoot '.local/model-config.json'
if (-not (Test-Path -LiteralPath $ConfigFile)) { throw 'Run scripts/setup-windows.ps1 first.' }
if (-not $UvPath) {
    $LocalUv = Join-Path $Backend 'uv.exe'
    $InstalledUv = Get-Command uv -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $LocalUv) { $UvPath = $LocalUv }
    elseif ($InstalledUv) { $UvPath = $InstalledUv.Source }
    else { throw 'Put uv.exe inside backend, or install uv and add it to PATH.' }
}
$UvPath = (Get-Command $UvPath -CommandType Application -ErrorAction Stop).Source
$Config = Get-Content -LiteralPath $ConfigFile -Raw -Encoding UTF8 | ConvertFrom-Json
$AllowedKeys = @('WHISPER_MODEL','WHISPER_DEVICE','WHISPER_COMPUTE_TYPE','MA3AK_MODELS_DIR',
    'TTS_MODEL_PATH','TTS_VOCAB_PATH','TTS_VOCODER_PATH','TTS_DEVICE','TTS_PYTHON',
    'TTS_REFERENCE_AUDIO','TTS_REFERENCE_TEXT','TTS_TIMEOUT_SECONDS','TTS_NFE_STEPS','TTS_CPU_THREADS')
foreach ($Key in $AllowedKeys) {
    $Property = $Config.PSObject.Properties[$Key]
    if ($Property -and $null -ne $Property.Value) {
        [Environment]::SetEnvironmentVariable($Key, [string]$Property.Value, 'Process')
    }
}
$env:PYTHONUTF8 = '1'
Write-Host "Starting local backend on port $Port. Keep this window open."
Write-Host "Android emulator API: http://10.0.2.2:$Port (Flutter defaults to port 8000)."
Write-Host 'First synthesis loads Habibi. Watch health.tts and the app status; CPU can be slow.'
Push-Location $Backend
try {
    & $UvPath run --frozen --no-dev uvicorn main:app --host 127.0.0.1 --port $Port
    if ($LASTEXITCODE -ne 0) { throw "Backend exited with code $LASTEXITCODE." }
} finally { Pop-Location }

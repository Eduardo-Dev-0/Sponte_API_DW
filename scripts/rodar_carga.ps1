# Roda a carga Sponte -> PostgreSQL e guarda o log em logs\carga_AAAAMMDD_HHMMSS.log
# Uso (de qualquer pasta):
#   powershell -ExecutionPolicy Bypass -File scripts\rodar_carga.ps1
#   powershell -ExecutionPolicy Bypass -File scripts\rodar_carga.ps1 -SoProcessar
param([switch]$SoProcessar, [switch]$SemFrequencia)

$ErrorActionPreference = "Continue"
$raiz = Split-Path -Parent $PSScriptRoot
Set-Location $raiz
New-Item -ItemType Directory -Force -Path "logs" | Out-Null

# Evita acentos quebrados no console e no log
$env:PYTHONIOENCODING = "utf-8"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$log = "logs\carga_{0}.log" -f (Get-Date -Format "yyyyMMdd_HHmmss")
$python = ".\.venv\Scripts\python.exe"
$argumentos = @("src\sponte_loader.py")
if ($SoProcessar) { $argumentos += "--so-processar" }

& $python @argumentos 2>&1 | Tee-Object -FilePath $log
$codigo = $LASTEXITCODE
if ($codigo -eq 0 -and -not $SemFrequencia) {
    $freq = @("src\carga_frequencia.py")
    if ($SoProcessar) { $freq += "--so-processar" }
    & $python @freq 2>&1 | Tee-Object -FilePath $log -Append
    $codigo = $LASTEXITCODE
}
Write-Host "Log salvo em $log (codigo de saida: $codigo)"
# Chamado com ". script" (ponto no inicio): nao encerra a sessao do terminal
if ($MyInvocation.InvocationName -eq ".") { return }
exit $codigo

# Cria no Agendador de Tarefas do Windows a carga diaria Sponte -> PostgreSQL.
# Rode UMA vez, no PC onde esta o banco (de qualquer pasta):
#   powershell -ExecutionPolicy Bypass -File scripts\agendar_carga.ps1
#   powershell -ExecutionPolicy Bypass -File scripts\agendar_carga.ps1 -Hora 06:30
#   powershell -ExecutionPolicy Bypass -File scripts\agendar_carga.ps1 -Remover
param(
    [string]$Hora = "07:30",
    [string]$Nome = "SponteDW-Carga-Diaria",
    [switch]$Remover
)
$ErrorActionPreference = "Stop"

if ($Remover) {
    Unregister-ScheduledTask -TaskName $Nome -Confirm:$false
    Write-Host "Tarefa '$Nome' removida."
    exit 0
}

$raiz   = Split-Path -Parent $PSScriptRoot
$script = Join-Path $raiz "scripts\rodar_carga.ps1"
if (-not (Test-Path $script)) { throw "Nao encontrei $script" }
if (-not (Test-Path (Join-Path $raiz ".venv\Scripts\python.exe"))) {
    throw "A .venv nao existe. Rode antes scripts\setup_pc.ps1"
}

$acao = New-ScheduledTaskAction -Execute "powershell.exe" `
    -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$script`"" `
    -WorkingDirectory $raiz
$gatilho = New-ScheduledTaskTrigger -Daily -At $Hora
# Se o PC estava desligado no horario, roda assim que for possivel; tenta de novo se falhar.
$config = New-ScheduledTaskSettingsSet -StartWhenAvailable `
    -ExecutionTimeLimit (New-TimeSpan -Hours 2) `
    -RestartCount 2 -RestartInterval (New-TimeSpan -Minutes 15)

Register-ScheduledTask -TaskName $Nome -Action $acao -Trigger $gatilho -Settings $config `
    -Description "Carga diaria Sponte -> PostgreSQL (Projeto SPT-DW)" -Force | Out-Null

Write-Host "Tarefa '$Nome' criada: todos os dias as $Hora (usuario atual, com a sessao aberta)."
Write-Host "Testar agora:      Start-ScheduledTask -TaskName $Nome"
Write-Host "Ver o resultado:   Get-ScheduledTaskInfo -TaskName $Nome   (LastTaskResult 0 = ok)"
Write-Host "Logs das cargas:   $raiz\logs"

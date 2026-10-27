# Prepara um PC novo: cria a .venv, instala as dependências e cria o .env a partir do exemplo.
# Uso (de qualquer pasta):
#   powershell -ExecutionPolicy Bypass -File scripts\setup_pc.ps1
$ErrorActionPreference = "Stop"
$raiz = Split-Path -Parent $PSScriptRoot
Set-Location $raiz

if (-not (Get-Command python -ErrorAction SilentlyContinue)) {
    throw "Python nao encontrado no PATH. Instale o Python 3.11+ e marque 'Add python.exe to PATH'."
}

if (-not (Test-Path ".venv")) {
    Write-Host "Criando .venv ..."
    python -m venv .venv
    if ($LASTEXITCODE -ne 0) { throw "Falha ao criar a .venv" }
}

Write-Host "Instalando dependencias ..."
& ".\.venv\Scripts\python.exe" -m pip install --upgrade pip
& ".\.venv\Scripts\python.exe" -m pip install -r requirements.txt
if ($LASTEXITCODE -ne 0) { throw "Falha ao instalar as dependencias" }

if (-not (Test-Path ".env")) {
    Copy-Item ".env.example" ".env"
    Write-Host "Arquivo .env criado a partir do exemplo. Edite-o e preencha as credenciais."
} else {
    Write-Host ".env ja existe e foi mantido como esta."
}
Write-Host "Pronto. Proximo passo: criar o banco (docs\SETUP.md, passo 5)."

# Instalar e retomar o projeto em outro PC

Este guia serve para **(a)** montar o projeto num PC novo e **(b)** continuar de onde paramos.
Comandos em PowerShell (Windows). Rode-os na pasta raiz do projeto, salvo indicação contrária.

## 0. Decida onde fica o banco

| Cenário | Quando usar | Consequência |
|---|---|---|
| **A. Um PostgreSQL central** (recomendado) | Mais de um PC vai rodar a carga ou consultar o DW | Cada PC só precisa do código e do `.env` apontando para o servidor (`PG_HOST`). **Pule o passo 5.** |
| **B. Um PostgreSQL local por PC** | Uso individual ou teste | Cada PC tem seu próprio banco. Os snapshots diários e o histórico de eventos só existem onde a carga rodou. Para levar os dados de um PC ao outro, use o passo 9 |

Sugestão: manter o banco num único lugar (um servidor ou o PC que roda a carga todo dia) e usar os outros PCs só para desenvolver e consultar. Liberar acesso remoto ao PostgreSQL (`listen_addresses`, `pg_hba.conf`, porta 5432) deve ser feito com a TI, restrito à rede interna.

## 1. Pré-requisitos

- **Python 3.11 ou superior**, com a opção "Add python.exe to PATH" marcada na instalação.
- **Git**.
- **PostgreSQL 13 ou superior** (só no cenário B, ou no servidor do cenário A) e, opcionalmente, o **pgAdmin**.
- Acesso à API do Sponte: **código do cliente** (número da sede) e **token**.

## 2. Obter o código

```powershell
git clone <URL-DO-REPOSITORIO> Projeto-SPT-DW
cd Projeto-SPT-DW
```

Sem repositório remoto ainda: copie a pasta do projeto inteira (menos `.venv`, `.env` e `logs`).

## 3. Ambiente Python

```powershell
powershell -ExecutionPolicy Bypass -File scripts\setup_pc.ps1
```

O script cria a `.venv`, instala o `requirements.txt` e cria o `.env` a partir do `.env.example`. Manualmente, o equivalente é:

```powershell
python -m venv .venv
.\.venv\Scripts\python.exe -m pip install -r requirements.txt
Copy-Item .env.example .env
```

## 4. Configurar o `.env`

Edite o `.env` (formato `NOME=valor`, sem aspas e sem espaços ao redor do `=`; salve em UTF-8):

| Variável | O que é |
|---|---|
| `SPONTE_COD_CLIENTE` | Número do código da sede no Sponte (só dígitos) |
| `SPONTE_TOKEN` | Token (chave da API) da mesma sede |
| `PG_HOST` | `localhost`, ou o endereço do servidor (cenário A) |
| `PG_PORT` | `5432`, se não mudou na instalação |
| `PG_DB` | `sponte_dw` |
| `PG_USER` / `PG_PASSWORD` | Usuário e senha do PostgreSQL |

O `.env` é pessoal de cada PC e **não vai para o Git**. O token e a senha não devem ser enviados por chat ou e-mail.

## 5. Criar o banco e o schema (cenário B, ou uma única vez no servidor)

Se o banco **já existe e já tem o schema**, pule este passo.

**Pelo pgAdmin:** crie um banco chamado `sponte_dw`, abra a Query Tool nele e execute o arquivo `sql\01_schema.sql`.

**Pelo psql** (o caminho padrão no Windows é `C:\Program Files\PostgreSQL\<versão>\bin`; adicione ao PATH ou use o caminho completo):

```powershell
psql -U postgres -c "CREATE DATABASE sponte_dw;"
psql -U postgres -d sponte_dw -v ON_ERROR_STOP=1 -f sql\01_schema.sql
```

Banco criado com a **versão antiga** do modelo (etapa 2, com `dim_turma` em versões)? Não use o `01_schema.sql`. Rode no lugar dele `sql\migrations\002_simplificacao_dim_turma.sql`, uma única vez, e depois o passo 7 com `-SoProcessar`.

Depois do schema (ou das migrações), rode também `sql\02_views_bi.sql`: ele cria o schema `bi` com as views de consumo (alunos por turma, turmas por professor, comparação de cursos, alunos por situação). Pode ser rodado de novo sempre que o arquivo mudar.

## 6. Primeira carga

```powershell
powershell -ExecutionPolicy Bypass -File scripts\rodar_carga.ps1
```

Ou, com a `.venv` ativa (`.\.venv\Scripts\Activate.ps1`): `python src\sponte_loader.py`.

Saída esperada: uma linha por turma do recorte, a linha `raw gravado: ...` e, no fim, a contagem de eventos da carga (na primeira carga, tudo com `carga_inicial = True`). O log fica em `logs\`. Não chame o script com ponto na frente (`. .\scripts\rodar_carga.ps1`); use o comando acima ou `& .\scripts\rodar_carga.ps1`.

## 7. Conferir

Abra `sql\consultas\validacoes.sql` no pgAdmin e rode as consultas. As principais:

- **(2)** volume da carga e **(4)** eventos: reprocessar a mesma carga não pode aumentar a contagem.
- **(6)** e **(7)** devem voltar zero linhas.

Para reprocessar a última carga sem chamar a API (seguro e repetível):

```powershell
powershell -ExecutionPolicy Bypass -File scripts\rodar_carga.ps1 -SoProcessar
```

## 8. Rotina entre PCs

- Antes de trabalhar: `git pull`. Ao terminar: `git commit` e `git push`.
- O `.env` e a `.venv` ficam em cada PC. Se o `requirements.txt` mudar, rode de novo o `scripts\setup_pc.ps1`.
- Se o banco é central (cenário A), todos veem os mesmos dados. Rode a carga em **um** PC só, para não haver cargas simultâneas.

## 9. Levar os dados de um PostgreSQL para outro

```powershell
# no PC de origem
pg_dump -U postgres -Fc -f sponte_dw.dump sponte_dw
# no PC de destino (banco vazio, sem rodar o 01_schema.sql)
psql -U postgres -c "CREATE DATABASE sponte_dw;"
pg_restore -U postgres -d sponte_dw --no-owner sponte_dw.dump
```

O arquivo `.dump` tem dados pessoais (nome, CPF, e-mail). Não o envie por e-mail nem o suba no Git; o `.gitignore` já o ignora.

## 10. Agendar a carga diária (Windows)

A carga deve rodar todo dia, **no PC onde está o banco**. Ele precisa estar ligado e com o serviço do PostgreSQL ativo no horário. O `rodar_carga.ps1` roda a carga de cadastro e, em seguida, a de frequência.

```powershell
powershell -ExecutionPolicy Bypass -File scripts\agendar_carga.ps1 -Hora 07:30
```

Cria a tarefa `SponteDW-Carga-Diaria` no Agendador de Tarefas, para o usuário atual (com a sessão aberta). Se o PC estiver desligado no horário, a carga roda assim que for possível, e tenta de novo (2 vezes, a cada 15 minutos) se falhar. Escolha um horário fixo em que o PC esteja ligado: cada carga registra o estado do Sponte naquele momento.

- Testar agora: `Start-ScheduledTask -TaskName SponteDW-Carga-Diaria`
- Resultado da última execução: `Get-ScheduledTaskInfo -TaskName SponteDW-Carga-Diaria` (`LastTaskResult` 0 = ok)
- Logs: pasta `logs\`. No banco: `SELECT carga_id, status, observacao FROM raw.carga ORDER BY carga_id DESC LIMIT 5;`
- Remover: `powershell -ExecutionPolicy Bypass -File scripts\agendar_carga.ps1 -Remover`

Evite rodar a carga manualmente no mesmo momento em que a tarefa agendada roda.

---

## Retomar de onde paramos (checklist atual)

Estado: núcleo do DW e frequência em uso; Power BI montado. Ajuste em andamento: a frequência dos alunos que passaram pela turma. A carga está sendo rodada à mão, enquanto não se decide qual máquina ou servidor vai agendá-la.

**Rotina manual (nesta ordem):** `python src\sponte_loader.py` e depois `python src\carga_frequencia.py`. O `scripts\rodar_carga.ps1` faz as duas em sequência.

1. **Banco:** rode de novo `sql\migrations\004_frequencia.sql` (repetível; acrescenta uma coluna em `raw.frequencia_janela`).
2. **Sonda:** `python src\sonda_ex_alunos.py --turma 623 --mes 2026-05` e veja a conclusão (SIM ou NÃO).
3. **Carga:** `python src\carga_frequencia.py`. Na primeira vez reconsulta todos os meses uma única vez (mais longa).
4. **Conferir:** a consulta 11 de `sql\consultas\qualidade_frequencia.sql` (matrículas no mês x alunos na frequência) e, no Power BI, atualizar o relatório.
5. Depois: definir a máquina da carga diária (seção 10) e subir o projeto para o GitHub.

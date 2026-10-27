# Projeto SPT-DW: Sponte → Data Warehouse

Pipeline que lê a API do **Sponte** (sistema acadêmico) e alimenta um **Data Warehouse em PostgreSQL**, com foco em **turmas** e nas **matrículas dos alunos** dessas turmas: quem entra, quem sai e quando.

> **Status:** núcleo funcionando. Três cargas reais concluídas (31 turmas, 703 matrículas, 682 alunos com CPF e e-mail). Detecta entradas, saídas, mudanças de situação e transferências entre turmas. A carga de frequência (por dia de aula) está pronta e aguarda a primeira execução real. O que falta e as metas estão em [docs/ROADMAP.md](docs/ROADMAP.md).

## Objetivo

1. Ter, num só lugar, o retrato atual e o **histórico** das turmas em andamento e em fase de matrícula.
2. Registrar o **fluxo de alunos** (entradas, saídas, trancamentos, cancelamentos) com as datas do próprio Sponte.
3. Servir de base para as próximas metas: **análise de frequência** e **unificação da criação de acessos** (AD e Moodle).

## Escopo atual

- **Turmas Vigente** (já iniciadas, com alunos entrando e saindo) e **Aberta** (em fase de matrículas, com data de início prevista).
- Ficam de fora: pré-matrícula, concluída, encerrada, mesclada e bloqueada.
- **Uma sede por vez** (hoje, Bezerra). Todas as tabelas já carregam o código da sede (`cod_cliente`), então incluir outras sedes não exige mudar o modelo.
- Fora do escopo por enquanto: frequência (meta futura), notas e financeiro.

## Como funciona

```
API Sponte (SOAP/WSDL)
   └─ src/sponte_loader.py ─▶ raw.*  ─▶ stg.* (views) ─▶ dw.processar_carga() ─▶ dim_turma
                              JSON       dados tipados                           dim_aluno
                              como veio                                          fato_matricula
                                                                                 fato_matricula_evento
                                                                                 snapshot_turma_dia
```

1. O loader descobre as turmas, filtra Vigente/Aberta e busca, por turma, os dados da turma, as matrículas e os integrantes.
2. Tudo é gravado em `raw` (JSON) e a carga só é marcada como `ok` se **nenhuma** chamada falhou.
3. A função `dw.processar_carga` compara a carga nova com o estado anterior e gera os eventos.

Detalhes das tabelas: [docs/MODELO_DADOS.md](docs/MODELO_DADOS.md). Métodos e filtros da API: [docs/API_SPONTE.md](docs/API_SPONTE.md).

## Estrutura do repositório

```
Projeto-SPT-DW/
├── README.md
├── .env.example          # modelo das variáveis (copie para .env)
├── .gitignore
├── requirements.txt
├── docs/
│   ├── SETUP.md          # instalar / retomar o projeto em outro PC
│   ├── ROADMAP.md        # metas e próximos passos
│   ├── MODELO_DADOS.md   # tabelas, eventos e regras do DW
│   ├── FREQUENCIA.md     # plano da análise de frequência (Meta 1)
│   ├── ATUALIZACAO.md    # o que o DW atualiza quando o Sponte muda
│   ├── PBIX_FREQUENCIA.md # layout e medidas do Power BI (3 páginas)
│   └── API_SPONTE.md     # métodos usados, filtros e armadilhas
├── sql/
│   ├── 01_schema.sql     # instalação do zero (banco vazio)
│   ├── 02_views_bi.sql   # views de consumo (schema bi), rodar depois do schema
│   ├── migrations/
│   │   ├── 002_simplificacao_dim_turma.sql   # só para bancos da versão antiga
│   │   ├── 003_horario_e_mudanca_turma.sql   # horário formatado e evento de transferência
│   │   ├── 004_frequencia.sql                # tabelas e função da frequência
│   │   └── 005_sede.sql                      # nome de cada sede (código de cliente)
│   └── consultas/
│       ├── validacoes.sql                    # conferências (somente leitura)
│       ├── qualidade_dados.sql               # lista do que corrigir no cadastro do Sponte
│       └── qualidade_frequencia.sql          # dias parciais, aulas não concluídas, calendário
├── src/
│   ├── sponte_loader.py  # carga: API → raw → dw
│   ├── carga_frequencia.py # carga de frequência: GetFrequenciaTurma + GetDiarioAulas → dw
│   ├── sonda_alunos.py   # sonda de testes (CPF/e-mail, alterados, horários)
│   ├── sonda_ex_alunos.py # sonda: a API devolve a frequência de quem saiu da turma?
│   ├── sonda_frequencia.py # sonda da frequência (Meta 1)
│   ├── auditoria_frequencia.py # aulas por mês x dias previstos e regra do dia
│   └── exportar_pendencias.py  # exporta em CSV o que corrigir no Sponte
├── scripts/
│   ├── setup_pc.ps1      # prepara um PC novo (venv, dependências, .env)
│   ├── rodar_carga.ps1   # roda a carga com log em logs/
│   └── agendar_carga.ps1 # agenda a carga diária no Windows
├── tools/                # (futuro) integração das ferramentas de acesso
│   ├── ad_manager/
│   └── moodle/
├── data/                 # saídas locais (ignorado pelo Git)
└── logs/                 # logs de carga (ignorado pelo Git)
```

## Começando

Passo a passo completo, inclusive para um PC novo: **[docs/SETUP.md](docs/SETUP.md)**. Resumo:

```powershell
# 1) ambiente Python e .env
powershell -ExecutionPolicy Bypass -File scripts\setup_pc.ps1
# 2) edite o .env (token do Sponte e dados do PostgreSQL)
# 3) crie o banco e o schema (ver SETUP.md, passo 5)
# 4) rode a carga
powershell -ExecutionPolicy Bypass -File scripts\rodar_carga.ps1
```

Rotina diária (com a `.venv` ativa): `python src\sponte_loader.py`. Para reprocessar a última carga sem chamar a API: `python src\sponte_loader.py --so-processar`. Para reconsultar CPF e e-mail de todos os alunos: `--atualizar-alunos`. A frequência tem carga própria (`python src\carga_frequencia.py`), que o `scripts\rodar_carga.ps1` já executa depois da carga de cadastro.

## Views de consumo (schema `bi`)

`sql/02_views_bi.sql` cria views prontas para relatório, sem nome, CPF ou e-mail de aluno:

| View | Responde |
|---|---|
| `bi.vw_alunos_por_turma` | Alunos vigentes, trancados, cancelados etc. por turma, vagas livres e ocupação |
| `bi.vw_turmas_por_professor` | Quantas turmas, cursos e alunos cada professor tem |
| `bi.vw_cursos_comparativo` | Qual curso tem mais turmas e qual tem mais alunos, em quantidade e em proporção |
| `bi.vw_alunos_por_situacao` | Alunos e matrículas por situação (Vigente, Trancado, Cancelado...) |
| `bi.vw_frequencia_turma_mes`, `_aluno_mes`, `_aluno`, `_curso_mes` | Frequência por dia de aula: presenças, faltas e percentual por turma, aluno e curso |
| `bi.vw_calendario_divergencias` | Turmas e meses em que as aulas ocorridas não batem com as previstas, com as datas a mais e a menos |
| `bi.vw_dias_sem_aula` | Datas em que turmas ficaram sem aula e quantas turmas do mesmo dia da semana pararam junto (feriado ou evento?) |
| `bi.vw_pendencias_sponte` | Lista do que corrigir no Sponte: data, turma, módulo e disciplina (e aluno nas faltas parciais) |
| `bi.vw_aluno_turma`, `vw_movimento_matricula_mes`, `dim_turma`, `dim_aluno` | Para o Power BI: resumo por aluno na turma (primeiro dia, entrada, faltas seguidas), entradas e saídas por mês, e as dimensões |
| `bi.vw_calendario_frequencia`, `vw_frequencia_aluno_dia`, `vw_frequencia_turma`, `vw_frequencia_curso`, `vw_cobertura_frequencia`, `dim_data` | Para o Power BI: calendário da frequência com nome do mês, módulo e disciplina; frequência geral e por mês; cobertura do histórico; tabela de datas |

## Decisões de projeto

- **`raw` guarda o JSON como veio** (exceto campos descartados por privacidade), então o DW pode ser reconstruído sem nova chamada à API.
- **A matrícula é o fato principal.** O `GetMatriculas` traz também as matrículas que saíram, com `DataEncerramento`. Os integrantes da turma servem de conferência.
- **Carga tudo-ou-nada:** se qualquer chamada falhar, a carga é marcada como `erro` e nada é processado. Isso evita eventos falsos de "sumiu da API".
- **Turma que sai do recorte** (ex.: Vigente → Concluída) é coletada mais uma vez, para o DW registrar o estado final.
- **Dados pessoais:** o `raw` só guarda os campos necessários. CPF e e-mail vão para `dim_aluno` (CPF como texto, só dígitos). O `GetAlunos4` devolve também a senha do portal; ela **nunca** é gravada.

## Segurança

- O `.env` (token do Sponte, senha do banco) nunca vai para o Git. Use o `.env.example` como modelo.
- A governança de dados (acessos por perfil no PostgreSQL, tempo de retenção do `raw`, rotação do token) será tratada numa etapa própria. Está no [roadmap](docs/ROADMAP.md).

## Problemas comuns

| Sintoma | Causa provável | O que fazer |
|---|---|---|
| `KeyError: 'NOME'` em `os.environ[...]` | O nome da variável no código não existe no `.env` | Dentro dos colchetes vai o **nome** da variável, e o valor fica no `.env` |
| `python-dotenv could not parse statement` | Linha do `.env` fora do formato `NOME=valor` ou arquivo não está em UTF-8 | Sem aspas, sem espaço ao redor do `=`, salvar em UTF-8 |
| `21 - Informe pelo menos um parâmetro de busca` | O método exige filtro | Use `TurmaID=<id>` (ver API_SPONTE.md) |
| `relation "raw.carga" does not exist` | Schema não instalado | Rode `sql/01_schema.sql` no banco |
| `column "atual" does not exist` | Loader antigo com o banco já migrado | Use o `src/sponte_loader.py` atual |
| Script `.ps1` bloqueado | Política de execução do Windows | Chame com `powershell -ExecutionPolicy Bypass -File ...` |
| `password authentication failed` / `connection refused` | `PG_*` errado ou serviço do PostgreSQL parado | Confira o `.env` e o serviço `postgresql` |

## Documentação

- [docs/SETUP.md](docs/SETUP.md): instalação e retomada em outro PC
- [docs/ROADMAP.md](docs/ROADMAP.md): metas e próximos passos
- [docs/MODELO_DADOS.md](docs/MODELO_DADOS.md): modelo de dados
- [docs/API_SPONTE.md](docs/API_SPONTE.md): referência da API usada

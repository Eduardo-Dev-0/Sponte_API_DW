# Modelo de dados

Três camadas no PostgreSQL. Todas as tabelas carregam `cod_cliente` (código da sede no Sponte).
O schema completo está em `sql/01_schema.sql`.

## raw: o que a API devolveu

| Tabela | Conteúdo |
|---|---|
| `raw.carga` | Uma linha por execução do loader: `status` (`em_andamento`, `ok`, `erro`), início, fim e observação |
| `raw.turma` | Retorno do `GetTurmas2` por turma, em JSONB |
| `raw.matricula` | Retorno do `GetMatriculas` por matrícula (sem `Contratante` nem listas de disciplinas) |
| `raw.integrante` | Retorno do `GetIntegrantesTurmas` por integrante (sem a lista de disciplinas) |
| `raw.aluno` | Retorno do `GetAlunos4`, apenas `AlunoID`, `Nome`, `CPF` e `Email` (preenchida só para alunos novos ou alterados; ver abaixo) |

Cada carga bem-sucedida tem seus próprios registros. Nada é apagado.

## stg: views que tipam o JSON

`stg.carga_atual` aponta para a última carga `ok` de cada sede. `stg.turma`, `stg.matricula`, `stg.integrante` e `stg.aluno` leem só essa carga e convertem os campos (datas `dd/mm/aaaa` viram `date`, CPF fica só com dígitos, e-mail em minúsculas).

## dw: modelo final

| Tabela | Chave | O que guarda |
|---|---|---|
| `dim_turma` | `(cod_cliente, turma_id)` | Uma linha por turma, sobrescrita a cada carga: nome, sigla, situação, turno, horário (formato "Segunda 18:00 às 22:00", convertido do texto do Sponte; se não seguir o padrão, fica o texto original), curso, datas, vagas máximas, professor |
| `dim_aluno` | `(cod_cliente, aluno_id)` | Nome, CPF (texto, só dígitos), e-mail. CPF e e-mail só são trocados quando a carga traz valor novo |
| `fato_matricula` | `(cod_cliente, contrato_id)` | Estado atual de cada matrícula, **inclusive as que saíram**: situação, datas de matrícula, início, término e encerramento |
| `fato_matricula_evento` | `evento_id` | Linha do tempo: entradas, saídas, mudanças de situação e desaparecimentos |
| `snapshot_turma_dia` | `(cod_cliente, turma_id, data_ref)` | Retrato diário: situação, datas previstas, vagas ocupadas, integrantes, matrículas vigentes |

### Eventos (`fato_matricula_evento.tipo`)

| Tipo | Quando é gerado | `data_negocio` |
|---|---|---|
| `entrada` | Contrato novo na API | `DataMatricula` |
| `saida` | Contrato que passa a ter `DataEncerramento` (Cancelado, Rescindido, Trancado ou Encerrado), ou contrato novo já encerrado | `DataEncerramento` |
| `mudanca_situacao` | A situação de um contrato conhecido mudou | `DataEncerramento`, se houver; senão a data da carga |
| `mudanca_turma` | Contrato conhecido que passou a aparecer em **outra turma** (transferência). `turma_id_anterior` guarda a turma de origem | Data da carga (o Sponte não informa a data da transferência) |
| `sumiu_da_api` | Contrato conhecido que deixou de vir, numa turma que continua no recorte. Pode ser exclusão no Sponte **ou** transferência para uma turma fora do recorte | Data da carga |

Regras que ajudam a ler os dados:
- Uma saída gera **dois** eventos (`mudanca_situacao` e `saida`). **Para contar saídas, use `tipo = 'saida'`.**
- Transferência entre turmas é só `mudanca_turma`: **não** conta como entrada nem como saída. Entradas e saídas por turma devem ser lidas junto com as transferências.
- Se um aluno sai e volta (ex.: Encerrado para Vigente), o `saida` antigo continua no histórico e a volta aparece como `mudanca_situacao` para Vigente.
- `data_negocio` é a data informada pelo Sponte; `detectado_em` é quando o loader percebeu.
- `carga_inicial = true` marca o histórico reconstruído na primeira carga. As datas do Sponte permitem montar entradas e saídas antigas sem esperar acumular snapshots.
- `fato_matricula.ativa_na_api = false` indica uma matrícula que existia e sumiu do Sponte (por exemplo, numa limpeza de dados).

### Como CPF e e-mail chegam ao DW

O `GetAlunos4` não tem filtro por turma, então é uma chamada por aluno. A cada carga o loader consulta:
- os alunos do recorte **nunca consultados** (a primeira carga consulta todos);
- os que o `GetAlunosAlterados` aponta como alterados desde a última consulta (janela de 1, 7, 15 ou 30 dias, escolhida pelo tempo passado);
- **todos**, se a última consulta foi há mais de 30 dias ou se rodar com `--atualizar-alunos`.

Só `AlunoID`, `Nome`, `CPF` e `Email` são gravados; o resto do retorno (RG, endereço, telefones, login e senha do portal) é descartado antes de chegar ao banco.

### Outras regras

- **Situação da turma ao longo do tempo** (ex.: Aberta → Vigente, mudança da data prevista de início) fica em `snapshot_turma_dia`, não em `dim_turma`.
- A data de referência do snapshot usa o fuso `America/Sao_Paulo`. Rodar a carga duas vezes no mesmo dia sobrescreve o retrato do dia.
- `dw.processar_carga(<sede>)` é repetível: reprocessar a mesma carga não duplica eventos.

## bi: camada de consumo

Views em `sql/02_views_bi.sql`, pensadas para relatório e BI. Só entram turmas Vigente e Aberta e matrículas ainda presentes na API. Nenhuma expõe nome, CPF ou e-mail de aluno, então dá para liberar acesso só ao schema `bi`.

| View | Conteúdo |
|---|---|
| `bi.vw_alunos_por_turma` | Uma linha por turma: curso, professor, horário, vagas máximas, alunos por situação da matrícula, vagas livres e `ocupacao_pct` |
| `bi.vw_turmas_por_professor` | Por professor: turmas (vigentes e abertas), cursos e alunos vigentes (soma por turma) |
| `bi.vw_cursos_comparativo` | Por curso: turmas, alunos vigentes, `pct_turmas`, `pct_alunos`, `diferenca_pp` (positivo = turmas cheias, negativo = turmas vazias), alunos por turma e ranking |
| `bi.vw_alunos_por_situacao` | Por situação da turma e da matrícula: alunos, matrículas e percentual |

"Alunos por situação" usa a situação da **matrícula** (a que o DW guarda). A situação cadastral do aluno no Sponte (`GetSituacoesAlunos`) não é gravada hoje. As views de frequência, calendário e pendências estão descritas em [FREQUENCIA.md](FREQUENCIA.md).

## Frequência

Detalhes e regras em [FREQUENCIA.md](FREQUENCIA.md). Carga própria (`src/carga_frequencia.py`), com controle em `raw.carga_frequencia`, para não interferir na carga de cadastro.

| Camada | Tabela | Conteúdo |
|---|---|---|
| raw | `raw.frequencia_janela` | Uma linha por turma e mês consultados (mesmo vazio) |
| raw | `raw.frequencia`, `raw.diario_aula` | Retorno por aluno e disciplina, e aulas do diário (sem nome de aluno, nome de professor e conteúdo) |
| dw | `dim_disciplina` | Disciplina |
| dw | `fato_frequencia_janela` | Totais da API por turma, mês, disciplina e aluno (só conferência) |
| dw | `fato_aula_dia` | Aulas por turma, disciplina e dia: módulo, total, concluídas e não concluídas |
| dw | `fato_falta_dia` | Horas faltadas por aluno, disciplina e dia |
| dw | `fato_frequencia_dia` | **Presença ou Falta por aluno e dia de aula**; `parcial` marca lançamento a corrigir |
| dw | `calendario_turma_mes` | Aulas previstas x ocorridas por turma e mês, com as datas a mais e a menos |
| dw | `config_frequencia` | Parâmetro `limite_falta_dia` (padrão 1,0) |

Para cada turma e mês vale a consulta mais recente. O `dw.processar_frequencia` recalcula tudo a partir do `raw`, então é repetível.

## Validação

O schema, a migração da versão antiga e a função de processamento foram testados em PostgreSQL 16 com dados fictícios: instalação do zero equivalente ao banco migrado (mesmas colunas, índices, constraints, views e função), carga inicial, segunda carga com entrada, trancamento, desaparecimento e mudança de situação da turma, e reprocessamento sem duplicar eventos. A carga com a API real foi validada pela primeira carga de produção (703 entradas e 253 saídas no histórico inicial).

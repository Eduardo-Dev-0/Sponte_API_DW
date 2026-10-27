# Frequência (Meta 1)

Estado: **em uso: a primeira carga real foi feita em out/2026** (`python src/carga_frequencia.py`).

## Regras de negócio (confirmadas)

- **Presença ou falta por dia de aula, não por hora.** No Sponte cada hora é uma aula (uma noite de 4 horas são 4 aulas). Na escola, o aluno assina a folha de frequência do dia e isso garante todas as horas; quem não assina recebe falta em todas por igual. O que importa é se o aluno veio naquele dia.
- **Só contam as aulas "Concluída".** O fluxo do acadêmico é: a aula acontece, ele marca quem faltou e conclui a aula. Aula que ficou só "Confirmada" não entra na frequência.
- **Falta parcial é erro de lançamento.** Se o aluno tem falta em parte das horas do dia, o dia conta como **Presença** (o aluno veio) e fica marcado `parcial`, para corrigir no Sponte. O parâmetro `dw.config_frequencia.limite_falta_dia` (padrão 1,0: só é Falta quem faltou em todas as horas) permite mudar isso sem refazer a carga: `UPDATE dw.config_frequencia SET limite_falta_dia = 0.5;` e `python src/carga_frequencia.py --so-processar`.
- **Divergências de calendário não são corrigidas automaticamente.** Ficam numa tabela separada, por mês, para a equipe conferir se foi feriado ou erro operacional no Sponte.

## O que a API permite

- `GetFrequenciaTurma`: Turma → Disciplinas → Alunos → Faltas, com totais por aluno. Filtro de data de **até 6 meses por chamada**; sem data, últimos 30 dias.
- `GetDiarioAulas`: aulas de **uma disciplina por chamada**, período de **até 60 dias**. A `Situacao` só vem no retorno: **não existe filtro por situação**, então as aulas `Concluída` são selecionadas no nosso lado.
- O limite de 6 meses é **por chamada**. A carga usa um mês por vez e vai somando, então o histórico não fica limitado.

## O que a sonda confirmou

- A lista de faltas fecha com `TotalFaltas`, e o percentual da API confere com presenças ÷ (presenças + faltas), pois cada aula tem 1 hora.
- **As janelas somam:** dois meses de uma vez = soma dos dois meses separados, em todas as linhas aluno × disciplina.
- O diário bate com a frequência (`NumeroAulas`), e todas as datas de falta existem no diário.
- **Os totais da API só contam aulas "Concluída".** Turma 436, setembro: 28 aulas em `NumeroAulas`, mas 20 horas por aluno nos totais; as 8 que faltam são as "Confirmada". Em nenhuma das 19 turmas, nos 3 meses auditados, houve falta em dia sem aula concluída.
- Dias de falta parcial são raros: 4 em cerca de 2.700 aluno-dias, todos na turma 503 em agosto (o lançamento marcou a falta em 1 hora só; já será corrigido).
- Formatos: datas `dd/mm/aaaa`; horários `18:00`; percentual em texto (`50,00%`, `100%`); duração `1:0`. O horário inicial **se repete** entre as horas do mesmo dia, então as horas de um dia são contadas por linhas do diário, nunca por horário.

## Como funciona a carga

- Turmas Vigente, mais as que tiveram aula nos últimos 45 dias (para fechar o último mês).
- **Histórico completo, da primeira aula concluída até a última.** Cada turma começa um mês antes do início cadastrado (ou da primeira matrícula, o que for mais cedo) e, se o mês mais antigo tiver aula, a carga volta mais um mês, até achar um mês sem aula (limite de jan/2024). `bi.vw_cobertura_frequencia` confirma por turma: `meses_faltando` deve ser 0 e `cobertura_inicio` deve ser `completa`.
- Um mês de calendário por consulta (o mês corrente vai até ontem). Meses fechados são consultados uma vez. São reconsultados a cada carga **os 2 últimos meses** e **qualquer mês, nos últimos 120 dias, com aula não concluída ou dia de falta parcial**, porque o acadêmico conclui aulas e corrige faltas depois. Alteração em mês antigo e sem pendência só entra com `--completa`. O que atualiza e quando: [ATUALIZACAO.md](ATUALIZACAO.md).
- Cada turma-mês é independente: se uma consulta falhar, as outras são gravadas e a que falhou é tentada de novo na próxima carga.
- Só os dias entre o **início e o encerramento da matrícula** do aluno contam para ele, para quem entrou no meio do mês não ganhar presenças dos dias anteriores.
- `--recarregar N`, `--completa`, `--turma ID` e `--so-processar` estão descritos no cabeçalho do script.

## Calendário: aulas previstas x ocorridas

Para cada turma e mês, `dw.calendario_turma_mes` compara:

- **Previstas:** os dias do mês que caem no dia da semana do horário da turma (a partir do início da turma).
- **Ocorridas:** os dias com ao menos uma aula **Concluída**.

| Status | Leitura |
|---|---|
| igual | Tudo como previsto |
| menos | Dia previsto sem aula concluída: feriado, evento, ou aula que ficou só "Confirmada" |
| mais | Aula concluída em dia não previsto: investigar |
| trocado | As duas coisas: aula movida de dia |
| sem dia previsto | Horário com mais de um dia ou não reconhecido (não é avaliado) |

A view `bi.vw_calendario_divergencias` mostra só as divergentes, **ordenadas por mês**, com as colunas: aulas previstas, aulas ocorridas, diferença, **datas a menos** e **datas a mais**, e ainda as datas em que há aula marcada mas não concluída. Se o término cadastrado da turma já passou e ainda há aula, o período previsto vai até a última aula e a turma fica sinalizada em `dias_apos_termino_cadastrado`.

Primeiras conferências (ago e set/2026), já investigadas pela equipe:

| Turma | Mês | Causa |
|---|---|---|
| 421, 622 | Ago | Feriado em 15/08 (menos). A 421 também tinha aula em dia fora do previsto: erro a corrigir |
| 437, 502, 584 | Set | Feriado em 07/09 (menos) |
| 509 | Ago | Aula de 07/08 aconteceu, mas não consta nas aulas do mês: falha na base do Sponte |
| 671 | Ago | Mesmo tipo de falha na base (a auditoria apontou 09/08; a data informada foi 07/08, a confirmar) |
| 649 | Ago | 7 aulas no mês: anomalia a corrigir nos dados |
| 575 | Set | Teve 5 aulas, todas nos dias certos (02, 09, 16, 23 e 30). Estava com 4 previstas porque o término cadastrado era anterior |
| 503 | Ago | Dia com falta lançada em 1 hora só (a corrigir para as 4 horas) |

## Primeira leitura dos dados reais (out/2026)

Resumo de `qualidade_frequencia.sql`: 6 dias parciais; 1.105 horas de aulas passadas não concluídas; 48 turma-mês com calendário divergente; 4 turma-mês com aula depois do término cadastrado; 13 casos em que `TotalFaltas` da API difere das faltas listadas; **0** faltas em dia sem aula concluída.

- **Todas as 48 divergências são "menos".** Nenhuma turma teve aula concluída em dia não previsto. O "a mais" que apareceu na auditoria antiga (turmas 649 e 421) são aulas **marcadas e não concluídas** em dia fora do previsto: a turma 649 tem 5 quartas marcadas em julho e 3 em agosto, sendo turma de quinta. Por isso `vw_calendario_divergencias` também lista os meses com esse alerta.
- **Muitas divergências são coletivas** (todas as turmas do mesmo dia da semana pararam), o que aponta para feriado ou evento: 13/04 (3 turmas de segunda), 07/09 e 12/10 (as mesmas 3 de segunda), 09/08 (as 3 turmas de domingo), 15/08 (as 2 de sábado), 03/04 (2 de sexta), 24/06 (2 de quarta), 02/07 (2 de quinta). `bi.vw_dias_sem_aula` mostra isso por data, com o percentual de turmas que pararam.
- **Casos isolados, para investigar:** a turma 437 teve 1 aula concluída em abril e 1 em maio (3 a menos em cada mês); a 436 ficou sem 2 aulas em dezembro e fevereiro.
- **Aulas marcadas e não concluídas:** em 15 das 48 divergências a data prevista tem aula no diário que ficou sem conclusão (por exemplo, 14 e 17/02, 09/08, 04/10); nas outras 33 não há aula no diário na data. O padrão sugere que aula não realizada costuma ficar "Confirmada" em vez de ser cancelada.
- **Turma 671 em agosto:** a data que falta é 09/08, a mesma das outras duas turmas de domingo (505 e 648). A nota de "aula de 07/08 que não consta" vale para a 509 (sexta).

## Alunos que passaram pela turma

A consulta normal do `GetFrequenciaTurma` só lista quem está na turma **agora** (no Sponte, é como deixar desmarcada a caixa de mostrar os alunos que passaram pela turma). Quem saiu (cancelamento, trancamento, transferência) some dos meses em que ainda estava matriculado, e a frequência do mês fica sem eles.

Correção na carga: para cada turma e mês, os alunos com matrícula naquele mês que **não vieram** na resposta normal são pedidos um a um, com o filtro `AlunoID` (`sParametrosBusca=AlunoID=<id>;Data=...`), e entram na frequência do mês. O limite deles é o período da matrícula: contam do início até a **data de encerramento** da matrícula (a última aula deles na turma).

- O filtro `AlunoID` não é documentado como forma de trazer quem saiu. Antes de confiar, rode `python src/sonda_ex_alunos.py --turma 623 --mes 2026-05`: ela diz se a API devolve a frequência desses alunos (SIM ou NÃO).
- As janelas consultadas antes desta correção são reconsultadas sozinhas, uma vez (a primeira carga fica mais longa). `--sem-ex-alunos` desliga esse passo.
- Conferência: a consulta 11 de `sql/consultas/qualidade_frequencia.sql` compara, por turma e mês, as matrículas com algum dia no mês e os alunos que aparecem na frequência.
- Se a carga avisar que a API não devolveu nenhum aluno que saiu, o filtro `AlunoID` não resolve e é preciso outro caminho.
- Se o aluno parou de vir antes do cancelamento, os dias até a data de encerramento contam como falta dele.

## Para o Power BI

Conectar ao schema `bi` do banco `sponte_dw` (Obter dados > Banco de dados PostgreSQL; o Power BI pode pedir a instalação do provedor Npgsql). As views não trazem nome, CPF nem e-mail de aluno, só o `aluno_id`. Ordene `mes_nome` por `mes_numero`.

| View | Uma linha por | Para quê |
|---|---|---|
| `vw_calendario_frequencia` | turma, disciplina e **dia de aula concluída** | O calendário da frequência: `data_aula`, `ano`, `mes_numero`, `mes_nome`, `ano_mes`, `dia_da_semana`, turma, curso, `modulo`, disciplina, `horas_de_aula`, `alunos`, `presencas`, `faltas`, `pct_frequencia` |
| `vw_frequencia_aluno_dia` | aluno e dia de aula | Todo o registro do aluno, com mês, módulo e disciplinas do dia; `presente` e `falta` valem 1 ou 0 para somar |
| `vw_frequencia_aluno` / `_aluno_mes` | aluno (e mês) | Frequência do aluno em todo o período e por mês |
| `vw_frequencia_turma` / `_turma_mes` | turma (e mês) | Frequência geral da turma e por mês |
| `vw_frequencia_curso` / `_curso_mes` | curso (e mês) | Frequência geral do curso e por mês |
| `vw_cobertura_frequencia` | turma | Primeira e última aula concluída, meses consultados e se o histórico está completo |
| `dim_data` | dia (2025 a 2027) | Tabela de datas com nome do mês em português, trimestre e dia da semana |

As views mensais têm `ano`, `mes_numero`, `mes_nome` e `ano_mes`. O percentual é sempre presenças ÷ (presenças + faltas) sobre as somas. No calendário da frequência, o aluno que faltou em uma disciplina no dia conta como falta nela pela mesma regra do `limite_falta_dia`.

## Pendências para corrigir no Sponte

A frequência usa **somente aulas concluídas**. Tudo o que é divergente fica numa lista separada, `bi.vw_pendencias_sponte`, com o que se precisa para achar a aula no Sponte: **data, turma, módulo e disciplina** (e o `aluno_id` nas faltas parciais). Nada é corrigido automaticamente. Quando a correção é feita no Sponte, a linha some na carga seguinte.

| Tipo | O que é | O que a linha traz |
|---|---|---|
| Aula não concluída | Aula marcada que já passou e não foi concluída | Data, turma, módulo, disciplina, horas, situação no Sponte e se o dia teve outra aula concluída (provável aula paralela que não aconteceu) ou nenhuma (não realizada ou sem conclusão) |
| Dia previsto sem aula no diário | Data prevista pelo horário da turma sem nenhuma aula no diário | Data, turma, e o módulo e as disciplinas que têm aula naquele mês (não há disciplina específica, pois não existe aula) |
| Aula concluída em dia não previsto | Aula concluída fora do dia da semana do horário | Data, turma, módulo, disciplina |
| Falta parcial | Aluno com falta em parte das horas do dia | Data, turma, módulo, disciplina onde a falta foi lançada, `aluno_id`, horas faltadas e horas da aula |
| Término cadastrado vencido | A turma tem aula concluída depois da data de término cadastrada | Turma, término cadastrado e última aula concluída |
| TotalFaltas diferente da lista | O total de faltas da API não bate com as faltas listadas | Turma, módulo, disciplina, mês, `aluno_id` e os dois valores |

Para entregar à equipe numa planilha: `python src/exportar_pendencias.py` (gera `data/pendencias_sponte_AAAAMMDD.csv`, com `--tipo` e `--desde` para filtrar).

Na falta parcial, a linha mostra a disciplina em que a falta foi lançada. Se o dia tiver mais de uma disciplina, vale conferir todas as aulas daquele dia para o aluno.

## Views (schema `bi`)

`vw_frequencia_turma_mes`, `vw_frequencia_aluno_mes`, `vw_frequencia_aluno` (todo o período) e `vw_frequencia_curso_mes`. A lista de correções está em `vw_pendencias_sponte` (seção acima). No calendário: `vw_calendario_turma_mes`, `vw_calendario_divergencias` (só as divergentes, por mês, com `alertas`) e `vw_dias_sem_aula` (datas em que turmas pararam e quantas turmas do mesmo dia da semana pararam junto). O percentual é sempre presenças ÷ (presenças + faltas) sobre as somas, nunca média de percentuais. Nas views de aluno só aparece o `aluno_id`.

## Verificações de qualidade

`sql/consultas/qualidade_frequencia.sql`: dias parciais, aulas passadas não concluídas, calendário divergente, aula após o término cadastrado, faltas da API x faltas listadas, faltas em dia sem aula concluída, e **se a API conta só aulas concluídas** (por turma, mês e disciplina).

## Em aberto

- [x] Primeira carga real e leitura de `bi.vw_calendario_divergencias`
- [ ] Confirmar com `sonda_ex_alunos.py` que a API devolve a frequência de quem saiu da turma pelo `AlunoID`
- [ ] 13 casos em que `TotalFaltas` da API difere das faltas listadas (consulta 9 de `qualidade_frequencia.sql`)
- [ ] 1.105 horas de aulas passadas não concluídas: quanto é aula paralela que não aconteceu e quanto é diário sem fechamento (consultas 7 e 8)
- [ ] Significado exato de "Confirmada" (aula não realizada ou diário sem fechamento) e quantas ficaram assim
- [ ] Disciplina cujas aulas do mês estão todas "Confirmada" pode não aparecer na resposta do `GetFrequenciaTurma` e fazer o mês parecer "menos"

# Quando o Sponte muda, o DW acompanha?

O DW só se atualiza quando as cargas rodam, e o Power BI só mostra o novo quando o relatório é atualizado. Ordem da rotina: `python src\sponte_loader.py` e depois `python src\carga_frequencia.py` (o `scripts\rodar_carga.ps1` faz as duas). A frequência depende do cadastro atualizado (turmas e matrículas).

## Cadastro (`sponte_loader.py`)

| Mudança no Sponte | Atualiza no DW? | Observação |
|---|---|---|
| Dados da turma (nome, sigla, situação, turno, horário, curso, datas, vagas, professor) | **Sim**, a cada carga | Só turmas Vigente e Aberta, mais a última coleta de quem sai do recorte. A mudança de situação (Aberta para Vigente) fica também no histórico diário `snapshot_turma_dia` |
| Situação, datas ou turma de uma matrícula (cancelamento, trancamento, transferência) | **Sim** | O estado atual é sobrescrito e é gerado um evento. Os eventos antigos **não** são reescritos: corrigir uma data no Sponte muda o estado atual, não o evento já registrado |
| Matrícula excluída no Sponte | **Sim** | Fica marcada como `ativa_na_api = false` e sai das contagens atuais |
| Nome do aluno | **Sim** | Vem da matrícula, a cada carga |
| CPF e e-mail do aluno | **Sim, com ressalva** | Atualizados para alunos novos, para os que o Sponte aponta como alterados (`GetAlunosAlterados`) e em todos com `--atualizar-alunos`. Não confirmei que esse método enxerga mudança de CPF ou e-mail, então vale rodar `--atualizar-alunos` de tempos em tempos. CPF ou e-mail **apagado** no Sponte não é apagado no DW: fica o último valor conhecido |
| Aluno ou turma que saiu do recorte | Não | Fica no último estado coletado |

## Frequência (`carga_frequencia.py`)

| Mudança no Sponte | Atualiza no DW? | Observação |
|---|---|---|
| Aula concluída, aula alterada ou falta corrigida **nos 2 últimos meses** | **Sim**, na próxima carga | Os 2 últimos meses são reconsultados sempre |
| O mesmo em **mês antigo com pendência** (aula não concluída ou dia de falta parcial nos últimos 120 dias) | **Sim** | O mês é reconsultado até a pendência sumir |
| O mesmo em **mês antigo sem pendência** (por exemplo, uma falta trocada em um mês já fechado e limpo) | **Só com `--completa`** | `python src\carga_frequencia.py --completa` refaz todo o histórico (de 10 a 20 minutos). Vale rodar uma vez por semana |
| Aula excluída ou cancelada | **Sim**, quando o mês é reconsultado | A aula some do mês |
| Início ou encerramento da matrícula do aluno | **Sim** | O período de cada aluno é recalculado a cada carga de frequência |
| Aluno que saiu da turma (cancelamento, trancamento, transferência) | **Sim**, nos meses em que estava matriculado | A carga pede a frequência dele pelo `AlunoID` até a data de encerramento da matrícula. Depende de a API devolver esse dado (ver `sonda_ex_alunos.py`) |
| Horário ou dia da semana da turma | Parcial | O calendário compara **todos** os meses com o horário atual. Meses anteriores à mudança podem aparecer como divergentes |
| Turma que deixa de ser Vigente | **Sim**, por 45 dias | Continua sendo atualizada por 45 dias depois da última aula |

## Rotina recomendada

- **A cada uso:** `sponte_loader.py` e `carga_frequencia.py` (ou o `rodar_carga.ps1`).
- **Uma vez por semana:** `python src\carga_frequencia.py --completa` e `python src\sponte_loader.py --atualizar-alunos`.
- **No Power BI:** Atualizar o relatório depois das cargas.

# API do Sponte: o que usamos

Serviço SOAP (`WSAPIEdu`), consumido com a biblioteca `zeep`.
WSDL: `https://api.sponteeducacional.net.br/WSAPIEdu.asmx?WSDL`

Fonte: documentação oficial do Sponte (página salva) e o próprio WSDL. Os pontos marcados com **(a confirmar)** ainda não foram testados com a API real.

## Convenções

- Toda chamada recebe `nCodigoCliente` (número da sede) e `sToken`.
- A maioria dos métodos de consulta recebe `sParametrosBusca`: pares `Nome=valor`, separados por `;`. Exemplo: `Situacao=-1;AnoLetivo=2025`.
- Datas **nos filtros**: `aaaa/mm/dd`. Datas **nos retornos**: `dd/mm/aaaa`.
- Todo retorno traz `RetornoOperacao`. Mensagens vistas: `01 - Operação Realizada com Sucesso.` e `21 - Informe pelo menos um parâmetro de busca.`
- **Filtro vazio não funciona** em `GetTurmas`/`GetTurmas2` (código 21). O que funciona: `TurmaID=<id>`, com ou sem `;` no final.

## Métodos em uso

| Método | Filtro usado | Para quê | Observações |
|---|---|---|---|
| `GetModalidadeDasTurmas` | vazio | Lista os `TurmaID` da base | Aceita filtro vazio. Na primeira carga listou 86 turmas |
| `GetTurmas2` | `TurmaID=<id>` | Dados da turma (situação, datas, vagas, horário, professor) | Inclui os campos de `GetTurmas` mais `Assistentes`. `Situacao` vem em texto (vigente, aberta, concluída, mesclada, pré-matrícula, encerrada, turma bloqueada) |
| `GetMatriculas` | `TurmaID=<id>` | Matrículas da turma, inclusive as encerradas | `SituacaoID`: 1 Vigente, 2 Encerrado, 3 Rescindido, 4 Cancelado, 5 Trancado, 6 Pré-Matrícula. `DataEncerramento` é a data em que o contrato foi encerrado, cancelado, rescindido ou trancado. Também filtra por período de `DataMatricula` e `DataEncerramento` |
| `GetIntegrantesTurmas` | `TurmaID=<id>` | Quem está na turma agora | `Modulo` é opcional, com padrão 1. Nos testes, sem informar o módulo, os integrantes bateram com as vagas ocupadas inclusive em turmas nos módulos 0, 2, 3 e 4. Não traz situação nem datas do aluno |

## Métodos previstos

| Método | Para quê | Observações |
|---|---|---|
| `GetAlunos4` | CPF e e-mail do aluno (em uso no loader) | Testado: por `AlunoID` devolve CPF (11 dígitos) e e-mail preenchidos. Filtros: `AlunoID`, `CPF`, `Email`, `Nome` e outros; **não há filtro por turma**, então é uma chamada por aluno. Devolve também RG, endereço, telefones, `LoginPortal` e `SenhaPortal`: **gravar só `AlunoID`, `Nome`, `CPF` e `Email`** |
| `GetAlunosAlterados` | Quais alunos mudaram (em uso no loader) | Parâmetro `QtdDias`: 1, 7, 15 ou 30. Retorna os IDs separados por `;`. Teste de 7 dias: 17 na base toda, 16 no recorte |
| `GetQuadroHorarios` | Dia da semana e horário por aula | Filtro `TurmaID=<id>`. Testado na turma 437: 197 linhas e só 4 combinações distintas, em faixas de 1 hora (Segunda 18:00-19:00, 19:00-20:00, 20:00-21:00, 21:00-22:00). Dá para juntar faixas seguidas em "Segunda 18:00-22:00" |
| `GetHorariosAulas` | Detalhes dos modelos de horário | A confirmar |
| `GetFrequenciaTurma` | Frequência (Meta 1) | O `TurmaID` vai no parâmetro `nTurmaID`; o `sParametrosBusca` aceita `AlunoID`, `DisciplinaID`, `FuncionarioID`, `Modulo` e `Data=aaaa/mm/dd e aaaa/mm/dd` (máximo de 6 meses). Sem data, devolve os últimos 30 dias. Retorno: Turma → Disciplinas → Alunos → Faltas. Ver `FREQUENCIA.md` |
| `GetDiarioAulas` | Aulas do diário (Meta 1) | `nTurmaID`, `nDisciplinaID` (0 para turma sem matriz curricular), `dDataInicio`, `dDataTermino` (máximo de 60 dias, formato `aaaa/mm/dd`), `nModulo` (1 se a turma não for modular) e `sSemana` (opcional). Uma disciplina por chamada. **Não há filtro por situação da aula** (`Situacao` é só retorno): a seleção das aulas `Concluída` é feita no nosso lado |

## Armadilhas já encontradas

- O `Situacao` das turmas na entrada (`-1 Aberta / -2 Encerrada / -3 Pré-Matrícula`) não inclui "Vigente". Por isso o filtro Vigente/Aberta é feito no nosso lado, sobre o texto devolvido.
- Os métodos `Insert*`, `Update*`, `Set*` e `Quitar*` **gravam no Sponte**. O projeto só usa métodos de leitura (`Get*`).
- Há versões numeradas (`GetAlunos` a `GetAlunos4`, `GetTurmas`/`GetTurmas2`). Usamos a mais recente, que traz mais campos.

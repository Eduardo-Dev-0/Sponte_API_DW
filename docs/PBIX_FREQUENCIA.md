# Power BI: frequência (página inicial da sede + 3 páginas)

Fonte: schema `bi` do banco `sponte_dw`. As medidas DAX abaixo ainda não foram testadas no Power BI.

## Modelo de dados

| No Power BI | View | Uma linha por |
|---|---|---|
| Frequência dia | `bi.vw_frequencia_aluno_dia` | aluno, turma e dia de aula (**fato principal**) |
| Turma | `bi.dim_turma` | turma |
| Aluno | `bi.dim_aluno` | aluno (só id e nome) |
| Aluno na turma | `bi.vw_aluno_turma` | aluno e turma |
| Aulas do mês | `bi.vw_calendario_turma_mes` | turma e mês (previstas x ocorridas) |
| Calendário frequência | `bi.vw_calendario_frequencia` | turma, disciplina e dia de aula |
| Movimento | `bi.vw_movimento_matricula_mes` | turma e mês (entradas e saídas) |
| Data | `bi.dim_data` | dia |
| Pendências | `bi.vw_pendencias_sponte` | aula, dia ou aluno a corrigir no Sponte (opcional, para o cartão e a página de qualidade) |

**Relacionamentos** (um para muitos, filtro em uma direção, do primeiro para o segundo):

- `Data[data]` para `Frequência dia[data_aula]`, `Calendário frequência[data_aula]`, `Aulas do mês[mes]` e `Movimento[mes]`
- `Turma[turma_id]` para `Frequência dia`, `Calendário frequência`, `Aulas do mês` e `Movimento` (coluna `turma_id`)
- `Aluno na turma[chave_aluno_turma]` para `Frequência dia[chave_aluno_turma]`
- `Aluno[aluno_id]` para `Aluno na turma[aluno_id]`

Não relacione `Turma` com `Aluno na turma` (cria dois caminhos). Marque `Data` como tabela de datas e ordene `mes_nome` por `mes_numero`. `bi.dim_aluno` traz o **nome** do aluno: se o relatório for compartilhado fora da equipe, deixe essa tabela de fora do modelo.

## Medidas

```dax
Presenças = SUM ( 'Frequência dia'[presente] )
Faltas = SUM ( 'Frequência dia'[falta] )
Registros = [Presenças] + [Faltas]
% Frequência = DIVIDE ( [Presenças], [Registros] )
Alunos = DISTINCTCOUNT ( 'Frequência dia'[aluno_id] )
Alunos com presença = CALCULATE ( DISTINCTCOUNT ( 'Frequência dia'[aluno_id] ), 'Frequência dia'[presente] = 1 )
Alunos sem presença = [Alunos] - [Alunos com presença]
Dias de aula = DISTINCTCOUNT ( 'Frequência dia'[data_aula] )   -- use por turma
% Frequência mês anterior = CALCULATE ( [% Frequência], DATEADD ( 'Data'[data], -1, MONTH ) )
Variação (pp) = ( [% Frequência] - [% Frequência mês anterior] ) * 100
% Frequência do curso = CALCULATE ( [% Frequência], ALLEXCEPT ( 'Turma', 'Turma'[curso] ) )
Entradas = SUM ( Movimento[entradas] )
Saídas = SUM ( Movimento[saidas] )
Turmas = DISTINCTCOUNT ( 'Turma'[turma_id] )
Turmas vigentes = CALCULATE ( DISTINCTCOUNT ( 'Turma'[turma_id] ), 'Turma'[situacao_turma] = "Vigente" )
Turmas abertas = CALCULATE ( DISTINCTCOUNT ( 'Turma'[turma_id] ), 'Turma'[situacao_turma] = "Aberta" )
Cursos = DISTINCTCOUNT ( 'Turma'[curso] )
Alunos matriculados vigentes = SUM ( 'Turma'[alunos_vigentes] )
% Frequência (total) = CALCULATE ( [% Frequência], REMOVEFILTERS ( 'Data' ) )   -- da primeira à última aula
Turmas com histórico completo = CALCULATE ( DISTINCTCOUNT ( 'Turma'[turma_id] ), 'Turma'[cobertura_inicio] = "completa" )
Pendências = COUNTROWS ( 'Pendências' )
Curso com maior % =
    VAR t = ADDCOLUMNS ( VALUES ( 'Turma'[curso] ), "@p", [% Frequência] )
    RETURN MAXX ( TOPN ( 1, t, [@p], DESC ), 'Turma'[curso] )
Curso com menor % =
    VAR t = ADDCOLUMNS ( VALUES ( 'Turma'[curso] ), "@p", [% Frequência] )
    RETURN MAXX ( TOPN ( 1, t, [@p], ASC ), 'Turma'[curso] )
% Frequência da turma (na página do aluno) =
    VAR turmas = VALUES ( 'Aluno na turma'[turma_id] )
    RETURN CALCULATE ( [% Frequência], REMOVEFILTERS ( 'Aluno na turma' ), REMOVEFILTERS ( Aluno ),
                       TREATAS ( turmas, 'Frequência dia'[turma_id] ) )
```

Para destacar alunos em risco, crie um parâmetro (What-if) **Limite de frequência** de 0 a 100, de 5 em 5, com valor inicial **75** (ajuste à regra da escola):

```dax
Alunos abaixo do limite =
    COUNTROWS ( FILTER ( VALUES ( 'Aluno na turma'[chave_aluno_turma] ),
                         [% Frequência] * 100 < 'Limite de frequência'[Limite de frequência Valor] ) )
```

## Página inicial: Frequência geral da sede

Objetivo: visão geral da sede (hoje, Bezerra, o único código de cliente): quantas turmas vigentes e abertas, a frequência de todas as turmas por mês e o total de cada turma, da primeira à última aula. O nome da sede vem de `dw.sede` (ver `docs/SETUP.md`); sem cadastro aparece "(sede sem nome)".

```
+----------------------------------------------------------------------------+
| FREQUÊNCIA GERAL DA SEDE [sede]  [Ano/Mês] [Curso] [Situação] [Turno] [Dia]|
+--------+--------+--------+--------+--------+--------+--------+-------------+
| Turmas | Turmas | Alunos | Cursos | % freq | % freq | Alunos | Pendências  |
| vigent.| abertas| matric.|        | TOTAL  | período| s/ pres|             |
+--------+--------+--------+--------+--------+--------+--------+-------------+
| (1) Colunas + linha: presenças, faltas | (2) Barras: turmas por curso       |
|     e % por mês (todas as turmas)      |     (vigente x aberta)             |
+----------------------------------------+------------------------------------+
| (3) Matriz: turma x mês (%)            | (4) Barras: % TOTAL por turma      |
|     com coluna de total da turma       |     (menores primeiro)             |
+----------------------------------------+------------------------------------+
| (5) Turmas por turno | (6) Turmas por dia da semana | (7) Entradas x saídas  |
+----------------------------------------------------------------------------+
| (8) Tabela: turma | curso | situação | 1ª aula | última aula | dias | % total |
+----------------------------------------------------------------------------+
```

| Visual | Campos |
|---|---|
| Filtros | `Data[ano_mes]`, `Turma[curso]`, `Turma[situacao_turma]`, `Turma[turno]`, `Turma[dia_da_semana]` |
| Título | cartão de texto com `Turma[sede]` |
| Cartões | `[Turmas vigentes]`, `[Turmas abertas]`, `[Alunos matriculados vigentes]`, `[Cursos]`, `[% Frequência (total)]`, `[% Frequência]` (do período filtrado), `[Alunos sem presença]`, `[Pendências]` |
| (1) Colunas + linha | eixo `Data[ano_mes]`, colunas empilhadas `[Presenças]` e `[Faltas]`, linha `[% Frequência]` |
| (2) Barras empilhadas | eixo `Turma[curso]`, valor `[Turmas]`, legenda `Turma[situacao_turma]` |
| (3) Matriz | linhas `Turma[turma]`, colunas `Data[ano_mes]`, valores `[% Frequência]`; o total da linha é a frequência da turma em todo o período filtrado |
| (4) Barras | eixo `Turma[turma]`, valor `[% Frequência (total)]`, ordem crescente |
| (5) e (6) Colunas | `[Turmas]` por `Turma[turno]` e por `Turma[dia_da_semana]` |
| (7) Colunas | eixo `Data[ano_mes]`, `[Entradas]` e `[Saídas]` |
| (8) Tabela | `turma`, `curso`, `situacao_turma`, `primeira_aula_concluida`, `ultima_aula_concluida`, `dias_de_aula_concluidos`, `[Alunos]`, `alunos_vigentes`, `ocupacao_pct`, `[% Frequência (total)]` |
| Navegação | clique na turma leva à página 2; no curso, à página 1 |

`[% Frequência (total)]` ignora o filtro de data: é a frequência da turma desde a primeira aula concluída até a última, mesmo com um mês selecionado. Só entram as turmas que estão no DW (Vigente, Aberta e as que saíram há pouco); turmas Concluída, Mesclada e outras situações da base do Sponte não são carregadas.

## Página 1: Cursos

Objetivo: ver quais cursos têm a maior e a menor frequência, no período total e em cada mês, e quais estão em alta ou perdendo alunos.

```
+----------------------------------------------------------------------------+
| FREQUÊNCIA POR CURSO     [Ano/Mês]  [Curso]  [Situação da turma]           |
+---------+---------+---------+---------+---------+--------------------------+
| %       | Maior % | Menor % | Alunos  | Faltas  | Variação vs mês anterior |
+---------+---------+---------+---------+---------+--------------------------+
| (1) Barras: % por curso       | (3) Linhas: % por mês, uma linha por curso |
|     (período filtrado)        |                                            |
+-------------------------------+--------------------------------------------+
| (2) Matriz: curso x mês       | (4) Barras: variação (pp) vs mês anterior  |
|     (% com escala de cor)     |     por curso                              |
+-------------------------------+--------------------------------------------+
| (5) Colunas: entradas x saídas| (6) Colunas: alunos sem presença no mês    |
|     por mês                   |                                            |
+-------------------------------+--------------------------------------------+
| (7) Tabela: curso | turmas | alunos | presenças | faltas | % | variação     |
+----------------------------------------------------------------------------+
```

| Visual | Campos |
|---|---|
| Filtros | `Data[ano_mes]` (ou ano e mês), `Turma[curso]`, `Turma[situacao_turma]` |
| Cartões | `[% Frequência]`, `[Curso com maior %]`, `[Curso com menor %]`, `[Alunos]`, `[Faltas]`, `[Variação (pp)]` |
| (1) Barras | eixo `Turma[curso]`, valor `[% Frequência]`, ordem decrescente, cor por faixa |
| (2) Matriz | linhas `Turma[curso]`, colunas `Data[ano_mes]`, valores `[% Frequência]`, escala de cor |
| (3) Linhas | eixo `Data[ano_mes]`, valor `[% Frequência]`, legenda `Turma[curso]` |
| (4) Barras | eixo `Turma[curso]`, valor `[Variação (pp)]` (selecione o mês) |
| (5) Colunas | eixo `Data[ano_mes]`, valores `[Entradas]` e `[Saídas]` (filtra por curso) |
| (6) Colunas | eixo `Data[ano_mes]`, valor `[Alunos sem presença]` |
| (7) Tabela | curso, turmas, `[Alunos]`, `[Presenças]`, `[Faltas]`, `[% Frequência]`, `[Variação (pp)]`, `[Alunos sem presença]` |
| Navegação | clique no curso filtra a página; botão "Ver turmas do curso" leva à página 2 |

## Página 2: Turmas

Objetivo: ver a frequência da turma a cada mês, desde o início, e o total da primeira à última aula concluída.

```
+----------------------------------------------------------------------------+
| FREQUÊNCIA DA TURMA     [Curso]  [Turma]  [Situação]  [Módulo]  [Mês]      |
+---------+---------+---------+---------+---------+--------------------------+
| % total | Alunos  | Dias de | Presen- | Faltas  | 1ª aula | Última | Cobert.|
|         |         | aula    | ças     |         |         | aula   |        |
+---------+---------+---------+---------+---------+--------------------------+
| (1) Colunas + linha: % por mês    | (2) Colunas: aulas previstas x         |
|     (linha = média do curso)      |     ocorridas por mês                  |
+-----------------------------------+----------------------------------------+
| (3) Barras: % por disciplina      | (5) Barras: alunos da turma por %      |
|     (e por módulo)                |     (menores primeiro)                 |
+-----------------------------------+----------------------------------------+
| (4) Tabela: calendário da frequência (dia a dia)                           |
+----------------------------------------------------------------------------+
| (6) Matriz: aluno x data com presença/falta (opcional)                     |
+----------------------------------------------------------------------------+
```

| Visual | Campos |
|---|---|
| Filtros | `Turma[curso]`, `Turma[turma]`, `Turma[situacao_turma]`, `Calendário frequência[modulo]`, `Data[ano_mes]` |
| Cartões | `[% Frequência]`, `[Alunos]`, `[Dias de aula]`, `[Presenças]`, `[Faltas]`, `Turma[primeira_aula_concluida]`, `Turma[ultima_aula_concluida]`, `Turma[cobertura_inicio]` |
| (1) Colunas + linha | eixo `Data[ano_mes]`, colunas `[% Frequência]`, linha `[% Frequência do curso]` |
| (2) Colunas | eixo `Data[ano_mes]`, valores `Aulas do mês[aulas_previstas]` e `Aulas do mês[aulas_ocorridas]`, tooltip com `datas_a_menos` e `datas_a_mais` |
| (3) Barras | eixo `Calendário frequência[disciplina]`, valor `AVERAGE ( Calendário frequência[pct_frequencia] )` (ou ponderado pelo número de alunos) |
| (4) Tabela | `data_aula`, `mes_nome`, `dia_da_semana`, `modulo`, `disciplina`, `horas_de_aula`, `alunos`, `presencas`, `faltas`, `pct_frequencia`, com cor condicional |
| (5) Barras | eixo `Aluno[nome]`, valor `[% Frequência]`, ordem crescente, "Principais N" |
| (6) Matriz | linhas `Aluno[nome]`, colunas `Data[data]`, valor `SELECTEDVALUE ( 'Frequência dia'[status] )` com cor por texto |
| Navegação | clique no aluno leva à página 3 (drill-through) |

Sem nenhuma turma selecionada, mostre uma tabela de turmas no lugar dos gráficos (turma, curso, `[Alunos]`, `[% Frequência]`, primeira e última aula).

## Página 3: Alunos

Objetivo: ver a frequência do aluno na turma desde o primeiro dia, saber se ele entrou no início ou depois, e acompanhar mês a mês.

```
+----------------------------------------------------------------------------+
| FREQUÊNCIA DO ALUNO   [Curso] [Turma] [Aluno (busca)] [Matrícula] [Entrada]|
+--------+--------+---------+---------+--------+--------+--------+-----------+
| Turma  | Curso  | Matríc. | 1º dia  | Entrou | Presen-| Faltas | % geral   |
|        |        | situação|         | quando | ças    |        | na turma  |
+--------+--------+---------+---------+--------+--------+--------+-----------+
| (1) Colunas + linha: % do aluno por mês (linha = % da turma no mês)         |
+--------------------------------------+-------------------------------------+
| (2) Linha do tempo: dia a dia        | (3) Rosca: presenças x faltas       |
|     (presença / falta por data)      |     + última presença, faltas seguidas |
+--------------------------------------+-------------------------------------+
| (4) Tabela de alunos (sem aluno selecionado): ordenada por % crescente      |
+----------------------------------------------------------------------------+
```

| Visual | Campos |
|---|---|
| Filtros | `Aluno na turma[curso]`, `Aluno na turma[turma]`, `Aluno[nome]`, `Aluno na turma[situacao_matricula]`, `Aluno na turma[entrada]` |
| Cartões | `Aluno na turma[turma]`, `[curso]`, `[situacao_matricula]`, `[primeiro_dia]`, `[entrada]` e `[dias_apos_o_inicio]`, `[presencas]`, `[faltas]`, `[pct_frequencia]` (geral na turma), `[% Frequência da turma]`, `[ultima_presenca]`, `[faltas_seguidas_atuais]` |
| (1) Colunas + linha | eixo `Data[ano_mes]`, colunas `[% Frequência]` (aluno), linha `[% Frequência da turma]` |
| (2) Linha do tempo | matriz com `Data[data]` e `status`, cor por texto (Presença, Falta) |
| (3) Rosca | `[Presenças]` e `[Faltas]` |
| (4) Tabela | aluno, turma, `primeiro_dia`, `entrada`, `presencas`, `faltas`, `pct_frequencia`, `ultima_presenca`, `faltas_seguidas_atuais`, com barras de dados no `%` |

`entrada` vale "Desde o início" (o primeiro dia do aluno é a primeira aula da turma) ou "Entrou após o início"; `dias_apos_o_inicio` diz quantos dias depois. O percentual do aluno só conta os dias a partir da entrada dele.

## Extras sugeridos (já estão no layout acima)

- **Variação em pontos percentuais** contra o mês anterior, por curso: mostra quem está em alta ou em queda.
- **Entradas x saídas por mês** (`Movimento`): complementa a frequência para "perdendo alunos".
- **Alunos sem presença no mês:** alunos que só tiveram falta. Sinal de evasão silenciosa, antes do cancelamento.
- **Faltas seguidas atuais** e **última presença** na página do aluno.
- **Aulas previstas x ocorridas** na página da turma, ligando a frequência ao calendário.
- Uma **página 4 de qualidade**, para a equipe operacional, com `bi.vw_pendencias_sponte` e `bi.vw_calendario_divergencias`.

# Roadmap e metas

Legenda: `[x]` feito · `[ ]` a fazer · `[~]` pronto, falta aplicar ou validar.

## Fase 1: núcleo do DW (em andamento)

**Feito**
- [x] Acesso à API do Sponte (WSDL, token, filtro `TurmaID=`)
- [x] Recorte Vigente/Aberta (30 turmas na primeira carga real)
- [x] Camadas `raw` → `stg` → `dw` e função de processamento
- [x] Primeira carga real: 703 matrículas, 463 integrantes, histórico de entradas e saídas com as datas do Sponte
- [x] Estrutura do projeto, README e guia de instalação em outro PC
- [x] Schema de instalação do zero, testado em PostgreSQL 16 com dados fictícios (carga inicial, mudanças, saída, desaparecimento e reprocessamento)

**Pronto, falta aplicar/validar no seu banco**
- [~] CPF e e-mail em `dim_aluno` (loader consulta alunos novos e alterados; testado com API simulada. Na primeira carga real serão cerca de 680 chamadas, alguns minutos)
- [~] Simplificação de `dim_turma` (sem versões) e novas colunas: `sql/migrations/002_...` (ou `01_schema.sql` em banco novo)
- [~] Segunda carga e reprocessamento sem duplicar eventos (`-SoProcessar`)

**A fazer**
- [x] Horário da turma: o campo `Horario` do Sponte ("Segunda-feira- 18h às 22h") é convertido para "Segunda 18:00 às 22:00" (migração 003)
- [~] Transferência de aluno entre turmas: confirmada nos dados (um contrato passou da 509 para a 507 entre duas cargas). Evento `mudanca_turma` e reconstrução do histórico na migração 003
- [x] Parâmetro `Modulo` do `GetIntegrantesTurmas`: as turmas estão em módulos 0 a 4 e os integrantes (sem informar módulo) batem com as vagas ocupadas em todas, inclusive nas de módulo 0; o padrão não restringe quem aparece
- [ ] Entender a regra que faz os integrantes superarem as matrículas Vigente em algumas turmas (8 de 30 na primeira carga). Parte disso são reativações (Encerrado voltando a Vigente) e cancelamentos recentes; a consulta 8 de `qualidade_dados.sql` mostra o que sobrou
- [ ] Qualidade de dados: rodar `sql/consultas/qualidade_dados.sql` e levar a lista de cadastros a corrigir à equipe do Sponte (boas práticas de preenchimento)
- [~] Agendar a carga diária: `scripts/agendar_carga.ps1` pronto; falta executá-lo no PC que roda a carga e acompanhar as primeiras execuções
- [ ] Rodar por alguns dias para validar as detecções de mudança com movimento real

## Meta 1: análise de frequência (implementada, aguardando a primeira carga real)

Plano, regras e resultados da sonda: [FREQUENCIA.md](FREQUENCIA.md).

- [x] Sonda e auditoria de calendário (19 turmas, 3 meses)
- [x] Regra de negócio: presença ou falta por dia de aula, só aulas concluídas
- [x] Tabelas, carga por turma e mês, e views por turma, aluno e curso (`bi.vw_frequencia_*`)
- [x] Tabela de divergências de calendário por mês (`bi.vw_calendario_divergencias`), sem correção automática
- [x] Primeira execução real feita: 48 turma-mês com aula a menos, 6 dias parciais, 1.105 horas de aulas passadas não concluídas
- [x] Lista de pendências para corrigir no Sponte (`bi.vw_pendencias_sponte`) e exportação em CSV
- [x] Histórico completo por turma (da primeira à última aula concluída), calendário da frequência com nome do mês, frequência geral e por mês
- [~] Relatório no Power BI: layout e medidas da página inicial da sede e de 3 páginas (cursos, turmas, alunos) em `docs/PBIX_FREQUENCIA.md`; falta montar o .pbix
- [ ] Investigar: turma 437 (abr e mai), aulas marcadas e não concluídas, 13 diferenças de `TotalFaltas`
- [ ] Análises: frequência antes das saídas (cruzar com `fato_matricula_evento`), alunos com faltas seguidas, comparação entre cursos

## Meta 2: um sistema só para os acessos dos alunos

**Hoje:** duas ferramentas separadas, ambas alimentadas por planilha extraída do Sponte.
- Ferramenta Python que cria os acessos no Active Directory.
- Ferramenta HTML que cria o aluno e a matrícula no portal Moodle via API do Moodle.

**Objetivo:** o DW como fonte única, e um fluxo só no lugar de duas planilhas.

Passos previstos:
1. **Mapear** quais colunas cada ferramenta consome da planilha e quais campos do DW as substituem (nome, e-mail, CPF, turma, curso; ver `dim_aluno` e `dim_turma`).
2. **Criar uma view de "alunos a provisionar"** no DW: matrículas Vigente em turmas do recorte, com os campos que as ferramentas precisam.
3. **Trocar a planilha pela view**: as ferramentas passam a ler do DW (a princípio por arquivo exportado, depois por leitura direta).
4. **Registrar o resultado no DW** (tabelas de controle: conta criada no AD e no Moodle, data, erro), para saber quem já foi provisionado.
5. **Unificar**: uma única rotina e interface, com fila, log e reprocessamento. Os eventos de saída do DW podem sinalizar contas a suspender; a decisão fica para quando chegarmos lá.

A pasta `tools/` já existe para receber esse trabalho.

## Backlog e decisões em aberto

- [ ] **Governança e LGPD:** perfis de acesso no PostgreSQL (CPF é o campo mais sensível), retenção do `raw`, rotação do token, backup.
- [~] **Consumo dos dados:** views do schema `bi` prontas (alunos por turma, turmas por professor, cursos, situação). Falta definir a ferramenta de visualização
- [ ] **Mais sedes:** existem 3 sedes; por enquanto só a Bezerra. O modelo já suporta várias, falta uma lista de sedes (código + token) no loader.
- [ ] **Pré-matrícula:** fora do recorte por decisão (dados sujos que outra equipe vai limpar no Sponte). Revisar depois da limpeza.
- [ ] **Cargas incrementais:** `GetMatriculas` aceita filtro por período de `DataMatricula` e `DataEncerramento`; usar se a carga completa ficar lenta.
- [ ] **Fora do escopo por ora:** notas, financeiro.

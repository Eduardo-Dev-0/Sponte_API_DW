-- =====================================================================
-- Camada de consumo (schema bi): views prontas para relatório / BI.
-- Rode DEPOIS do 01_schema.sql (ou das migrações). Pode ser rodado de novo
-- a qualquer momento: ele recria as views (não mexe em nenhum dado).
--
-- Regras comuns:
--  * Só entram turmas Vigente e Aberta (turmas que saíram do recorte ficam fora).
--  * Só entram matrículas ainda presentes na API (ativa_na_api = true).
--  * "Alunos" = alunos distintos por turma; nada aqui expõe nome, CPF ou e-mail.
--    Dá para liberar acesso só ao schema bi, sem liberar raw, stg e dw.
-- =====================================================================

CREATE SCHEMA IF NOT EXISTS bi;

DROP VIEW IF EXISTS bi.vw_alunos_por_situacao;
DROP VIEW IF EXISTS bi.vw_cursos_comparativo;
DROP VIEW IF EXISTS bi.vw_turmas_por_professor;
DROP VIEW IF EXISTS bi.vw_alunos_por_turma;
DROP VIEW IF EXISTS bi.vw_aluno_turma;
DROP VIEW IF EXISTS bi.dim_turma;
DROP VIEW IF EXISTS bi.dim_sede;
DROP VIEW IF EXISTS bi.dim_aluno;
DROP VIEW IF EXISTS bi.vw_movimento_matricula_mes;
DROP VIEW IF EXISTS bi.vw_pendencias_sponte;
DROP VIEW IF EXISTS bi.vw_cobertura_frequencia;
DROP VIEW IF EXISTS bi.vw_calendario_frequencia;
DROP VIEW IF EXISTS bi.vw_frequencia_aluno_dia;
DROP VIEW IF EXISTS bi.vw_frequencia_curso;
DROP VIEW IF EXISTS bi.vw_frequencia_turma;
DROP VIEW IF EXISTS bi.dim_data;
DROP VIEW IF EXISTS bi.vw_dias_sem_aula;
DROP VIEW IF EXISTS bi.vw_calendario_divergencias;
DROP VIEW IF EXISTS bi.vw_calendario_turma_mes;
DROP VIEW IF EXISTS bi.vw_frequencia_curso_mes;
DROP VIEW IF EXISTS bi.vw_frequencia_aluno;
DROP VIEW IF EXISTS bi.vw_frequencia_aluno_mes;
DROP VIEW IF EXISTS bi.vw_frequencia_turma_mes;

-- Nome do mês em português (não depende do idioma do servidor)
CREATE OR REPLACE FUNCTION bi.mes_nome(d date) RETURNS text LANGUAGE sql IMMUTABLE AS $$
    SELECT (ARRAY['janeiro','fevereiro','março','abril','maio','junho','julho','agosto','setembro',
                  'outubro','novembro','dezembro'])[extract(month FROM d)::int]
$$;

-- Lista de datas em texto (DD/MM/AAAA, separadas por vírgula), para leitura em relatório
CREATE OR REPLACE FUNCTION bi.datas_txt(d date[]) RETURNS text LANGUAGE sql IMMUTABLE AS $$
    SELECT string_agg(to_char(x, 'DD/MM/YYYY'), ', ' ORDER BY x) FROM unnest(d) x
$$;

-- 1) Alunos por turma: uma linha por turma, com a situação das matrículas e a ocupação
CREATE VIEW bi.vw_alunos_por_turma AS
SELECT
    t.cod_cliente,
    t.turma_id,
    t.nome                AS turma,
    t.sigla,
    t.curso,
    t.situacao            AS situacao_turma,
    t.turno,
    t.horario,
    t.professor_regente   AS professor,
    t.data_inicio,
    t.data_termino,
    t.max_alunos,
    count(DISTINCT f.aluno_id) FILTER (WHERE f.situacao = 'Vigente')    AS alunos_vigentes,
    count(DISTINCT f.aluno_id) FILTER (WHERE f.situacao = 'Trancado')   AS alunos_trancados,
    count(DISTINCT f.aluno_id) FILTER (WHERE f.situacao = 'Cancelado')  AS alunos_cancelados,
    count(DISTINCT f.aluno_id) FILTER (WHERE f.situacao = 'Rescindido') AS alunos_rescindidos,
    count(DISTINCT f.aluno_id) FILTER (WHERE f.situacao = 'Encerrado')  AS alunos_encerrados,
    count(f.contrato_id)                                                AS total_matriculas,
    t.max_alunos - count(DISTINCT f.aluno_id) FILTER (WHERE f.situacao = 'Vigente') AS vagas_livres,
    round(100.0 * count(DISTINCT f.aluno_id) FILTER (WHERE f.situacao = 'Vigente')
          / NULLIF(t.max_alunos, 0), 1)                                 AS ocupacao_pct
FROM dw.dim_turma t
LEFT JOIN dw.fato_matricula f
       ON f.cod_cliente = t.cod_cliente AND f.turma_id = t.turma_id AND f.ativa_na_api
WHERE lower(t.situacao) IN ('vigente', 'aberta')
GROUP BY t.cod_cliente, t.turma_id;

-- 2) Turmas por professor (regente): quantas turmas, quantos cursos e quantos alunos
--    alunos_vigentes é a soma por turma (um aluno em duas turmas do mesmo professor conta duas vezes)
CREATE VIEW bi.vw_turmas_por_professor AS
SELECT
    v.cod_cliente,
    COALESCE(NULLIF(btrim(v.professor), ''), '(sem professor)')    AS professor,
    count(*)                                                       AS turmas,
    count(*) FILTER (WHERE lower(v.situacao_turma) = 'vigente')    AS turmas_vigentes,
    count(*) FILTER (WHERE lower(v.situacao_turma) = 'aberta')     AS turmas_abertas,
    count(DISTINCT v.curso)                                        AS cursos,
    COALESCE(sum(v.alunos_vigentes), 0)                            AS alunos_vigentes
FROM bi.vw_alunos_por_turma v
GROUP BY v.cod_cliente, COALESCE(NULLIF(btrim(v.professor), ''), '(sem professor)');

-- 3) Cursos: quem tem mais turmas e quem tem mais alunos, em quantidade e em proporção.
--    pct_turmas e pct_alunos somam 100% cada. diferenca_pp = pct_alunos - pct_turmas:
--    positivo = o curso concentra mais alunos do que turmas (turmas cheias);
--    negativo = tem muitas turmas para poucos alunos (turmas vazias).
CREATE VIEW bi.vw_cursos_comparativo AS
WITH c AS (
    SELECT cod_cliente,
           COALESCE(curso, '(sem curso)')                              AS curso,
           count(*)                                                    AS turmas,
           count(*) FILTER (WHERE lower(situacao_turma) = 'vigente')   AS turmas_vigentes,
           count(*) FILTER (WHERE lower(situacao_turma) = 'aberta')    AS turmas_abertas,
           COALESCE(sum(alunos_vigentes), 0)                           AS alunos_vigentes
    FROM bi.vw_alunos_por_turma
    GROUP BY cod_cliente, COALESCE(curso, '(sem curso)')
)
SELECT c.*,
       round(100.0 * c.turmas / NULLIF(sum(c.turmas) OVER (PARTITION BY c.cod_cliente), 0), 1)           AS pct_turmas,
       round(100.0 * c.alunos_vigentes / NULLIF(sum(c.alunos_vigentes) OVER (PARTITION BY c.cod_cliente), 0), 1) AS pct_alunos,
       round(100.0 * c.alunos_vigentes / NULLIF(sum(c.alunos_vigentes) OVER (PARTITION BY c.cod_cliente), 0)
           - 100.0 * c.turmas / NULLIF(sum(c.turmas) OVER (PARTITION BY c.cod_cliente), 0), 1)           AS diferenca_pp,
       round(c.alunos_vigentes::numeric / NULLIF(c.turmas, 0), 1)                                         AS alunos_por_turma,
       rank() OVER (PARTITION BY c.cod_cliente ORDER BY c.turmas DESC)                                    AS rank_turmas,
       rank() OVER (PARTITION BY c.cod_cliente ORDER BY c.alunos_vigentes DESC)                           AS rank_alunos
FROM c;

-- 4) Alunos por situação da matrícula (Vigente, Trancado, Cancelado, Rescindido, Encerrado),
--    separado por situação da turma (Vigente / Aberta). O pct é calculado sobre as matrículas
--    de cada situação de turma. Não some "alunos" entre linhas: um aluno pode estar em mais de uma.
CREATE VIEW bi.vw_alunos_por_situacao AS
SELECT
    t.cod_cliente,
    t.situacao                      AS situacao_turma,
    f.situacao                      AS situacao_matricula,
    count(DISTINCT f.aluno_id)      AS alunos,
    count(*)                        AS matriculas,
    round(100.0 * count(*) / NULLIF(sum(count(*)) OVER (PARTITION BY t.cod_cliente, t.situacao), 0), 1)
                                    AS pct_na_situacao_da_turma
FROM dw.fato_matricula f
JOIN dw.dim_turma t ON t.cod_cliente = f.cod_cliente AND t.turma_id = f.turma_id
WHERE lower(t.situacao) IN ('vigente', 'aberta') AND f.ativa_na_api
GROUP BY t.cod_cliente, t.situacao, f.situacao;

-- ---------------------------------------------------------------------
-- FREQUÊNCIA (precisa da carga de frequência: python src/carga_frequencia.py)
-- Só contam aulas "Concluída". Presença ou falta por aluno e DIA de aula.
-- pct_frequencia = presenças / (presenças + faltas), calculado sobre as somas (nunca média de percentuais).
-- Nas views de aluno só aparece o aluno_id: para o nome, junte com dw.dim_aluno (acesso restrito).
-- ---------------------------------------------------------------------

-- Colunas de calendário nas views mensais, para o Power BI: ano, mes_numero (ordenação), mes_nome e ano_mes.
-- Dica: no Power BI, ordene mes_nome por mes_numero.

-- 5) Frequência por turma e mês
CREATE VIEW bi.vw_frequencia_turma_mes AS
SELECT x.cod_cliente, x.curso, x.turma_id, x.turma, x.mes,
       extract(year FROM x.mes)::int AS ano, extract(month FROM x.mes)::int AS mes_numero,
       bi.mes_nome(x.mes) AS mes_nome, to_char(x.mes, 'YYYY-MM') AS ano_mes,
       x.dias_de_aula, x.alunos, x.presencas, x.faltas, x.parciais, x.pct_frequencia
FROM (SELECT f.cod_cliente, t.curso, f.turma_id, t.nome AS turma, date_trunc('month', f.data_aula)::date AS mes,
             count(DISTINCT f.data_aula) AS dias_de_aula, count(DISTINCT f.aluno_id) AS alunos,
             count(*) FILTER (WHERE f.status = 'Presença') AS presencas,
             count(*) FILTER (WHERE f.status = 'Falta')    AS faltas,
             count(*) FILTER (WHERE f.parcial)             AS parciais,
             round(100.0 * count(*) FILTER (WHERE f.status = 'Presença') / NULLIF(count(*), 0), 1) AS pct_frequencia
        FROM dw.fato_frequencia_dia f
        LEFT JOIN dw.dim_turma t ON t.cod_cliente = f.cod_cliente AND t.turma_id = f.turma_id
       GROUP BY f.cod_cliente, t.curso, f.turma_id, t.nome, date_trunc('month', f.data_aula)::date) x;

-- 5b) Frequência geral da turma (todo o período, da primeira à última aula concluída)
CREATE VIEW bi.vw_frequencia_turma AS
SELECT f.cod_cliente, t.curso, f.turma_id, t.nome AS turma,
       count(DISTINCT f.data_aula) AS dias_de_aula, count(DISTINCT f.aluno_id) AS alunos,
       count(*) FILTER (WHERE f.status = 'Presença') AS presencas,
       count(*) FILTER (WHERE f.status = 'Falta')    AS faltas,
       count(*) FILTER (WHERE f.parcial)             AS parciais,
       round(100.0 * count(*) FILTER (WHERE f.status = 'Presença') / NULLIF(count(*), 0), 1) AS pct_frequencia,
       min(f.data_aula) AS primeira_aula, max(f.data_aula) AS ultima_aula
FROM dw.fato_frequencia_dia f
LEFT JOIN dw.dim_turma t ON t.cod_cliente = f.cod_cliente AND t.turma_id = f.turma_id
GROUP BY f.cod_cliente, t.curso, f.turma_id, t.nome;

-- 6) Frequência por aluno e mês (dentro de cada turma)
CREATE VIEW bi.vw_frequencia_aluno_mes AS
SELECT x.cod_cliente, x.curso, x.turma_id, x.turma, x.aluno_id, x.mes,
       extract(year FROM x.mes)::int AS ano, extract(month FROM x.mes)::int AS mes_numero,
       bi.mes_nome(x.mes) AS mes_nome, to_char(x.mes, 'YYYY-MM') AS ano_mes,
       x.dias_de_aula, x.presencas, x.faltas, x.parciais, x.pct_frequencia
FROM (SELECT f.cod_cliente, t.curso, f.turma_id, t.nome AS turma, f.aluno_id, date_trunc('month', f.data_aula)::date AS mes,
             count(*) AS dias_de_aula,
             count(*) FILTER (WHERE f.status = 'Presença') AS presencas,
             count(*) FILTER (WHERE f.status = 'Falta')    AS faltas,
             count(*) FILTER (WHERE f.parcial)             AS parciais,
             round(100.0 * count(*) FILTER (WHERE f.status = 'Presença') / NULLIF(count(*), 0), 1) AS pct_frequencia
        FROM dw.fato_frequencia_dia f
        LEFT JOIN dw.dim_turma t ON t.cod_cliente = f.cod_cliente AND t.turma_id = f.turma_id
       GROUP BY f.cod_cliente, t.curso, f.turma_id, t.nome, f.aluno_id, date_trunc('month', f.data_aula)::date) x;

-- 7) Frequência por aluno em todo o período (dentro de cada turma)
CREATE VIEW bi.vw_frequencia_aluno AS
SELECT f.cod_cliente, t.curso, f.turma_id, t.nome AS turma, f.aluno_id,
       count(*) AS dias_de_aula,
       count(*) FILTER (WHERE f.status = 'Presença') AS presencas,
       count(*) FILTER (WHERE f.status = 'Falta')    AS faltas,
       count(*) FILTER (WHERE f.parcial)             AS parciais,
       round(100.0 * count(*) FILTER (WHERE f.status = 'Presença') / NULLIF(count(*), 0), 1) AS pct_frequencia,
       min(f.data_aula) AS primeiro_dia, max(f.data_aula) AS ultimo_dia
FROM dw.fato_frequencia_dia f
LEFT JOIN dw.dim_turma t ON t.cod_cliente = f.cod_cliente AND t.turma_id = f.turma_id
GROUP BY f.cod_cliente, t.curso, f.turma_id, t.nome, f.aluno_id;

-- 7b) Frequência do aluno dia a dia (todo o registro), com mês, módulo e disciplinas do dia.
--     presente e falta valem 1 ou 0, para somar no Power BI.
CREATE VIEW bi.vw_frequencia_aluno_dia AS
SELECT f.cod_cliente, f.data_aula,
       extract(year FROM f.data_aula)::int AS ano, extract(month FROM f.data_aula)::int AS mes_numero,
       bi.mes_nome(f.data_aula) AS mes_nome, to_char(f.data_aula, 'YYYY-MM') AS ano_mes,
       date_trunc('month', f.data_aula)::date AS mes,
       (ARRAY['Segunda','Terça','Quarta','Quinta','Sexta','Sábado','Domingo'])[extract(isodow FROM f.data_aula)::int] AS dia_da_semana,
       f.turma_id, t.nome AS turma, t.curso, f.aluno_id,
       f.turma_id::text || '-' || f.aluno_id::text AS chave_aluno_turma,
       m.modulos, m.disciplinas,
       f.aulas_dia AS horas_de_aula, f.horas_faltadas, f.status, f.parcial,
       (f.status = 'Presença')::int AS presente, (f.status = 'Falta')::int AS falta
FROM dw.fato_frequencia_dia f
LEFT JOIN dw.dim_turma t ON t.cod_cliente = f.cod_cliente AND t.turma_id = f.turma_id
LEFT JOIN (SELECT a.cod_cliente, a.turma_id, a.data_aula,
                  string_agg(DISTINCT a.modulo::text, ', ') AS modulos,
                  string_agg(DISTINCT dd.nome, ', ')        AS disciplinas
             FROM dw.fato_aula_dia a
             LEFT JOIN dw.dim_disciplina dd ON dd.cod_cliente = a.cod_cliente AND dd.disciplina_id = a.disciplina_id
            WHERE a.aulas_concluidas > 0
            GROUP BY a.cod_cliente, a.turma_id, a.data_aula) m
  ON m.cod_cliente = f.cod_cliente AND m.turma_id = f.turma_id AND m.data_aula = f.data_aula;

-- 8) Frequência por curso e mês
CREATE VIEW bi.vw_frequencia_curso_mes AS
SELECT x.cod_cliente, x.curso, x.mes,
       extract(year FROM x.mes)::int AS ano, extract(month FROM x.mes)::int AS mes_numero,
       bi.mes_nome(x.mes) AS mes_nome, to_char(x.mes, 'YYYY-MM') AS ano_mes,
       x.turmas, x.alunos, x.presencas, x.faltas, x.parciais, x.pct_frequencia
FROM (SELECT f.cod_cliente, COALESCE(t.curso, '(sem curso)') AS curso, date_trunc('month', f.data_aula)::date AS mes,
             count(DISTINCT f.turma_id) AS turmas, count(DISTINCT f.aluno_id) AS alunos,
             count(*) FILTER (WHERE f.status = 'Presença') AS presencas,
             count(*) FILTER (WHERE f.status = 'Falta')    AS faltas,
             count(*) FILTER (WHERE f.parcial)             AS parciais,
             round(100.0 * count(*) FILTER (WHERE f.status = 'Presença') / NULLIF(count(*), 0), 1) AS pct_frequencia
        FROM dw.fato_frequencia_dia f
        LEFT JOIN dw.dim_turma t ON t.cod_cliente = f.cod_cliente AND t.turma_id = f.turma_id
       GROUP BY f.cod_cliente, COALESCE(t.curso, '(sem curso)'), date_trunc('month', f.data_aula)::date) x;

-- 8b) Frequência geral do curso (todo o período)
CREATE VIEW bi.vw_frequencia_curso AS
SELECT f.cod_cliente, COALESCE(t.curso, '(sem curso)') AS curso,
       count(DISTINCT f.turma_id) AS turmas, count(DISTINCT f.aluno_id) AS alunos,
       count(*) FILTER (WHERE f.status = 'Presença') AS presencas,
       count(*) FILTER (WHERE f.status = 'Falta')    AS faltas,
       count(*) FILTER (WHERE f.parcial)             AS parciais,
       round(100.0 * count(*) FILTER (WHERE f.status = 'Presença') / NULLIF(count(*), 0), 1) AS pct_frequencia,
       min(f.data_aula) AS primeira_aula, max(f.data_aula) AS ultima_aula
FROM dw.fato_frequencia_dia f
LEFT JOIN dw.dim_turma t ON t.cod_cliente = f.cod_cliente AND t.turma_id = f.turma_id
GROUP BY f.cod_cliente, COALESCE(t.curso, '(sem curso)');

-- 8c) CALENDÁRIO DA FREQUÊNCIA: uma linha por turma, disciplina e dia de aula concluída (todo o registro),
--     com mês, nome do mês, módulo e disciplina, e a presença do dia nessa disciplina.
--     faltas = alunos que faltaram na disciplina nesse dia (pela mesma regra do limite de falta).
CREATE VIEW bi.vw_calendario_frequencia AS
WITH cfg AS (SELECT COALESCE((SELECT limite_falta_dia FROM dw.config_frequencia WHERE id = 1), 1.0) AS lim),
mb AS (
    SELECT cod_cliente, turma_id, aluno_id, min(data_inicio) AS ini,
           CASE WHEN bool_or(data_encerramento IS NULL) THEN NULL ELSE max(data_encerramento) END AS fim
      FROM dw.fato_matricula GROUP BY cod_cliente, turma_id, aluno_id
), elig AS (
    SELECT a.cod_cliente, a.turma_id, a.disciplina_id, a.data_aula, j.aluno_id,
           a.aulas_concluidas AS horas_aula, COALESCE(f.horas_faltadas, 0) AS horas_faltadas
      FROM dw.fato_aula_dia a
      JOIN dw.fato_frequencia_janela j
        ON j.cod_cliente = a.cod_cliente AND j.turma_id = a.turma_id AND j.disciplina_id = a.disciplina_id
       AND j.mes = date_trunc('month', a.data_aula)::date
      LEFT JOIN mb ON mb.cod_cliente = j.cod_cliente AND mb.turma_id = j.turma_id AND mb.aluno_id = j.aluno_id
      LEFT JOIN dw.fato_falta_dia f
        ON f.cod_cliente = a.cod_cliente AND f.turma_id = a.turma_id AND f.disciplina_id = a.disciplina_id
       AND f.aluno_id = j.aluno_id AND f.data_aula = a.data_aula
     WHERE a.aulas_concluidas > 0
       AND (mb.ini IS NULL OR a.data_aula >= mb.ini) AND (mb.fim IS NULL OR a.data_aula <= mb.fim)
), agg AS (
    SELECT cod_cliente, turma_id, disciplina_id, data_aula, count(*) AS alunos,
           count(*) FILTER (WHERE horas_faltadas > 0 AND horas_faltadas >= (SELECT lim FROM cfg) * horas_aula) AS faltas
      FROM elig GROUP BY cod_cliente, turma_id, disciplina_id, data_aula
)
SELECT a.cod_cliente, a.data_aula,
       extract(year FROM a.data_aula)::int AS ano, extract(month FROM a.data_aula)::int AS mes_numero,
       bi.mes_nome(a.data_aula) AS mes_nome, to_char(a.data_aula, 'YYYY-MM') AS ano_mes,
       date_trunc('month', a.data_aula)::date AS mes,
       (ARRAY['Segunda','Terça','Quarta','Quinta','Sexta','Sábado','Domingo'])[extract(isodow FROM a.data_aula)::int] AS dia_da_semana,
       a.turma_id, t.nome AS turma, t.curso, a.modulo, a.disciplina_id, dd.nome AS disciplina,
       a.aulas_concluidas AS horas_de_aula,
       COALESCE(g.alunos, 0) AS alunos, COALESCE(g.alunos, 0) - COALESCE(g.faltas, 0) AS presencas,
       COALESCE(g.faltas, 0) AS faltas,
       round(100.0 * (COALESCE(g.alunos, 0) - COALESCE(g.faltas, 0)) / NULLIF(g.alunos, 0), 1) AS pct_frequencia
FROM dw.fato_aula_dia a
LEFT JOIN agg g ON g.cod_cliente = a.cod_cliente AND g.turma_id = a.turma_id
               AND g.disciplina_id = a.disciplina_id AND g.data_aula = a.data_aula
LEFT JOIN dw.dim_turma t ON t.cod_cliente = a.cod_cliente AND t.turma_id = a.turma_id
LEFT JOIN dw.dim_disciplina dd ON dd.cod_cliente = a.cod_cliente AND dd.disciplina_id = a.disciplina_id
WHERE a.aulas_concluidas > 0;

-- 8d) COBERTURA: cada turma tem o registro completo, da primeira à última aula concluída?
--     cobertura_inicio = 'completa' quando existe um mês consultado anterior ao da primeira aula concluída
--     (a carga volta no tempo até achar um mês sem aula). meses_faltando deve ser 0.
CREATE VIEW bi.vw_cobertura_frequencia AS
WITH jan AS (
    SELECT cod_cliente, turma_id, min(mes) AS primeiro_mes_consultado, max(mes) AS ultimo_mes_consultado,
           count(DISTINCT mes) AS meses_consultados
      FROM stg.frequencia_janela_atual GROUP BY cod_cliente, turma_id
), aul AS (
    SELECT cod_cliente, turma_id,
           min(data_aula) FILTER (WHERE aulas_concluidas > 0) AS primeira_aula_concluida,
           max(data_aula) FILTER (WHERE aulas_concluidas > 0) AS ultima_aula_concluida,
           count(DISTINCT data_aula) FILTER (WHERE aulas_concluidas > 0) AS dias_de_aula_concluidos
      FROM dw.fato_aula_dia GROUP BY cod_cliente, turma_id
)
SELECT j.cod_cliente, j.turma_id, t.nome AS turma, t.curso, t.situacao AS situacao_turma,
       a.primeira_aula_concluida, a.ultima_aula_concluida, COALESCE(a.dias_de_aula_concluidos, 0) AS dias_de_aula_concluidos,
       j.primeiro_mes_consultado, j.ultimo_mes_consultado, j.meses_consultados,
       ((extract(year FROM j.ultimo_mes_consultado) - extract(year FROM j.primeiro_mes_consultado)) * 12
         + extract(month FROM j.ultimo_mes_consultado) - extract(month FROM j.primeiro_mes_consultado) + 1)::int
         - j.meses_consultados AS meses_faltando,
       CASE WHEN a.primeira_aula_concluida IS NULL THEN 'sem aula concluída'
            WHEN date_trunc('month', a.primeira_aula_concluida)::date > j.primeiro_mes_consultado THEN 'completa'
            ELSE 'verificar o início' END AS cobertura_inicio
FROM jan j
LEFT JOIN aul a ON a.cod_cliente = j.cod_cliente AND a.turma_id = j.turma_id
LEFT JOIN dw.dim_turma t ON t.cod_cliente = j.cod_cliente AND t.turma_id = j.turma_id;

-- 8e) Tabela de datas para o Power BI (2025 a 2027), com nome do mês em português
CREATE VIEW bi.dim_data AS
SELECT d::date AS data, extract(year FROM d)::int AS ano, extract(month FROM d)::int AS mes_numero,
       bi.mes_nome(d::date) AS mes_nome, to_char(d, 'YYYY-MM') AS ano_mes,
       bi.mes_nome(d::date) || '/' || extract(year FROM d)::int AS mes_ano,
       extract(quarter FROM d)::int AS trimestre, extract(week FROM d)::int AS semana_iso,
       extract(isodow FROM d)::int AS dia_da_semana_numero,
       (ARRAY['Segunda','Terça','Quarta','Quinta','Sexta','Sábado','Domingo'])[extract(isodow FROM d)::int] AS dia_da_semana
FROM generate_series('2025-01-01'::timestamp, '2027-12-31'::timestamp, interval '1 day') d;

-- 8f) POWER BI: tabelas de apoio e resumos por aluno na turma e por mês
--     dim_turma: uma linha por turma (use como dimensão). dim_aluno: SÓ id e nome (sem CPF, e-mail ou telefone);
--     se o relatório for compartilhado fora da equipe, deixe essa tabela de fora do modelo.
CREATE VIEW bi.dim_sede AS
SELECT t.cod_cliente, COALESCE(s.nome, '(sede sem nome)') AS sede
FROM (SELECT DISTINCT cod_cliente FROM dw.dim_turma) t
LEFT JOIN dw.sede s ON s.cod_cliente = t.cod_cliente;

CREATE VIEW bi.dim_turma AS
SELECT t.cod_cliente, COALESCE(s.nome, '(sede sem nome)') AS sede,
       t.turma_id, t.nome AS turma, t.sigla, t.curso, t.situacao AS situacao_turma, t.turno, t.horario,
       (ARRAY['Segunda','Terça','Quarta','Quinta','Sexta','Sábado','Domingo'])[stg.dia_semana_previsto(t.horario)] AS dia_da_semana,
       t.data_inicio, t.data_termino, t.max_alunos,
       v.alunos_vigentes, v.vagas_livres, v.ocupacao_pct,
       c.primeira_aula_concluida, c.ultima_aula_concluida, c.dias_de_aula_concluidos, c.cobertura_inicio
FROM dw.dim_turma t
LEFT JOIN dw.sede s ON s.cod_cliente = t.cod_cliente
LEFT JOIN bi.vw_alunos_por_turma v ON v.cod_cliente = t.cod_cliente AND v.turma_id = t.turma_id
LEFT JOIN bi.vw_cobertura_frequencia c ON c.cod_cliente = t.cod_cliente AND c.turma_id = t.turma_id
WHERE lower(t.situacao) IN ('vigente', 'aberta') OR c.turma_id IS NOT NULL;

CREATE VIEW bi.dim_aluno AS
SELECT cod_cliente, aluno_id, btrim(nome) AS nome FROM dw.dim_aluno;

-- Uma linha por aluno e turma: primeiro dia, se entrou no início ou depois, totais, frequência geral,
-- última presença e faltas seguidas até o último dia de aula. chave_aluno_turma liga com vw_frequencia_aluno_dia.
CREATE VIEW bi.vw_aluno_turma AS
WITH base AS (
    SELECT f.cod_cliente, f.turma_id, f.aluno_id,
           count(*)                                       AS dias_de_aula,
           count(*) FILTER (WHERE f.status = 'Presença')  AS presencas,
           count(*) FILTER (WHERE f.status = 'Falta')     AS faltas,
           count(*) FILTER (WHERE f.parcial)              AS parciais,
           min(f.data_aula)                               AS primeiro_dia,
           max(f.data_aula)                               AS ultimo_dia,
           max(f.data_aula) FILTER (WHERE f.status = 'Presença') AS ultima_presenca
      FROM dw.fato_frequencia_dia f GROUP BY f.cod_cliente, f.turma_id, f.aluno_id
), seq AS (
    SELECT cod_cliente, turma_id, aluno_id, count(*) AS faltas_seguidas_atuais
      FROM (SELECT x.*, sum(CASE WHEN x.status = 'Presença' THEN 1 ELSE 0 END)
                          OVER (PARTITION BY x.cod_cliente, x.turma_id, x.aluno_id ORDER BY x.data_aula DESC) AS pres_acum
              FROM dw.fato_frequencia_dia x) y
     WHERE pres_acum = 0 GROUP BY cod_cliente, turma_id, aluno_id
), mat AS (
    SELECT DISTINCT ON (cod_cliente, turma_id, aluno_id)
           cod_cliente, turma_id, aluno_id, situacao AS situacao_matricula, data_matricula,
           data_inicio AS data_inicio_matricula, data_encerramento
      FROM dw.fato_matricula WHERE ativa_na_api
     ORDER BY cod_cliente, turma_id, aluno_id, data_inicio DESC NULLS LAST, contrato_id DESC
)
SELECT b.cod_cliente, b.turma_id::text || '-' || b.aluno_id::text AS chave_aluno_turma,
       b.turma_id, t.nome AS turma, t.curso, b.aluno_id,
       m.situacao_matricula, m.data_matricula, m.data_inicio_matricula, m.data_encerramento,
       c.primeira_aula_concluida AS primeira_aula_da_turma, b.primeiro_dia, b.ultimo_dia, b.ultima_presenca,
       CASE WHEN b.primeiro_dia <= c.primeira_aula_concluida THEN 'Desde o início' ELSE 'Entrou após o início' END AS entrada,
       b.primeiro_dia - c.primeira_aula_concluida AS dias_apos_o_inicio,
       b.dias_de_aula, b.presencas, b.faltas, b.parciais,
       round(100.0 * b.presencas / NULLIF(b.dias_de_aula, 0), 1) AS pct_frequencia,
       COALESCE(s.faltas_seguidas_atuais, 0) AS faltas_seguidas_atuais
FROM base b
LEFT JOIN seq s ON s.cod_cliente = b.cod_cliente AND s.turma_id = b.turma_id AND s.aluno_id = b.aluno_id
LEFT JOIN mat m ON m.cod_cliente = b.cod_cliente AND m.turma_id = b.turma_id AND m.aluno_id = b.aluno_id
LEFT JOIN dw.dim_turma t ON t.cod_cliente = b.cod_cliente AND t.turma_id = b.turma_id
LEFT JOIN bi.vw_cobertura_frequencia c ON c.cod_cliente = b.cod_cliente AND c.turma_id = b.turma_id;

-- Entradas e saídas de matrícula por turma e mês (datas do Sponte: matrícula e encerramento).
-- Mostra, junto da frequência, se um curso está ganhando ou perdendo alunos.
CREATE VIEW bi.vw_movimento_matricula_mes AS
SELECT x.cod_cliente, x.curso, x.turma_id, x.turma, x.mes,
       extract(year FROM x.mes)::int AS ano, extract(month FROM x.mes)::int AS mes_numero,
       bi.mes_nome(x.mes) AS mes_nome, to_char(x.mes, 'YYYY-MM') AS ano_mes,
       x.entradas, x.saidas, x.entradas - x.saidas AS saldo
FROM (SELECT e.cod_cliente, t.curso, e.turma_id, t.nome AS turma, date_trunc('month', e.data_negocio)::date AS mes,
             count(*) FILTER (WHERE e.tipo = 'entrada') AS entradas,
             count(*) FILTER (WHERE e.tipo = 'saida')   AS saidas
        FROM dw.fato_matricula_evento e
        LEFT JOIN dw.dim_turma t ON t.cod_cliente = e.cod_cliente AND t.turma_id = e.turma_id
       WHERE e.tipo IN ('entrada', 'saida') AND e.data_negocio IS NOT NULL
       GROUP BY e.cod_cliente, t.curso, e.turma_id, t.nome, date_trunc('month', e.data_negocio)::date) x;

-- 9) Calendário: aulas previstas (dia da semana do horário da turma) x ocorridas (dias com aula concluída)
--    "aulas" aqui são dias de aula (encontros), não horas. mes_parcial = mês ainda em andamento.
--    dias_com_aula_no_diario = todos os dias com aula no diário, concluída ou não (o que se vê no Sponte).
--    datas_a_menos = previstas sem aula concluída | datas_a_mais = aula concluída em dia não previsto
--    datas_marcadas_nao_concluidas = entre as "a menos", as que têm aula marcada mas não concluída
--    datas_marcadas_fora_do_dia = aula marcada e não concluída em dia não previsto
CREATE VIEW bi.vw_calendario_turma_mes AS
SELECT c.cod_cliente, c.mes, c.turma_id, t.nome AS turma, t.curso, t.horario,
       c.dia_previsto, c.aulas_previstas, c.aulas_ocorridas,
       c.aulas_ocorridas - c.aulas_previstas                        AS diferenca,
       (SELECT count(DISTINCT a.data_aula) FROM dw.fato_aula_dia a
         WHERE a.cod_cliente = c.cod_cliente AND a.turma_id = c.turma_id
           AND date_trunc('month', a.data_aula)::date = c.mes)      AS dias_com_aula_no_diario,
       c.status, c.mes_parcial,
       bi.datas_txt(c.datas_a_menos)                                AS datas_a_menos,
       bi.datas_txt(c.datas_a_mais)                                 AS datas_a_mais,
       bi.datas_txt(c.datas_marcadas_nao_concluidas)                AS datas_marcadas_nao_concluidas,
       bi.datas_txt(c.datas_nao_concluidas_fora_do_dia)             AS datas_marcadas_fora_do_dia,
       c.dias_apos_termino_cadastrado,
       NULLIF(concat_ws('; ',
           CASE WHEN cardinality(c.datas_nao_concluidas_fora_do_dia) > 0
                THEN 'aula marcada e não concluída em dia não previsto' END,
           CASE WHEN c.dias_apos_termino_cadastrado > 0
                THEN 'aula depois do término cadastrado da turma' END), '') AS alertas
FROM dw.calendario_turma_mes c
LEFT JOIN dw.dim_turma t ON t.cod_cliente = c.cod_cliente AND t.turma_id = c.turma_id;

-- 10) Só as turmas e meses com divergência, para investigar (feriado? erro operacional no Sponte?)
--     menos = dia previsto sem aula concluída | mais = aula concluída em dia não previsto
--     trocado = as duas coisas. Também entram os meses com "alertas" (aula marcada e não concluída
--     fora do dia previsto, ou aula depois do término cadastrado). Ordenado por mês.
CREATE VIEW bi.vw_calendario_divergencias AS
SELECT * FROM bi.vw_calendario_turma_mes
WHERE status NOT IN ('igual', 'sem dia previsto') OR alertas IS NOT NULL
ORDER BY mes, turma_id;

-- 11) Dias sem aula: para cada data em que alguma turma ficou sem aula, quantas turmas do MESMO dia da
--     semana tiveram aula e quantas não. pct_sem_aula alto (100) = todas pararam: provável feriado ou
--     evento. Valor baixo = turma isolada: investigar o cadastro dessa turma. Ordenado por data.
CREATE VIEW bi.vw_dias_sem_aula AS
WITH sem AS (
    SELECT c.cod_cliente, d AS data_aula, count(DISTINCT c.turma_id) AS turmas_sem_aula
      FROM dw.calendario_turma_mes c
     CROSS JOIN LATERAL unnest(c.datas_a_menos) AS d
     GROUP BY c.cod_cliente, d
), com AS (
    SELECT a.cod_cliente, a.data_aula, count(DISTINCT a.turma_id) AS turmas_com_aula
      FROM dw.fato_aula_dia a
      JOIN dw.calendario_turma_mes c
        ON c.cod_cliente = a.cod_cliente AND c.turma_id = a.turma_id
       AND c.mes = date_trunc('month', a.data_aula)::date
     WHERE a.aulas_concluidas > 0
       AND array_position(ARRAY['Segunda','Terça','Quarta','Quinta','Sexta','Sábado','Domingo'], c.dia_previsto)
           = extract(isodow FROM a.data_aula)::int
     GROUP BY a.cod_cliente, a.data_aula
)
SELECT s.cod_cliente, s.data_aula,
       (ARRAY['Segunda','Terça','Quarta','Quinta','Sexta','Sábado','Domingo'])[extract(isodow FROM s.data_aula)::int] AS dia_da_semana,
       COALESCE(k.turmas_com_aula, 0) AS turmas_com_aula,
       s.turmas_sem_aula,
       round(100.0 * s.turmas_sem_aula / NULLIF(s.turmas_sem_aula + COALESCE(k.turmas_com_aula, 0), 0), 0) AS pct_sem_aula
FROM sem s
LEFT JOIN com k ON k.cod_cliente = s.cod_cliente AND k.data_aula = s.data_aula
ORDER BY s.data_aula;

-- 12) PENDÊNCIAS PARA CORRIGIR NO SPONTE: tudo o que é divergente, uma linha por aula, dia ou aluno,
--     com data, turma, módulo e disciplina para achar a aula no Sponte. Quando a correção é feita lá,
--     a linha some na carga seguinte. A frequência só usa aulas concluídas; isto é a lista do que sobrou.
--     tipo: Aula não concluída | Dia previsto sem aula no diário | Aula concluída em dia não previsto
--           | Falta parcial | Término cadastrado vencido | TotalFaltas diferente da lista
CREATE VIEW bi.vw_pendencias_sponte AS
WITH dia AS (
    SELECT cod_cliente, turma_id, data_aula, sum(aulas_concluidas) AS conc_dia
      FROM dw.fato_aula_dia GROUP BY cod_cliente, turma_id, data_aula
), mes_info AS (
    SELECT a.cod_cliente, a.turma_id, date_trunc('month', a.data_aula)::date AS mes,
           string_agg(DISTINCT a.modulo::text, ', ') AS modulos,
           string_agg(DISTINCT dd.nome, ', ')        AS disciplinas
      FROM dw.fato_aula_dia a
      LEFT JOIN dw.dim_disciplina dd ON dd.cod_cliente = a.cod_cliente AND dd.disciplina_id = a.disciplina_id
     GROUP BY a.cod_cliente, a.turma_id, date_trunc('month', a.data_aula)::date
)
-- 1) aula marcada e não concluída, que já passou
SELECT 'Aula não concluída'::text AS tipo,
       a.data_aula, date_trunc('month', a.data_aula)::date AS mes,
       a.cod_cliente, a.turma_id, t.nome AS turma, t.curso,
       a.modulo::text AS modulo, a.disciplina_id, dd.nome AS disciplina,
       NULL::int AS aluno_id, a.aulas_nao_concluidas AS horas_afetadas, a.aulas_total AS horas_da_aula,
       'Situação no Sponte: ' || COALESCE(a.situacoes, '?') || '. ' ||
       CASE WHEN d.conc_dia > 0
            THEN 'A turma teve outra aula concluída neste dia: provável aula paralela que não aconteceu (cancelar ou excluir).'
            ELSE 'Nenhuma aula concluída neste dia: aula não realizada (cancelar) ou realizada e sem conclusão (concluir).' END ||
       CASE WHEN stg.dia_semana_previsto(t.horario) IS NOT NULL
             AND stg.dia_semana_previsto(t.horario) <> extract(isodow FROM a.data_aula)::int
            THEN ' Dia fora do previsto para a turma.' ELSE '' END AS detalhe
  FROM dw.fato_aula_dia a
  JOIN dia d ON d.cod_cliente = a.cod_cliente AND d.turma_id = a.turma_id AND d.data_aula = a.data_aula
  LEFT JOIN dw.dim_turma t ON t.cod_cliente = a.cod_cliente AND t.turma_id = a.turma_id
  LEFT JOIN dw.dim_disciplina dd ON dd.cod_cliente = a.cod_cliente AND dd.disciplina_id = a.disciplina_id
 WHERE a.aulas_nao_concluidas > 0 AND a.data_aula < current_date
UNION ALL
-- 2) dia previsto sem nenhuma aula no diário (feriado, evento ou aula não lançada)
SELECT 'Dia previsto sem aula no diário', x.d, c.mes, c.cod_cliente, c.turma_id, t.nome, t.curso,
       mi.modulos, NULL::int, mi.disciplinas, NULL::int, NULL::int, NULL::int,
       'Nenhuma aula no diário nesta data: feriado ou evento, ou aula não lançada. Módulo e disciplinas: os que têm aula neste mês.'
  FROM dw.calendario_turma_mes c
 CROSS JOIN LATERAL unnest(c.datas_a_menos) AS x(d)
  LEFT JOIN dw.dim_turma t ON t.cod_cliente = c.cod_cliente AND t.turma_id = c.turma_id
  LEFT JOIN mes_info mi ON mi.cod_cliente = c.cod_cliente AND mi.turma_id = c.turma_id AND mi.mes = c.mes
 WHERE NOT (x.d = ANY (COALESCE(c.datas_marcadas_nao_concluidas, '{}'::date[])))
UNION ALL
-- 3) aula concluída em dia diferente do previsto
SELECT 'Aula concluída em dia não previsto', x.d, c.mes, c.cod_cliente, c.turma_id, t.nome, t.curso,
       a.modulo::text, a.disciplina_id, dd.nome, NULL::int, a.aulas_concluidas, a.aulas_total,
       'A turma tem aula concluída em dia diferente do previsto: conferir a data da aula.'
  FROM dw.calendario_turma_mes c
 CROSS JOIN LATERAL unnest(c.datas_a_mais) AS x(d)
  JOIN dw.fato_aula_dia a
    ON a.cod_cliente = c.cod_cliente AND a.turma_id = c.turma_id AND a.data_aula = x.d AND a.aulas_concluidas > 0
  LEFT JOIN dw.dim_turma t ON t.cod_cliente = c.cod_cliente AND t.turma_id = c.turma_id
  LEFT JOIN dw.dim_disciplina dd ON dd.cod_cliente = a.cod_cliente AND dd.disciplina_id = a.disciplina_id
UNION ALL
-- 4) falta parcial: o aluno tem falta em parte das horas do dia. Mostra a aula (disciplina) em que a falta foi lançada.
SELECT 'Falta parcial', f.data_aula, date_trunc('month', f.data_aula)::date, f.cod_cliente, f.turma_id, t.nome, t.curso,
       a.modulo::text, f.disciplina_id, dd.nome, f.aluno_id, f.horas_faltadas, a.aulas_concluidas,
       CASE WHEN f.horas_faltadas < a.aulas_concluidas
            THEN 'Faltou em ' || f.horas_faltadas || ' de ' || a.aulas_concluidas
                 || ' horas desta aula: lançar a falta em todas as horas (ou em nenhuma).'
            ELSE 'Falta em todas as horas desta aula, mas o aluno tem presença nas outras aulas do dia: conferir o dia todo.' END
  FROM dw.fato_frequencia_dia fd
  JOIN dw.fato_falta_dia f
    ON f.cod_cliente = fd.cod_cliente AND f.turma_id = fd.turma_id AND f.aluno_id = fd.aluno_id AND f.data_aula = fd.data_aula
  JOIN dw.fato_aula_dia a
    ON a.cod_cliente = f.cod_cliente AND a.turma_id = f.turma_id AND a.disciplina_id = f.disciplina_id AND a.data_aula = f.data_aula
  LEFT JOIN dw.dim_turma t ON t.cod_cliente = f.cod_cliente AND t.turma_id = f.turma_id
  LEFT JOIN dw.dim_disciplina dd ON dd.cod_cliente = f.cod_cliente AND dd.disciplina_id = f.disciplina_id
 WHERE fd.parcial
UNION ALL
-- 5) término cadastrado da turma já passou e ainda há aula concluída (uma linha por turma)
SELECT 'Término cadastrado vencido', u.ultima_aula, date_trunc('month', u.ultima_aula)::date, t.cod_cliente, t.turma_id,
       t.nome, t.curso, NULL::text, NULL::int, NULL::text, NULL::int, NULL::int, NULL::int,
       'Término cadastrado em ' || to_char(t.data_termino, 'DD/MM/YYYY') || '; a turma teve aula concluída até '
       || to_char(u.ultima_aula, 'DD/MM/YYYY') || '. Ajustar a data de término da turma.'
  FROM dw.dim_turma t
  JOIN (SELECT cod_cliente, turma_id, max(data_aula) AS ultima_aula
          FROM dw.fato_aula_dia WHERE aulas_concluidas > 0 GROUP BY cod_cliente, turma_id) u
    ON u.cod_cliente = t.cod_cliente AND u.turma_id = t.turma_id
 WHERE t.data_termino IS NOT NULL AND u.ultima_aula > t.data_termino
UNION ALL
-- 6) o total de faltas informado pela API não bate com as faltas listadas
SELECT 'TotalFaltas diferente da lista', NULL::date, x.mes, x.cod_cliente, x.turma_id, t.nome, t.curso,
       (SELECT max(a.modulo)::text FROM dw.fato_aula_dia a
         WHERE a.cod_cliente = x.cod_cliente AND a.turma_id = x.turma_id AND a.disciplina_id = x.disciplina_id
           AND date_trunc('month', a.data_aula)::date = x.mes),
       x.disciplina_id, dd.nome, x.aluno_id, NULL::int, NULL::int,
       'TotalFaltas da API = ' || x.faltas_api || '; faltas listadas = ' || x.faltas_listadas || '.'
  FROM (SELECT fj.cod_cliente, fj.turma_id, fj.mes, fj.disciplina_id, fj.aluno_id,
               COALESCE(fj.faltas, 0) AS faltas_api, COALESCE(sum(f.horas_faltadas), 0) AS faltas_listadas
          FROM dw.fato_frequencia_janela fj
          LEFT JOIN dw.fato_falta_dia f
            ON f.cod_cliente = fj.cod_cliente AND f.turma_id = fj.turma_id AND f.disciplina_id = fj.disciplina_id
           AND f.aluno_id = fj.aluno_id AND date_trunc('month', f.data_aula)::date = fj.mes
         GROUP BY fj.cod_cliente, fj.turma_id, fj.mes, fj.disciplina_id, fj.aluno_id, fj.faltas
        HAVING COALESCE(sum(f.horas_faltadas), 0) <> COALESCE(fj.faltas, 0)) x
  LEFT JOIN dw.dim_turma t ON t.cod_cliente = x.cod_cliente AND t.turma_id = x.turma_id
  LEFT JOIN dw.dim_disciplina dd ON dd.cod_cliente = x.cod_cliente AND dd.disciplina_id = x.disciplina_id
ORDER BY mes, data_aula NULLS LAST, turma_id, tipo;

-- ---------------------------------------------------------------------
-- Exemplos de uso
-- ---------------------------------------------------------------------
--   SELECT * FROM bi.vw_alunos_por_turma ORDER BY alunos_vigentes DESC;
--   SELECT * FROM bi.vw_turmas_por_professor ORDER BY turmas DESC;
--   SELECT * FROM bi.vw_cursos_comparativo ORDER BY turmas DESC;
--   SELECT * FROM bi.vw_alunos_por_situacao ORDER BY situacao_turma, matriculas DESC;
--   SELECT * FROM bi.vw_calendario_divergencias;           -- aulas previstas x ocorridas, por mês
--   SELECT * FROM bi.vw_dias_sem_aula;                     -- datas sem aula e quantas turmas pararam
--   SELECT * FROM bi.vw_pendencias_sponte;                 -- o que corrigir no Sponte (data, turma, módulo, disciplina)
--   SELECT * FROM bi.vw_frequencia_turma_mes ORDER BY mes, turma_id;

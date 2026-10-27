-- =====================================================================
-- Qualidade da frequência (somente leitura). Rode depois de python src/carga_frequencia.py.
-- Só IDs, datas e contagens: nenhum nome de aluno ou professor.
-- =====================================================================

-- 0) Resumo
SELECT '1  dias de falta PARCIAL (aluno faltou em parte das horas: corrigir no Sponte)' AS verificacao, count(*) AS casos
  FROM dw.fato_frequencia_dia WHERE parcial
UNION ALL SELECT '2  aulas passadas que não estão Concluída (horas)', COALESCE(sum(aulas_nao_concluidas), 0)
  FROM dw.fato_aula_dia WHERE data_aula < current_date
UNION ALL SELECT '3  turma-mês com calendário divergente (menos, mais ou trocado)', count(*)
  FROM dw.calendario_turma_mes WHERE status IN ('menos', 'mais', 'trocado')
UNION ALL SELECT '4  turma-mês com aula depois do término cadastrado da turma', count(*)
  FROM dw.calendario_turma_mes WHERE dias_apos_termino_cadastrado > 0
UNION ALL SELECT '5  aluno/disciplina/mês em que TotalFaltas da API difere das faltas listadas', count(*) FROM (
    SELECT fj.turma_id, fj.mes, fj.disciplina_id, fj.aluno_id
      FROM dw.fato_frequencia_janela fj
      LEFT JOIN dw.fato_falta_dia f ON f.cod_cliente = fj.cod_cliente AND f.turma_id = fj.turma_id
       AND f.disciplina_id = fj.disciplina_id AND f.aluno_id = fj.aluno_id
       AND date_trunc('month', f.data_aula)::date = fj.mes
     GROUP BY fj.turma_id, fj.mes, fj.disciplina_id, fj.aluno_id, fj.faltas
    HAVING COALESCE(sum(f.horas_faltadas), 0) <> COALESCE(fj.faltas, 0)) x
UNION ALL SELECT '6  faltas em dia sem aula concluída', count(*)
  FROM dw.fato_falta_dia f
  WHERE NOT EXISTS (SELECT 1 FROM dw.fato_aula_dia a
                     WHERE a.cod_cliente = f.cod_cliente AND a.turma_id = f.turma_id
                       AND a.disciplina_id = f.disciplina_id AND a.data_aula = f.data_aula AND a.aulas_concluidas > 0)
ORDER BY 1;

-- 1) Dias parciais: turma, disciplina não aparece (o dia soma as disciplinas); só IDs e datas
SELECT turma_id, aluno_id, data_aula, horas_faltadas, aulas_dia
FROM dw.fato_frequencia_dia WHERE parcial ORDER BY data_aula, turma_id, aluno_id;

-- 2) Aulas passadas não concluídas, por turma e mês (horas e dias)
SELECT turma_id, date_trunc('month', data_aula)::date AS mes,
       sum(aulas_nao_concluidas) AS horas_nao_concluidas, count(*) FILTER (WHERE aulas_concluidas = 0) AS dias_sem_conclusao
FROM dw.fato_aula_dia
WHERE data_aula < current_date AND aulas_nao_concluidas > 0
GROUP BY 1, 2 ORDER BY 2, 1;

-- 3 e 4) Calendário divergente ou com aula após o término cadastrado (versão completa: bi.vw_calendario_divergencias)
SELECT mes, turma_id, status, aulas_previstas, aulas_ocorridas, datas_a_menos, datas_a_mais, dias_apos_termino_cadastrado
FROM bi.vw_calendario_turma_mes
WHERE status IN ('menos', 'mais', 'trocado') OR dias_apos_termino_cadastrado > 0
ORDER BY mes, turma_id;

-- 5) A frequência da API conta só aulas concluídas? Por turma, mês e disciplina compara
--    (presenças + faltas) somadas dos alunos com (nº de alunos x aulas concluídas) e (nº de alunos x todas as aulas).
--    Aluno que entrou ou saiu no meio do mês pode dar "outro".
WITH api AS (
    SELECT turma_id, mes, disciplina_id, count(*) AS alunos, sum(COALESCE(presencas, 0) + COALESCE(faltas, 0)) AS total_api
      FROM dw.fato_frequencia_janela GROUP BY 1, 2, 3
), aulas AS (
    SELECT turma_id, date_trunc('month', data_aula)::date AS mes, disciplina_id,
           sum(aulas_concluidas) AS conc, sum(aulas_total) AS todas
      FROM dw.fato_aula_dia GROUP BY 1, 2, 3
)
SELECT CASE WHEN a.todas = a.conc THEN 'sem aula não concluída (não decide)'
            WHEN api.total_api = api.alunos * a.conc THEN 'só aulas concluídas'
            WHEN api.total_api = api.alunos * a.todas THEN 'inclui as não concluídas'
            ELSE 'outro' END AS a_api_conta, count(*) AS turma_mes_disciplina
FROM api JOIN aulas a USING (turma_id, mes, disciplina_id)
GROUP BY 1 ORDER BY 2 DESC;

-- 6) Período da matrícula: as horas de aula concluídas dentro do período da matrícula do aluno
--    batem com o total da API (presenças + faltas)? Se "diferentes" for alto, a data de início ou
--    de encerramento das matrículas não reflete o período em que o aluno realmente frequentou.
WITH mb AS (
    SELECT cod_cliente, turma_id, aluno_id, min(data_inicio) AS ini,
           CASE WHEN bool_or(data_encerramento IS NULL) THEN NULL ELSE max(data_encerramento) END AS fim
      FROM dw.fato_matricula GROUP BY cod_cliente, turma_id, aluno_id
), elig AS (
    SELECT fj.turma_id, fj.mes, fj.disciplina_id, fj.aluno_id,
           COALESCE(fj.presencas, 0) + COALESCE(fj.faltas, 0) AS total_api,
           COALESCE(sum(a.aulas_concluidas), 0) AS horas_elegiveis
      FROM dw.fato_frequencia_janela fj
      LEFT JOIN mb ON mb.cod_cliente = fj.cod_cliente AND mb.turma_id = fj.turma_id AND mb.aluno_id = fj.aluno_id
      LEFT JOIN dw.fato_aula_dia a
        ON a.cod_cliente = fj.cod_cliente AND a.turma_id = fj.turma_id AND a.disciplina_id = fj.disciplina_id
       AND date_trunc('month', a.data_aula)::date = fj.mes AND a.aulas_concluidas > 0
       AND (mb.ini IS NULL OR a.data_aula >= mb.ini) AND (mb.fim IS NULL OR a.data_aula <= mb.fim)
     GROUP BY fj.turma_id, fj.mes, fj.disciplina_id, fj.aluno_id, fj.presencas, fj.faltas
)
SELECT count(*) FILTER (WHERE horas_elegiveis = total_api) AS iguais,
       count(*) FILTER (WHERE horas_elegiveis <> total_api) AS diferentes
FROM elig;

-- 7) Aulas passadas não concluídas, por mês, separando: (a) em dia que a turma teve OUTRA aula concluída
--    (aula marcada em paralelo que provavelmente não aconteceu) e (b) em dia sem nenhuma aula concluída
--    (dia não realizado, ou diário sem fechamento).
SELECT date_trunc('month', a.data_aula)::date AS mes,
       COALESCE(sum(a.aulas_nao_concluidas) FILTER (WHERE d.conc > 0), 0)  AS horas_em_dia_com_outra_aula_concluida,
       COALESCE(sum(a.aulas_nao_concluidas) FILTER (WHERE d.conc = 0), 0)  AS horas_em_dia_sem_aula_concluida
FROM dw.fato_aula_dia a
JOIN (SELECT cod_cliente, turma_id, data_aula, sum(aulas_concluidas) AS conc
        FROM dw.fato_aula_dia GROUP BY cod_cliente, turma_id, data_aula) d
  USING (cod_cliente, turma_id, data_aula)
WHERE a.data_aula < current_date AND a.aulas_nao_concluidas > 0
GROUP BY 1 ORDER BY 1;

-- 8) As turmas com mais horas de aula passadas não concluídas (top 10)
SELECT turma_id, sum(aulas_nao_concluidas) AS horas_nao_concluidas,
       sum(aulas_nao_concluidas) FILTER (WHERE aulas_concluidas = 0) AS horas_em_dia_sem_aula_concluida
FROM dw.fato_aula_dia WHERE data_aula < current_date
GROUP BY 1 HAVING sum(aulas_nao_concluidas) > 0 ORDER BY 2 DESC LIMIT 10;

-- 9) Detalhe da verificação 5: aluno, disciplina e mês em que TotalFaltas da API difere das faltas listadas
SELECT fj.turma_id, fj.mes, fj.disciplina_id, fj.aluno_id, fj.faltas AS faltas_api,
       COALESCE(sum(f.horas_faltadas), 0) AS faltas_listadas
FROM dw.fato_frequencia_janela fj
LEFT JOIN dw.fato_falta_dia f
  ON f.cod_cliente = fj.cod_cliente AND f.turma_id = fj.turma_id AND f.disciplina_id = fj.disciplina_id
 AND f.aluno_id = fj.aluno_id AND date_trunc('month', f.data_aula)::date = fj.mes
GROUP BY fj.turma_id, fj.mes, fj.disciplina_id, fj.aluno_id, fj.faltas
HAVING COALESCE(sum(f.horas_faltadas), 0) <> COALESCE(fj.faltas, 0)
ORDER BY fj.mes, fj.turma_id, fj.disciplina_id, fj.aluno_id;

-- 10) Faltas que vieram da API com data que não foi lida (se > 0, a data tem formato inesperado)
SELECT count(*) AS faltas_com_data_nao_lida FROM stg.falta WHERE data_aula IS NULL;

-- 11) Alunos que passaram pela turma: por turma e mês, as matrículas com algum dia no mês x os alunos que
--     aparecem na frequência. Devem bater. Diferença = aluno sem frequência devolvida pela API (ou que
--     entrou e saiu em dia sem aula). Exemplo da DA09 (turma 623): troque o filtro para ver só ela.
WITH meses AS (SELECT DISTINCT turma_id, mes FROM dw.fato_frequencia_janela),
matr AS (
    SELECT turma_id, aluno_id, min(data_inicio) AS ini,
           CASE WHEN bool_or(data_encerramento IS NULL) THEN NULL ELSE max(data_encerramento) END AS fim
      FROM dw.fato_matricula GROUP BY turma_id, aluno_id
)
SELECT m.turma_id, m.mes,
       (SELECT count(*) FROM matr x
         WHERE x.turma_id = m.turma_id
           AND (x.ini IS NULL OR x.ini <= (m.mes + interval '1 month' - interval '1 day')::date)
           AND (x.fim IS NULL OR x.fim >= m.mes))                                   AS matriculas_no_mes,
       (SELECT count(DISTINCT j.aluno_id) FROM dw.fato_frequencia_janela j
         WHERE j.turma_id = m.turma_id AND j.mes = m.mes)                           AS alunos_na_frequencia
FROM meses m
-- WHERE m.turma_id = 623
ORDER BY m.mes, m.turma_id;

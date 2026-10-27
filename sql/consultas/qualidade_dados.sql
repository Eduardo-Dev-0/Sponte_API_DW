-- =====================================================================
-- Qualidade dos dados vindos do Sponte (somente leitura).
-- Cada consulta devolve IDs e contagens, nunca nome, CPF ou e-mail.
-- Serve para (1) conferir se a lógica do DW está certa e (2) levar à equipe
-- que cuida do Sponte uma lista objetiva do que corrigir no cadastro.
-- Rode a consulta 0 primeiro; as demais detalham cada verificação.
-- =====================================================================

-- 0) Resumo: quantos casos de cada verificação (0 = tudo certo)
WITH ult AS (SELECT max(data_ref) AS d FROM dw.snapshot_turma_dia),
vig_alunos AS (
    SELECT DISTINCT aluno_id FROM dw.fato_matricula WHERE situacao = 'Vigente' AND ativa_na_api
)
SELECT '01 matrícula Vigente com data de encerramento' AS verificacao, count(*) AS casos
  FROM dw.fato_matricula WHERE situacao = 'Vigente' AND data_encerramento IS NOT NULL
UNION ALL SELECT '02 matrícula que saiu sem data de encerramento', count(*)
  FROM dw.fato_matricula WHERE situacao <> 'Vigente' AND data_encerramento IS NULL
UNION ALL SELECT '03 encerramento antes da data da matrícula', count(*)
  FROM dw.fato_matricula WHERE data_encerramento < data_matricula
UNION ALL SELECT '04 término antes do início na matrícula', count(*)
  FROM dw.fato_matricula WHERE data_termino < data_inicio
UNION ALL SELECT '05 turma Vigente com início no futuro', count(*)
  FROM dw.dim_turma WHERE lower(situacao) = 'vigente' AND data_inicio > current_date
UNION ALL SELECT '06 turma Aberta com início já passado', count(*)
  FROM dw.dim_turma WHERE lower(situacao) = 'aberta' AND data_inicio < current_date
UNION ALL SELECT '07 turma com mais vagas ocupadas que o máximo', count(*)
  FROM dw.snapshot_turma_dia s, ult WHERE s.data_ref = ult.d AND s.vagas_ocupadas > s.max_alunos
UNION ALL SELECT '08 turma com integrantes diferentes das matrículas Vigente', count(*)
  FROM dw.snapshot_turma_dia s, ult WHERE s.data_ref = ult.d AND s.qtd_integrantes <> s.qtd_matriculas_vigentes
UNION ALL SELECT '09 aluno com mais de uma matrícula Vigente na mesma turma', count(*) FROM (
    SELECT aluno_id, turma_id FROM dw.fato_matricula WHERE situacao = 'Vigente' AND ativa_na_api
    GROUP BY 1, 2 HAVING count(*) > 1) x
UNION ALL SELECT '10 turma Vigente sem nenhuma matrícula Vigente', count(*)
  FROM dw.dim_turma t WHERE lower(t.situacao) = 'vigente'
   AND NOT EXISTS (SELECT 1 FROM dw.fato_matricula f WHERE f.turma_id = t.turma_id AND f.situacao = 'Vigente')
UNION ALL SELECT '11 aluno Vigente com CPF ausente ou inválido', count(*)
  FROM dw.dim_aluno a JOIN vig_alunos v USING (aluno_id)
  WHERE a.cpf IS NULL OR length(a.cpf) <> 11 OR a.cpf ~ '^(\d)\1{10}$'
UNION ALL SELECT '12 aluno Vigente com e-mail ausente ou inválido', count(*)
  FROM dw.dim_aluno a JOIN vig_alunos v USING (aluno_id)
  WHERE a.email IS NULL OR a.email !~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$'
UNION ALL SELECT '13 CPF repetido em alunos Vigente diferentes (grupos)', count(*) FROM (
    SELECT a.cpf FROM dw.dim_aluno a JOIN vig_alunos v USING (aluno_id)
    WHERE a.cpf IS NOT NULL GROUP BY a.cpf HAVING count(DISTINCT a.aluno_id) > 1) x
UNION ALL SELECT '14 turma com horário fora do padrão "Dia HH:MM às HH:MM"', count(*)
  FROM dw.dim_turma WHERE horario IS NOT NULL AND horario !~ '^[^[:space:]\d]+ \d{2}:\d{2} às \d{2}:\d{2}$'
UNION ALL SELECT '15 turma sem horário', count(*) FROM dw.dim_turma WHERE horario IS NULL
UNION ALL SELECT '16 matrícula que sumiu da API (acompanhar)', count(*) FROM dw.fato_matricula WHERE NOT ativa_na_api
UNION ALL SELECT 'info: reativações (saiu e voltou a Vigente)', count(*)
  FROM dw.fato_matricula_evento WHERE tipo = 'mudanca_situacao' AND situacao_nova = 'Vigente'
UNION ALL SELECT 'info: transferências entre turmas', count(*)
  FROM dw.fato_matricula_evento WHERE tipo = 'mudanca_turma'
ORDER BY 1;

-- ---------------------------------------------------------------------
-- Detalhes (descomente/rode o que o resumo apontar). Só IDs.
-- ---------------------------------------------------------------------

-- 1 e 2) contratos com data de encerramento incoerente com a situação
SELECT turma_id, contrato_id, situacao, data_encerramento FROM dw.fato_matricula
WHERE (situacao = 'Vigente' AND data_encerramento IS NOT NULL)
   OR (situacao <> 'Vigente' AND data_encerramento IS NULL)
ORDER BY turma_id, contrato_id LIMIT 100;

-- 3 e 4) datas fora de ordem
SELECT turma_id, contrato_id, situacao, data_matricula, data_inicio, data_termino, data_encerramento
FROM dw.fato_matricula
WHERE data_encerramento < data_matricula OR data_termino < data_inicio
ORDER BY turma_id, contrato_id LIMIT 100;

-- 5 e 6) turmas com situação incoerente com a data de início
SELECT turma_id, situacao, data_inicio, data_termino FROM dw.dim_turma
WHERE (lower(situacao) = 'vigente' AND data_inicio > current_date)
   OR (lower(situacao) = 'aberta'  AND data_inicio < current_date)
ORDER BY turma_id;

-- 7 e 8) turmas em que as contagens não fecham (última carga)
SELECT turma_id, situacao, max_alunos, vagas_ocupadas, qtd_integrantes, qtd_matriculas_vigentes
FROM dw.snapshot_turma_dia
WHERE data_ref = (SELECT max(data_ref) FROM dw.snapshot_turma_dia)
  AND (vagas_ocupadas > max_alunos OR qtd_integrantes <> qtd_matriculas_vigentes)
ORDER BY turma_id;

-- 9) matrículas Vigente duplicadas do mesmo aluno na mesma turma (IDs de aluno e de turma)
SELECT aluno_id, turma_id, count(*) AS matriculas_vigentes FROM dw.fato_matricula
WHERE situacao = 'Vigente' AND ativa_na_api GROUP BY 1, 2 HAVING count(*) > 1 ORDER BY 3 DESC, 2;

-- 10) turmas Vigente sem aluno Vigente
SELECT t.turma_id, t.situacao, t.data_inicio FROM dw.dim_turma t
WHERE lower(t.situacao) = 'vigente'
  AND NOT EXISTS (SELECT 1 FROM dw.fato_matricula f WHERE f.turma_id = t.turma_id AND f.situacao = 'Vigente');

-- 11 e 12) alunos Vigente para corrigir cadastro (somente o ID do aluno e o que falta)
SELECT a.aluno_id,
       (a.cpf IS NULL OR length(a.cpf) <> 11 OR a.cpf ~ '^(\d)\1{10}$') AS cpf_ruim,
       (a.email IS NULL OR a.email !~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$') AS email_ruim
FROM dw.dim_aluno a
WHERE a.aluno_id IN (SELECT aluno_id FROM dw.fato_matricula WHERE situacao = 'Vigente' AND ativa_na_api)
  AND (a.cpf IS NULL OR length(a.cpf) <> 11 OR a.cpf ~ '^(\d)\1{10}$'
       OR a.email IS NULL OR a.email !~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$')
ORDER BY a.aluno_id;

-- 13) CPF repetido: quantos alunos distintos compartilham cada CPF (o CPF não é exibido)
SELECT count(DISTINCT a.aluno_id) AS alunos_com_o_mesmo_cpf, count(*) AS grupos FROM (
    SELECT a.cpf, count(DISTINCT a.aluno_id) AS n FROM dw.dim_aluno a
    WHERE a.cpf IS NOT NULL
      AND a.aluno_id IN (SELECT aluno_id FROM dw.fato_matricula WHERE situacao = 'Vigente' AND ativa_na_api)
    GROUP BY a.cpf HAVING count(DISTINCT a.aluno_id) > 1) g
JOIN dw.dim_aluno a ON a.cpf = g.cpf GROUP BY g.n ORDER BY 1;

-- 14 e 15) horários que não seguiram o padrão ou estão vazios
SELECT turma_id, situacao, horario FROM dw.dim_turma
WHERE horario IS NULL OR horario !~ '^[^[:space:]\d]+ \d{2}:\d{2} às \d{2}:\d{2}$'
ORDER BY turma_id;

-- 16) matrículas que sumiram da API, por turma
SELECT turma_id, count(*) AS sumiram FROM dw.fato_matricula WHERE NOT ativa_na_api GROUP BY 1 ORDER BY 1;

-- info) reativações e transferências, sem nomes
SELECT tipo, contrato_id, turma_id_anterior, turma_id, situacao_anterior, situacao_nova, data_negocio
FROM dw.fato_matricula_evento
WHERE tipo = 'mudanca_turma' OR (tipo = 'mudanca_situacao' AND situacao_nova = 'Vigente')
ORDER BY data_negocio, tipo, contrato_id;

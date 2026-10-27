-- =====================================================================
-- Consultas de conferência (somente leitura). Rode no pgAdmin / psql,
-- conectado ao banco sponte_dw. Nenhuma devolve CPF, e-mail ou nome de aluno.
-- =====================================================================

-- 1) Últimas cargas e seu estado
SELECT carga_id, cod_cliente, status, iniciada_em, finalizada_em, observacao
FROM raw.carga ORDER BY carga_id DESC LIMIT 5;

-- 2) Volume da última carga ok (turmas / matrículas / integrantes)
SELECT (SELECT count(*) FROM stg.turma)      AS turmas,
       (SELECT count(*) FROM stg.matricula)  AS matriculas,
       (SELECT count(*) FROM stg.integrante) AS integrantes;

-- 3) Matrículas por situação (última carga)
SELECT situacao, count(*) FROM stg.matricula GROUP BY 1 ORDER BY 2 DESC;

-- 4) Eventos por tipo e por carga (reprocessar a mesma carga NÃO pode duplicar)
SELECT carga_id, tipo, carga_inicial, count(*)
FROM dw.fato_matricula_evento GROUP BY 1, 2, 3 ORDER BY 1, 2, 3;

-- 5) data_encerramento por situação: deve existir só nas matrículas que saíram
SELECT situacao, count(*) AS total, count(data_encerramento) AS com_encerramento,
       min(data_encerramento) AS primeira, max(data_encerramento) AS ultima
FROM dw.fato_matricula GROUP BY situacao ORDER BY total DESC;

-- 6) Datas que não foram interpretadas (esperado: 0 linhas)
SELECT contrato_id FROM stg.matricula
WHERE data_matricula IS NULL OR data_inicio IS NULL OR data_termino IS NULL;

-- 7) ContratoID repetido na carga (esperado: 0 linhas)
SELECT contrato_id, count(*) FROM stg.matricula GROUP BY 1 HAVING count(*) > 1;

-- 8) Horário da turma: quantas têm e como o Sponte escreve
SELECT turma_id, situacao, turno, horario FROM dw.dim_turma ORDER BY turma_id LIMIT 15;
SELECT count(horario) AS com_horario, count(*) AS total FROM dw.dim_turma;

-- 9) Módulo atual das turmas (se todas forem 1, o padrão do GetIntegrantesTurmas serve)
SELECT payload->>'ModuloAtual' AS modulo_atual, count(*)
FROM raw.turma
WHERE carga_id = (SELECT max(carga_id) FROM raw.carga WHERE status = 'ok')
GROUP BY 1 ORDER BY 1;

-- 10) Integrantes x matrículas Vigente por turma (divergência a investigar)
SELECT t.turma_id, t.situacao, t.vagas_ocupadas,
       (SELECT count(*) FROM stg.integrante i WHERE i.turma_id = t.turma_id) AS integrantes,
       (SELECT count(*) FROM stg.matricula m
         WHERE m.turma_id = t.turma_id AND m.situacao = 'Vigente')          AS matriculas_vigentes
FROM stg.turma t ORDER BY t.turma_id;

-- 11) Entradas e saídas por mês (data do Sponte). Conte saídas por tipo = 'saida'.
SELECT date_trunc('month', data_negocio)::date AS mes, tipo, count(*)
FROM dw.fato_matricula_evento
WHERE tipo IN ('entrada', 'saida') GROUP BY 1, 2 ORDER BY 1, 2;

-- 12) Ocupação de uma turma ao longo do tempo (troque o número da turma)
SELECT data_ref, situacao, data_inicio, vagas_ocupadas, max_alunos
FROM dw.snapshot_turma_dia WHERE turma_id = 421 ORDER BY data_ref;

-- 13) Alunos com CPF / e-mail já preenchidos (etapa de alunos)
SELECT count(*) AS alunos, count(cpf) AS com_cpf, count(email) AS com_email FROM dw.dim_aluno;

-- 14) O que mudou entre as duas últimas cargas ok, por matrícula (só IDs e contagens).
--     Mostra transferências entre turmas (turma_antes <> turma_depois), mudanças de
--     situação, contratos novos (turma_antes = 0) e contratos que sumiram (turma_depois = 0).
WITH c AS (
    SELECT carga_id, row_number() OVER (ORDER BY carga_id DESC) AS rn
    FROM raw.carga WHERE status = 'ok'
), a AS (
    SELECT (m.payload->>'ContratoID')::int AS contrato_id, m.turma_id, m.payload->>'Situacao' AS situacao
    FROM raw.matricula m JOIN c ON c.carga_id = m.carga_id AND c.rn = 1
), b AS (
    SELECT (m.payload->>'ContratoID')::int AS contrato_id, m.turma_id, m.payload->>'Situacao' AS situacao
    FROM raw.matricula m JOIN c ON c.carga_id = m.carga_id AND c.rn = 2
)
SELECT COALESCE(b.turma_id, 0) AS turma_antes, COALESCE(a.turma_id, 0) AS turma_depois,
       b.situacao AS situacao_antes, a.situacao AS situacao_depois, count(*) AS qtd
FROM a FULL JOIN b USING (contrato_id)
WHERE a.turma_id IS DISTINCT FROM b.turma_id OR a.situacao IS DISTINCT FROM b.situacao
GROUP BY 1, 2, 3, 4 ORDER BY 1, 2;

-- 15) Os eventos da ÚLTIMA carga, sem nomes de alunos. Vem vazia (só o cabeçalho) quando a última
--     carga não encontrou nenhuma mudança. Para ver o histórico de transferências e reativações,
--     use a última consulta de qualidade_dados.sql.
SELECT tipo, contrato_id, turma_id, situacao_anterior, situacao_nova, data_negocio
FROM dw.fato_matricula_evento
WHERE carga_id = (SELECT max(carga_id) FROM raw.carga WHERE status = 'ok')
ORDER BY tipo, contrato_id;

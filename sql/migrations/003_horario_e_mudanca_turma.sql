-- =====================================================================
-- Migração 003: horário no formato "Segunda 18:00 às 22:00" e evento mudanca_turma
-- Para bancos que já têm o modelo da migração 002 / 01_schema.sql anterior.
-- Banco novo: use sql/01_schema.sql (já inclui tudo isto).
-- Rode UMA vez (é repetível sem efeitos colaterais) e depois:
--   python src/sponte_loader.py --so-processar
-- =====================================================================

BEGIN;

-- 1) horário formatado -------------------------------------------------
-- Converte o texto de horário do Sponte ("Segunda-feira- 18h às 22h") para
-- "Segunda 18:00 às 22:00". Se o texto não seguir esse padrão, devolve o original.
CREATE OR REPLACE FUNCTION stg.formatar_horario(txt text)
RETURNS text LANGUAGE sql IMMUTABLE AS $$
    SELECT CASE
        WHEN txt IS NULL OR btrim(txt) = '' THEN NULL
        WHEN x.m IS NULL THEN btrim(txt)
        ELSE (x.m)[1] || ' ' || lpad((x.m)[2], 2, '0') || ':' || COALESCE((x.m)[3], '00')
             || ' às ' || lpad((x.m)[4], 2, '0') || ':' || COALESCE((x.m)[5], '00')
    END
    FROM (SELECT regexp_match(btrim(txt),
          '^([^\s\d-]+)(?:-feira)?\s*-\s*(\d{1,2})h(\d{2})?\s+(?:às|as)\s+(\d{1,2})h(\d{2})?$') AS m) x
$$;

CREATE OR REPLACE VIEW stg.turma AS
SELECT
    ca.cod_cliente,
    ca.carga_id,
    t.turma_id,
    t.payload->>'Nome'                        AS nome,
    t.payload->>'Sigla'                       AS sigla,
    t.payload->>'Situacao'                    AS situacao,
    t.payload->>'Turno'                       AS turno,
    stg.formatar_horario(t.payload->>'Horario') AS horario,
    (t.payload->>'CursoID')::int              AS curso_id,
    t.payload->>'Curso'                       AS curso,
    stg.parse_data(t.payload->>'DataInicio')  AS data_inicio,
    stg.parse_data(t.payload->>'DataTermino') AS data_termino,
    (t.payload->>'MaxAlunos')::int            AS max_alunos,
    (t.payload->>'VagasOcupadas')::int        AS vagas_ocupadas,
    t.payload->>'ProfessorRegente'            AS professor_regente
FROM raw.turma t
JOIN stg.carga_atual ca USING (carga_id);

-- 2) evento mudanca_turma: coluna da turma anterior e novo tipo ---------
ALTER TABLE dw.fato_matricula_evento ADD COLUMN IF NOT EXISTS turma_id_anterior integer;
ALTER TABLE dw.fato_matricula_evento DROP CONSTRAINT IF EXISTS fato_matricula_evento_tipo_check;
ALTER TABLE dw.fato_matricula_evento ADD CONSTRAINT fato_matricula_evento_tipo_check
    CHECK (tipo IN ('entrada', 'saida', 'mudanca_situacao', 'mudanca_turma', 'sumiu_da_api'));

-- 3) função de processamento com a detecção de mudança de turma ----------
CREATE OR REPLACE FUNCTION dw.processar_carga(p_cod_cliente integer)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE
    v_carga   bigint;
    v_em      timestamptz;
    v_inicial boolean;
BEGIN
    SELECT carga_id, iniciada_em INTO v_carga, v_em
    FROM stg.carga_atual WHERE cod_cliente = p_cod_cliente;

    IF v_carga IS NULL THEN
        RAISE EXCEPTION 'Nenhuma carga ok para a sede %', p_cod_cliente;
    END IF;

    v_inicial := NOT EXISTS (SELECT 1 FROM dw.fato_matricula WHERE cod_cliente = p_cod_cliente);

    -- 1) dim_turma: uma linha por turma, sobrescrita a cada carga
    INSERT INTO dw.dim_turma (cod_cliente, turma_id, nome, sigla, situacao, turno, horario,
                              curso_id, curso, data_inicio, data_termino, max_alunos,
                              professor_regente)
    SELECT s.cod_cliente, s.turma_id, s.nome, s.sigla, s.situacao, s.turno, s.horario,
           s.curso_id, s.curso, s.data_inicio, s.data_termino, s.max_alunos,
           s.professor_regente
      FROM stg.turma s
     WHERE s.cod_cliente = p_cod_cliente
    ON CONFLICT (cod_cliente, turma_id) DO UPDATE SET
        nome = EXCLUDED.nome,
        sigla = EXCLUDED.sigla,
        situacao = EXCLUDED.situacao,
        turno = EXCLUDED.turno,
        horario = EXCLUDED.horario,
        curso_id = EXCLUDED.curso_id,
        curso = EXCLUDED.curso,
        data_inicio = EXCLUDED.data_inicio,
        data_termino = EXCLUDED.data_termino,
        max_alunos = EXCLUDED.max_alunos,
        professor_regente = EXCLUDED.professor_regente;

    -- 2) dim_aluno: CPF e e-mail só são trocados quando a carga trouxe valor novo
    INSERT INTO dw.dim_aluno (cod_cliente, aluno_id, nome, cpf, email,
                              primeira_carga_em, ultima_carga_em)
    SELECT DISTINCT ON (m.aluno_id)
           m.cod_cliente, m.aluno_id, COALESCE(a.nome, m.nome_aluno), a.cpf, a.email, v_em, v_em
      FROM stg.matricula m
      LEFT JOIN stg.aluno a
             ON a.cod_cliente = m.cod_cliente AND a.aluno_id = m.aluno_id
            AND a.carga_id = m.carga_id
     WHERE m.cod_cliente = p_cod_cliente
     ORDER BY m.aluno_id
    ON CONFLICT (cod_cliente, aluno_id) DO UPDATE SET
        nome = EXCLUDED.nome,
        cpf = COALESCE(EXCLUDED.cpf, dw.dim_aluno.cpf),
        email = COALESCE(EXCLUDED.email, dw.dim_aluno.email),
        ultima_carga_em = EXCLUDED.ultima_carga_em;

    -- 3) eventos (antes de atualizar fato_matricula, que guarda o estado anterior)
    -- 3a) entrada: contrato novo
    INSERT INTO dw.fato_matricula_evento
        (cod_cliente, contrato_id, turma_id, aluno_id, tipo, situacao_anterior,
         situacao_nova, data_negocio, carga_id, detectado_em, carga_inicial)
    SELECT s.cod_cliente, s.contrato_id, s.turma_id, s.aluno_id, 'entrada', NULL,
           s.situacao, s.data_matricula, v_carga, v_em, v_inicial
      FROM stg.matricula s
      LEFT JOIN dw.fato_matricula f
             ON f.cod_cliente = s.cod_cliente AND f.contrato_id = s.contrato_id
     WHERE s.cod_cliente = p_cod_cliente AND f.contrato_id IS NULL;

    -- 3b) saída: contrato novo já encerrado, ou encerramento que apareceu agora
    INSERT INTO dw.fato_matricula_evento
        (cod_cliente, contrato_id, turma_id, aluno_id, tipo, situacao_anterior,
         situacao_nova, data_negocio, carga_id, detectado_em, carga_inicial)
    SELECT s.cod_cliente, s.contrato_id, s.turma_id, s.aluno_id, 'saida', f.situacao,
           s.situacao, s.data_encerramento, v_carga, v_em, v_inicial
      FROM stg.matricula s
      LEFT JOIN dw.fato_matricula f
             ON f.cod_cliente = s.cod_cliente AND f.contrato_id = s.contrato_id
     WHERE s.cod_cliente = p_cod_cliente
       AND s.data_encerramento IS NOT NULL
       AND (f.contrato_id IS NULL OR f.data_encerramento IS NULL);

    -- 3c) mudança de situação em contrato já conhecido
    INSERT INTO dw.fato_matricula_evento
        (cod_cliente, contrato_id, turma_id, aluno_id, tipo, situacao_anterior,
         situacao_nova, data_negocio, carga_id, detectado_em, carga_inicial)
    SELECT s.cod_cliente, s.contrato_id, s.turma_id, s.aluno_id, 'mudanca_situacao',
           f.situacao, s.situacao, COALESCE(s.data_encerramento, (v_em)::date),
           v_carga, v_em, false
      FROM stg.matricula s
      JOIN dw.fato_matricula f
        ON f.cod_cliente = s.cod_cliente AND f.contrato_id = s.contrato_id
     WHERE s.cod_cliente = p_cod_cliente
       AND s.situacao_id IS DISTINCT FROM f.situacao_id;

    -- 3d) sumiu das turmas acompanhadas (contrato que não veio mais, numa turma que continua no recorte)
    INSERT INTO dw.fato_matricula_evento
        (cod_cliente, contrato_id, turma_id, aluno_id, tipo, situacao_anterior,
         situacao_nova, data_negocio, carga_id, detectado_em, carga_inicial)
    SELECT f.cod_cliente, f.contrato_id, f.turma_id, f.aluno_id, 'sumiu_da_api',
           f.situacao, NULL, (v_em)::date, v_carga, v_em, false
      FROM dw.fato_matricula f
     WHERE f.cod_cliente = p_cod_cliente AND f.ativa_na_api
       AND EXISTS (SELECT 1 FROM stg.turma t
                    WHERE t.cod_cliente = f.cod_cliente AND t.turma_id = f.turma_id)
       AND NOT EXISTS (SELECT 1 FROM stg.matricula s
                        WHERE s.cod_cliente = f.cod_cliente AND s.contrato_id = f.contrato_id);

    -- 3e) mudança de turma: contrato conhecido que passou a aparecer em outra turma
    INSERT INTO dw.fato_matricula_evento
        (cod_cliente, contrato_id, turma_id, turma_id_anterior, aluno_id, tipo,
         situacao_anterior, situacao_nova, data_negocio, carga_id, detectado_em, carga_inicial)
    SELECT s.cod_cliente, s.contrato_id, s.turma_id, f.turma_id, s.aluno_id, 'mudanca_turma',
           f.situacao, s.situacao, (v_em)::date, v_carga, v_em, false
      FROM stg.matricula s
      JOIN dw.fato_matricula f
        ON f.cod_cliente = s.cod_cliente AND f.contrato_id = s.contrato_id
     WHERE s.cod_cliente = p_cod_cliente
       AND s.turma_id <> f.turma_id;

    -- 4) estado atual das matrículas
    INSERT INTO dw.fato_matricula
        (cod_cliente, contrato_id, turma_id, aluno_id, situacao_id, situacao, numero_contrato,
         data_matricula, data_inicio, data_termino, data_encerramento,
         ativa_na_api, primeira_carga_em, ultima_carga_em)
    SELECT cod_cliente, contrato_id, turma_id, aluno_id, situacao_id, situacao, numero_contrato,
           data_matricula, data_inicio, data_termino, data_encerramento, true, v_em, v_em
      FROM stg.matricula
     WHERE cod_cliente = p_cod_cliente
    ON CONFLICT (cod_cliente, contrato_id) DO UPDATE SET
        turma_id = EXCLUDED.turma_id,
        aluno_id = EXCLUDED.aluno_id,
        situacao_id = EXCLUDED.situacao_id,
        situacao = EXCLUDED.situacao,
        numero_contrato = EXCLUDED.numero_contrato,
        data_matricula = EXCLUDED.data_matricula,
        data_inicio = EXCLUDED.data_inicio,
        data_termino = EXCLUDED.data_termino,
        data_encerramento = EXCLUDED.data_encerramento,
        ativa_na_api = true,
        ultima_carga_em = EXCLUDED.ultima_carga_em;

    UPDATE dw.fato_matricula f
       SET ativa_na_api = false
     WHERE f.cod_cliente = p_cod_cliente AND f.ativa_na_api
       AND EXISTS (SELECT 1 FROM stg.turma t
                    WHERE t.cod_cliente = f.cod_cliente AND t.turma_id = f.turma_id)
       AND NOT EXISTS (SELECT 1 FROM stg.matricula s
                        WHERE s.cod_cliente = f.cod_cliente AND s.contrato_id = f.contrato_id);

    -- 5) retrato diário (rodar duas vezes no mesmo dia sobrescreve)
    INSERT INTO dw.snapshot_turma_dia
        (cod_cliente, turma_id, data_ref, situacao, data_inicio, data_termino,
         max_alunos, vagas_ocupadas, qtd_integrantes, qtd_matriculas_vigentes)
    SELECT t.cod_cliente, t.turma_id,
           (v_em AT TIME ZONE 'America/Sao_Paulo')::date,
           t.situacao, t.data_inicio, t.data_termino, t.max_alunos, t.vagas_ocupadas,
           (SELECT count(*) FROM stg.integrante i
             WHERE i.cod_cliente = t.cod_cliente AND i.turma_id = t.turma_id),
           (SELECT count(*) FROM stg.matricula m
             WHERE m.cod_cliente = t.cod_cliente AND m.turma_id = t.turma_id
               AND m.situacao = 'Vigente')
      FROM stg.turma t
     WHERE t.cod_cliente = p_cod_cliente
    ON CONFLICT (cod_cliente, turma_id, data_ref) DO UPDATE SET
        situacao = EXCLUDED.situacao,
        data_inicio = EXCLUDED.data_inicio,
        data_termino = EXCLUDED.data_termino,
        max_alunos = EXCLUDED.max_alunos,
        vagas_ocupadas = EXCLUDED.vagas_ocupadas,
        qtd_integrantes = EXCLUDED.qtd_integrantes,
        qtd_matriculas_vigentes = EXCLUDED.qtd_matriculas_vigentes;
END;
$$;

-- 4) reconstrói, a partir do histórico em raw, as transferências que já
--    aconteceram entre cargas consecutivas e ainda não têm evento ---------
INSERT INTO dw.fato_matricula_evento
    (cod_cliente, contrato_id, turma_id, turma_id_anterior, aluno_id, tipo,
     situacao_anterior, situacao_nova, data_negocio, carga_id, detectado_em, carga_inicial)
WITH ok AS (
    SELECT carga_id, cod_cliente, iniciada_em,
           lag(carga_id) OVER (PARTITION BY cod_cliente ORDER BY carga_id) AS carga_ant
    FROM raw.carga WHERE status = 'ok'
), mt AS (
    SELECT carga_id, turma_id,
           (payload->>'ContratoID')::int AS contrato_id,
           (payload->>'AlunoID')::int    AS aluno_id,
           payload->>'Situacao'          AS situacao
    FROM raw.matricula
)
SELECT ok.cod_cliente, a.contrato_id, a.turma_id, b.turma_id, a.aluno_id, 'mudanca_turma',
       b.situacao, a.situacao, (ok.iniciada_em)::date, ok.carga_id, ok.iniciada_em, false
FROM ok
JOIN mt a ON a.carga_id = ok.carga_id
JOIN mt b ON b.carga_id = ok.carga_ant AND b.contrato_id = a.contrato_id
WHERE a.turma_id <> b.turma_id
  AND NOT EXISTS (SELECT 1 FROM dw.fato_matricula_evento e
                   WHERE e.carga_id = ok.carga_id AND e.contrato_id = a.contrato_id
                     AND e.tipo = 'mudanca_turma');

COMMIT;

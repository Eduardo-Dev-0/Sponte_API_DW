-- ---------------------------------------------------------------------
-- USO: somente para um banco criado com a versão ANTIGA do modelo (etapa 2),
-- em que dim_turma ainda tem turma_sk, ano_letivo, hash_atributos, valido_de,
-- valido_ate e atual. Em banco novo use sql/01_schema.sql.
-- Rode UMA vez. Depois: python src/sponte_loader.py --so-processar
-- ---------------------------------------------------------------------
-- =====================================================================
-- Sponte -> DW | Etapa 2b: migração (rodar UMA vez, no banco sponte_dw)
--  - dim_turma passa a ter uma linha por turma (sem histórico de versões)
--  - remove: turma_sk, ano_letivo, hash_atributos, valido_de, valido_ate, atual
--  - adiciona: dim_turma.horario, dim_aluno.cpf, dim_aluno.email
--  - snapshot_turma_dia passa a guardar data_inicio e data_termino da turma
--  - cria raw.aluno e stg.aluno (preenchidos pelo loader numa próxima etapa)
-- Mantidos de propósito: data_encerramento e ativa_na_api (ver explicação no chat)
-- =====================================================================

BEGIN;

-- 1) dim_turma: uma linha por turma -----------------------------------
DROP INDEX IF EXISTS dw.ux_dim_turma_atual;
DELETE FROM dw.dim_turma WHERE NOT atual;
ALTER TABLE dw.dim_turma DROP CONSTRAINT dim_turma_pkey;
ALTER TABLE dw.dim_turma
    DROP COLUMN turma_sk,
    DROP COLUMN ano_letivo,
    DROP COLUMN hash_atributos,
    DROP COLUMN valido_de,
    DROP COLUMN valido_ate,
    DROP COLUMN atual,
    ADD COLUMN horario text;
ALTER TABLE dw.dim_turma ADD PRIMARY KEY (cod_cliente, turma_id);

-- 2) snapshot diário: preserva as datas previstas da turma ao longo do tempo
ALTER TABLE dw.snapshot_turma_dia
    ADD COLUMN data_inicio  date,
    ADD COLUMN data_termino date;

-- 3) dim_aluno: CPF (somente dígitos, como texto) e e-mail
ALTER TABLE dw.dim_aluno
    ADD COLUMN cpf   text,
    ADD COLUMN email text;

-- 4) raw.aluno: só os campos permitidos pelo loader (AlunoID, Nome, CPF, Email)
CREATE TABLE raw.aluno (
    id       bigserial PRIMARY KEY,
    carga_id bigint  NOT NULL REFERENCES raw.carga,
    aluno_id integer NOT NULL,
    payload  jsonb   NOT NULL
);
CREATE INDEX ix_raw_aluno_carga ON raw.aluno (carga_id);

-- 5) views de stg -------------------------------------------------------
DROP VIEW IF EXISTS stg.turma;
CREATE VIEW stg.turma AS
SELECT
    ca.cod_cliente,
    ca.carga_id,
    t.turma_id,
    t.payload->>'Nome'                        AS nome,
    t.payload->>'Sigla'                       AS sigla,
    t.payload->>'Situacao'                    AS situacao,
    t.payload->>'Turno'                       AS turno,
    NULLIF(btrim(t.payload->>'Horario'), '')  AS horario,
    (t.payload->>'CursoID')::int              AS curso_id,
    t.payload->>'Curso'                       AS curso,
    stg.parse_data(t.payload->>'DataInicio')  AS data_inicio,
    stg.parse_data(t.payload->>'DataTermino') AS data_termino,
    (t.payload->>'MaxAlunos')::int            AS max_alunos,
    (t.payload->>'VagasOcupadas')::int        AS vagas_ocupadas,
    t.payload->>'ProfessorRegente'            AS professor_regente
FROM raw.turma t
JOIN stg.carga_atual ca USING (carga_id);

CREATE OR REPLACE VIEW stg.aluno AS
SELECT
    ca.cod_cliente,
    ca.carga_id,
    a.aluno_id,
    a.payload->>'Nome' AS nome,
    NULLIF(regexp_replace(coalesce(a.payload->>'CPF', ''), '\D', '', 'g'), '') AS cpf,
    NULLIF(lower(btrim(a.payload->>'Email')), '') AS email
FROM raw.aluno a
JOIN stg.carga_atual ca USING (carga_id);

-- 6) função de processamento (sem SCD2; com cpf/email e datas no snapshot) ----
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

    -- 3d) sumiu da API (só para turmas que continuam no recorte)
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

COMMIT;

-- ---------------------------------------------------------------------
-- Conferências depois da migração e de `python sponte_loader.py --so-processar`
-- ---------------------------------------------------------------------
-- Uma linha por turma (esperado: 30):
--   SELECT count(*) FROM dw.dim_turma;
-- Horário preenchido (quantas turmas, e como o Sponte escreve):
--   SELECT count(horario) AS com_horario, count(*) AS total FROM dw.dim_turma;
-- Eventos não podem duplicar ao reprocessar (esperado: 703 entrada, 253 saida):
--   SELECT tipo, carga_inicial, count(*) FROM dw.fato_matricula_evento GROUP BY 1, 2;

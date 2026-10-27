-- =====================================================================
-- Sponte -> DW (PostgreSQL) | INSTALAÇÃO DO ZERO (estado atual do modelo)
--
-- Rode este arquivo UMA vez num banco vazio (ex.: sponte_dw).
-- Bancos criados com a versão antiga (etapa 2) NÃO usam este arquivo:
-- para eles vale sql/migrations/002_simplificacao_dim_turma.sql.
--
-- Camadas: raw (JSON como veio) -> stg (views tipadas) -> dw (modelo final)
-- Escopo: turmas Vigente e Aberta, com matrículas e integrantes.
-- =====================================================================

CREATE SCHEMA IF NOT EXISTS raw;
CREATE SCHEMA IF NOT EXISTS stg;
CREATE SCHEMA IF NOT EXISTS dw;

-- ---------------------------------------------------------------------
-- RAW: uma linha por registro devolvido pela API, em JSONB
-- ---------------------------------------------------------------------
CREATE TABLE raw.carga (
    carga_id      bigserial PRIMARY KEY,
    cod_cliente   integer     NOT NULL,           -- código da sede no Sponte
    iniciada_em   timestamptz NOT NULL DEFAULT now(),
    finalizada_em timestamptz,
    status        text        NOT NULL DEFAULT 'em_andamento'
                  CHECK (status IN ('em_andamento', 'ok', 'erro')),
    observacao    text
);

-- GetTurmas2 com sParametrosBusca = 'TurmaID=<id>'
CREATE TABLE raw.turma (
    carga_id bigint  NOT NULL REFERENCES raw.carga,
    turma_id integer NOT NULL,
    payload  jsonb   NOT NULL,
    PRIMARY KEY (carga_id, turma_id)
);

-- GetMatriculas com 'TurmaID=<id>' (o loader deve descartar o campo Contratante)
CREATE TABLE raw.matricula (
    id       bigserial PRIMARY KEY,
    carga_id bigint  NOT NULL REFERENCES raw.carga,
    turma_id integer NOT NULL,
    payload  jsonb   NOT NULL
);
CREATE INDEX ix_raw_matricula_carga ON raw.matricula (carga_id);

-- GetIntegrantesTurmas com 'TurmaID=<id>' (um registro por integrante)
CREATE TABLE raw.integrante (
    id       bigserial PRIMARY KEY,
    carga_id bigint  NOT NULL REFERENCES raw.carga,
    turma_id integer NOT NULL,
    payload  jsonb   NOT NULL
);
CREATE INDEX ix_raw_integrante_carga ON raw.integrante (carga_id);


-- GetAlunos4 com 'AlunoID=<id>' (o loader grava só AlunoID, Nome, CPF e Email)
CREATE TABLE raw.aluno (
    id       bigserial PRIMARY KEY,
    carga_id bigint  NOT NULL REFERENCES raw.carga,
    aluno_id integer NOT NULL,
    payload  jsonb   NOT NULL
);
CREATE INDEX ix_raw_aluno_carga ON raw.aluno (carga_id);


-- ---------------------------------------------------------------------
-- STG: views que tipam o JSON da última carga ok de cada sede
-- ---------------------------------------------------------------------

-- Aceita ISO (2026-10-05...) ou dd/mm/aaaa (com ou sem hora).
-- ASSUMIÇÃO: o formato real ainda precisa ser confirmado com uma amostra.
CREATE OR REPLACE FUNCTION stg.parse_data(txt text)
RETURNS date LANGUAGE sql IMMUTABLE AS $$
    SELECT CASE
        WHEN txt IS NULL OR btrim(txt) = '' THEN NULL
        WHEN txt ~ '^\d{4}-\d{2}-\d{2}' THEN substr(txt, 1, 10)::date
        WHEN txt ~ '^\d{2}/\d{2}/\d{4}' THEN to_date(substr(txt, 1, 10), 'DD/MM/YYYY')
        ELSE NULL
    END
$$;

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

CREATE OR REPLACE VIEW stg.carga_atual AS
SELECT c.carga_id, c.cod_cliente, c.iniciada_em
FROM raw.carga c
WHERE c.status = 'ok'
  AND c.carga_id = (SELECT max(x.carga_id) FROM raw.carga x
                    WHERE x.status = 'ok' AND x.cod_cliente = c.cod_cliente);

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


CREATE OR REPLACE VIEW stg.matricula AS
SELECT
    ca.cod_cliente,
    ca.carga_id,
    m.turma_id,
    (m.payload->>'ContratoID')::int          AS contrato_id,
    (m.payload->>'AlunoID')::int             AS aluno_id,
    m.payload->>'Aluno'                      AS nome_aluno,
    (m.payload->>'SituacaoID')::int          AS situacao_id,
    m.payload->>'Situacao'                   AS situacao,
    m.payload->>'NumeroContrato'             AS numero_contrato,
    stg.parse_data(m.payload->>'DataMatricula')    AS data_matricula,
    stg.parse_data(m.payload->>'DataInicio')       AS data_inicio,
    stg.parse_data(m.payload->>'DataTermino')      AS data_termino,
    stg.parse_data(m.payload->>'DataEncerramento') AS data_encerramento
FROM raw.matricula m
JOIN stg.carga_atual ca USING (carga_id);

CREATE OR REPLACE VIEW stg.integrante AS
SELECT
    ca.cod_cliente,
    ca.carga_id,
    i.turma_id,
    (i.payload->>'AlunoID')::int             AS aluno_id,
    i.payload->>'NumeroChamada'              AS numero_chamada,
    i.payload->>'NumeroContrato'             AS numero_contrato,
    i.payload->>'ModulosMatriculados'        AS modulos_matriculados
FROM raw.integrante i
JOIN stg.carga_atual ca USING (carga_id);


-- ---------------------------------------------------------------------
-- DW
-- ---------------------------------------------------------------------

-- Turma: uma linha por turma, sobrescrita a cada carga.
-- O histórico de situação (Aberta -> Vigente) fica em snapshot_turma_dia.
CREATE TABLE dw.dim_turma (
    cod_cliente       integer NOT NULL,
    turma_id          integer NOT NULL,
    nome              text,
    sigla             text,
    situacao          text NOT NULL,
    turno             text,
    horario           text,
    curso_id          integer,
    curso             text,
    data_inicio       date,
    data_termino      date,
    max_alunos        integer,
    professor_regente text,
    PRIMARY KEY (cod_cliente, turma_id)
);

-- Aluno: identificação, CPF (só dígitos, como texto) e e-mail.
-- Sem RG, endereço, telefone ou credenciais do portal.
CREATE TABLE dw.dim_aluno (
    cod_cliente       integer NOT NULL,
    aluno_id          integer NOT NULL,
    nome              text,
    cpf               text,
    email             text,
    primeira_carga_em timestamptz NOT NULL,
    ultima_carga_em   timestamptz NOT NULL,
    PRIMARY KEY (cod_cliente, aluno_id)
);

-- Estado atual de cada matrícula (inclui as que saíram)
CREATE TABLE dw.fato_matricula (
    cod_cliente       integer NOT NULL,
    contrato_id       integer NOT NULL,
    turma_id          integer NOT NULL,
    aluno_id          integer NOT NULL,
    situacao_id       integer,
    situacao          text,
    numero_contrato   text,
    data_matricula    date,
    data_inicio       date,
    data_termino      date,
    data_encerramento date,
    ativa_na_api      boolean NOT NULL DEFAULT true,  -- false = sumiu da API
    primeira_carga_em timestamptz NOT NULL,
    ultima_carga_em   timestamptz NOT NULL,
    PRIMARY KEY (cod_cliente, contrato_id)
);
CREATE INDEX ix_fato_matricula_turma ON dw.fato_matricula (cod_cliente, turma_id);

-- Linha do tempo de entradas, saídas e mudanças
CREATE TABLE dw.fato_matricula_evento (
    evento_id         bigserial PRIMARY KEY,
    cod_cliente       integer NOT NULL,
    contrato_id       integer NOT NULL,
    turma_id          integer NOT NULL,
    turma_id_anterior integer,   -- preenchido só em mudanca_turma
    aluno_id          integer NOT NULL,
    tipo              text NOT NULL
                      CHECK (tipo IN ('entrada', 'saida', 'mudanca_situacao', 'mudanca_turma', 'sumiu_da_api')),
    situacao_anterior text,
    situacao_nova     text,
    data_negocio      date,         -- data que o Sponte informa (matrícula/encerramento)
    carga_id          bigint NOT NULL,
    detectado_em      timestamptz NOT NULL,
    carga_inicial     boolean NOT NULL DEFAULT false  -- true = histórico da 1ª carga
);
CREATE INDEX ix_evento_turma ON dw.fato_matricula_evento (cod_cliente, turma_id, data_negocio);

-- Retrato diário por turma (ocupação ao longo do tempo)
CREATE TABLE dw.snapshot_turma_dia (
    cod_cliente              integer NOT NULL,
    turma_id                 integer NOT NULL,
    data_ref                 date    NOT NULL,
    situacao                 text,
    data_inicio              date,
    data_termino             date,
    max_alunos               integer,
    vagas_ocupadas           integer,
    qtd_integrantes          integer,
    qtd_matriculas_vigentes  integer,
    PRIMARY KEY (cod_cliente, turma_id, data_ref)
);


-- ---------------------------------------------------------------------
-- Processamento da última carga ok de uma sede
-- ---------------------------------------------------------------------
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

-- ---------------------------------------------------------------------
-- FREQUÊNCIA (Meta 1): raw, stg e dw
-- Só contam aulas com situação "Concluída". A presença é decidida por dia:
-- falta = faltou em todas as horas do dia; parcial = faltou em parte (lançamento incorreto).
-- ---------------------------------------------------------------------

-- RAW: carga própria (não interfere na carga de cadastro) e retornos da API ----------
CREATE TABLE IF NOT EXISTS raw.carga_frequencia (
    carga_freq_id bigserial PRIMARY KEY,
    cod_cliente   integer     NOT NULL,
    iniciada_em   timestamptz NOT NULL DEFAULT now(),
    finalizada_em timestamptz,
    status        text        NOT NULL DEFAULT 'em_andamento'
                  CHECK (status IN ('em_andamento', 'ok', 'erro')),
    observacao    text
);

-- Uma linha por turma e mês consultados (mesmo quando o retorno veio vazio)
CREATE TABLE IF NOT EXISTS raw.frequencia_janela (
    carga_freq_id bigint  NOT NULL REFERENCES raw.carga_frequencia,
    turma_id      integer NOT NULL,
    mes           date    NOT NULL,          -- primeiro dia do mês
    janela_inicio date    NOT NULL,
    janela_fim    date    NOT NULL,
    n_linhas      integer NOT NULL DEFAULT 0,
    n_aulas       integer NOT NULL DEFAULT 0,
    ex_alunos     boolean NOT NULL DEFAULT false,   -- true = a consulta incluiu os alunos que já saíram da turma
    PRIMARY KEY (carga_freq_id, turma_id, mes)
);
ALTER TABLE raw.frequencia_janela ADD COLUMN IF NOT EXISTS ex_alunos boolean NOT NULL DEFAULT false;

-- GetFrequenciaTurma: uma linha por aluno e disciplina (sem NomeAluno e NomeProfessor)
CREATE TABLE IF NOT EXISTS raw.frequencia (
    id            bigserial PRIMARY KEY,
    carga_freq_id bigint  NOT NULL REFERENCES raw.carga_frequencia,
    turma_id      integer NOT NULL,
    mes           date    NOT NULL,
    disciplina_id integer NOT NULL,
    aluno_id      integer NOT NULL,
    payload       jsonb   NOT NULL
);
CREATE INDEX IF NOT EXISTS ix_raw_frequencia_janela ON raw.frequencia (carga_freq_id, turma_id, mes);

-- GetDiarioAulas: uma linha por aula de 1 hora (sem professor e conteúdo)
CREATE TABLE IF NOT EXISTS raw.diario_aula (
    id            bigserial PRIMARY KEY,
    carga_freq_id bigint  NOT NULL REFERENCES raw.carga_frequencia,
    turma_id      integer NOT NULL,
    mes           date    NOT NULL,
    disciplina_id integer NOT NULL,
    payload       jsonb   NOT NULL
);
CREATE INDEX IF NOT EXISTS ix_raw_diario_aula_janela ON raw.diario_aula (carga_freq_id, turma_id, mes);

-- STG -----------------------------------------------------------------
-- Dia da semana previsto (1 = segunda ... 7 = domingo) a partir do horário da turma
-- ("Terça 18:00 às 22:00"). NULL quando o texto traz mais de um dia ou não é reconhecido.
CREATE OR REPLACE FUNCTION stg.dia_semana_previsto(h text)
RETURNS integer LANGUAGE sql IMMUTABLE AS $$
    SELECT CASE
        WHEN h IS NULL THEN NULL
        WHEN regexp_replace(h, '\d.*$', '') ~ '(\s+e\s+|,|/)' THEN NULL
        ELSE CASE lower(substring(h from '^\s*([^\s\d-]+)'))
            WHEN 'segunda' THEN 1 WHEN 'terça' THEN 2 WHEN 'terca' THEN 2
            WHEN 'quarta' THEN 3 WHEN 'quinta' THEN 4 WHEN 'sexta' THEN 5
            WHEN 'sábado' THEN 6 WHEN 'sabado' THEN 6 WHEN 'domingo' THEN 7
        END
    END
$$;

-- Para cada turma e mês vale a consulta mais recente
CREATE OR REPLACE VIEW stg.frequencia_janela_atual AS
SELECT DISTINCT ON (c.cod_cliente, j.turma_id, j.mes)
       c.cod_cliente, j.turma_id, j.mes, j.janela_inicio, j.janela_fim, j.carga_freq_id
FROM raw.frequencia_janela j
JOIN raw.carga_frequencia c USING (carga_freq_id)
WHERE c.status = 'ok'
ORDER BY c.cod_cliente, j.turma_id, j.mes, j.carga_freq_id DESC;

CREATE OR REPLACE VIEW stg.frequencia_aluno AS
SELECT ja.cod_cliente, f.turma_id, f.mes, f.disciplina_id, f.aluno_id,
       f.payload->>'NomeDisciplina'                  AS disciplina,
       (f.payload->>'Modulo')::int                   AS modulo,
       (f.payload->>'TotalPresencas')::int           AS presencas,
       (f.payload->>'TotalFaltas')::int              AS faltas,
       f.payload->>'HorasAssistidas'                 AS horas_assistidas,
       f.payload->>'HorasFaltas'                     AS horas_faltas,
       f.payload->>'PercentualFrequencia'            AS percentual_api
FROM raw.frequencia f
JOIN stg.frequencia_janela_atual ja
  ON ja.carga_freq_id = f.carga_freq_id AND ja.turma_id = f.turma_id AND ja.mes = f.mes;

CREATE OR REPLACE VIEW stg.falta AS
SELECT ja.cod_cliente, f.turma_id, f.mes, f.disciplina_id, f.aluno_id,
       stg.parse_data(x->>'DataAula') AS data_aula
FROM raw.frequencia f
JOIN stg.frequencia_janela_atual ja
  ON ja.carga_freq_id = f.carga_freq_id AND ja.turma_id = f.turma_id AND ja.mes = f.mes
CROSS JOIN LATERAL jsonb_array_elements(
    CASE WHEN jsonb_typeof(f.payload->'Faltas') = 'array' THEN f.payload->'Faltas' ELSE '[]'::jsonb END) AS x;

CREATE OR REPLACE VIEW stg.aula AS
SELECT ja.cod_cliente, d.turma_id, d.mes, d.disciplina_id,
       stg.parse_data(d.payload->>'DataAula') AS data_aula,
       d.payload->>'Situacao'                 AS situacao,
       COALESCE((d.payload->>'Modulo')::int, m.modulo) AS modulo
FROM raw.diario_aula d
JOIN stg.frequencia_janela_atual ja
  ON ja.carga_freq_id = d.carga_freq_id AND ja.turma_id = d.turma_id AND ja.mes = d.mes
LEFT JOIN (SELECT cod_cliente, turma_id, mes, disciplina_id, max(modulo) AS modulo
             FROM stg.frequencia_aluno GROUP BY cod_cliente, turma_id, mes, disciplina_id) m
  ON m.cod_cliente = ja.cod_cliente AND m.turma_id = d.turma_id AND m.mes = d.mes
 AND m.disciplina_id = d.disciplina_id;

-- DW ------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS dw.dim_disciplina (
    cod_cliente   integer NOT NULL,
    disciplina_id integer NOT NULL,
    nome          text,
    PRIMARY KEY (cod_cliente, disciplina_id)
);

-- Totais da API por turma, mês, disciplina e aluno (só para conferência)
CREATE TABLE IF NOT EXISTS dw.fato_frequencia_janela (
    cod_cliente      integer NOT NULL,
    turma_id         integer NOT NULL,
    mes              date    NOT NULL,
    disciplina_id    integer NOT NULL,
    aluno_id         integer NOT NULL,
    presencas        integer,
    faltas           integer,
    horas_assistidas text,
    horas_faltas     text,
    percentual_api   text,
    PRIMARY KEY (cod_cliente, turma_id, mes, disciplina_id, aluno_id)
);

-- Aulas do diário por turma, disciplina e dia (cada aula = 1 hora)
CREATE TABLE IF NOT EXISTS dw.fato_aula_dia (
    cod_cliente          integer NOT NULL,
    turma_id             integer NOT NULL,
    disciplina_id        integer NOT NULL,
    data_aula            date    NOT NULL,
    aulas_total          integer NOT NULL,
    aulas_concluidas     integer NOT NULL,
    aulas_nao_concluidas integer NOT NULL,
    situacoes            text,
    modulo               integer,
    PRIMARY KEY (cod_cliente, turma_id, disciplina_id, data_aula)
);
ALTER TABLE dw.fato_aula_dia ADD COLUMN IF NOT EXISTS modulo integer;

-- Faltas por aluno, disciplina e dia (horas faltadas)
CREATE TABLE IF NOT EXISTS dw.fato_falta_dia (
    cod_cliente    integer NOT NULL,
    turma_id       integer NOT NULL,
    disciplina_id  integer NOT NULL,
    aluno_id       integer NOT NULL,
    data_aula      date    NOT NULL,
    horas_faltadas integer NOT NULL,
    PRIMARY KEY (cod_cliente, turma_id, disciplina_id, aluno_id, data_aula)
);

-- A visão que importa: presença ou falta por aluno e DIA de aula (aulas concluídas)
CREATE TABLE IF NOT EXISTS dw.fato_frequencia_dia (
    cod_cliente    integer NOT NULL,
    turma_id       integer NOT NULL,
    aluno_id       integer NOT NULL,
    data_aula      date    NOT NULL,
    aulas_dia      integer NOT NULL,   -- horas de aula concluídas no dia (todas as disciplinas do aluno)
    horas_faltadas integer NOT NULL,
    status         text    NOT NULL CHECK (status IN ('Presença', 'Falta')),
    parcial        boolean NOT NULL,   -- faltou em parte das horas: lançamento a corrigir no Sponte
    PRIMARY KEY (cod_cliente, turma_id, aluno_id, data_aula)
);

-- limite_falta_dia: fração das horas do dia faltadas a partir da qual o dia conta como Falta.
-- 1.0 = só é Falta quem faltou em todas as horas (padrão). Parcial conta como Presença.
CREATE TABLE IF NOT EXISTS dw.config_frequencia (
    id               integer PRIMARY KEY CHECK (id = 1),
    limite_falta_dia numeric NOT NULL DEFAULT 1.0 CHECK (limite_falta_dia > 0 AND limite_falta_dia <= 1)
);
INSERT INTO dw.config_frequencia (id) VALUES (1) ON CONFLICT DO NOTHING;

-- Calendário: aulas previstas (dia da semana do horário da turma) x aulas ocorridas (dias com aula concluída)
CREATE TABLE IF NOT EXISTS dw.calendario_turma_mes (
    cod_cliente                     integer NOT NULL,
    turma_id                        integer NOT NULL,
    mes                             date    NOT NULL,
    mes_parcial                     boolean NOT NULL,
    dia_previsto                    text,
    aulas_previstas                 integer,
    aulas_ocorridas                 integer NOT NULL,
    status                          text    NOT NULL,   -- igual, menos, mais, trocado, sem dia previsto
    datas_a_menos                   date[],             -- previstas sem aula concluída
    datas_a_mais                    date[],             -- aula concluída em dia não previsto
    datas_marcadas_nao_concluidas   date[],             -- entre as "a menos": há aula marcada, mas não concluída
    datas_nao_concluidas_fora_do_dia date[],            -- aula não concluída em dia não previsto
    dias_apos_termino_cadastrado    integer NOT NULL DEFAULT 0,
    PRIMARY KEY (cod_cliente, turma_id, mes)
);

CREATE OR REPLACE FUNCTION dw.processar_frequencia(p_cod_cliente integer)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE
    v_lim numeric;
BEGIN
    SELECT limite_falta_dia INTO v_lim FROM dw.config_frequencia WHERE id = 1;
    v_lim := COALESCE(v_lim, 1.0);

    -- tudo é recalculado a partir da consulta mais recente de cada turma e mês
    DELETE FROM dw.calendario_turma_mes   WHERE cod_cliente = p_cod_cliente;
    DELETE FROM dw.fato_frequencia_dia    WHERE cod_cliente = p_cod_cliente;
    DELETE FROM dw.fato_falta_dia         WHERE cod_cliente = p_cod_cliente;
    DELETE FROM dw.fato_aula_dia          WHERE cod_cliente = p_cod_cliente;
    DELETE FROM dw.fato_frequencia_janela WHERE cod_cliente = p_cod_cliente;

    INSERT INTO dw.dim_disciplina (cod_cliente, disciplina_id, nome)
    SELECT DISTINCT ON (disciplina_id) cod_cliente, disciplina_id, disciplina
      FROM stg.frequencia_aluno WHERE cod_cliente = p_cod_cliente
     ORDER BY disciplina_id, mes DESC
    ON CONFLICT (cod_cliente, disciplina_id) DO UPDATE SET nome = EXCLUDED.nome;

    INSERT INTO dw.fato_frequencia_janela
        (cod_cliente, turma_id, mes, disciplina_id, aluno_id, presencas, faltas,
         horas_assistidas, horas_faltas, percentual_api)
    SELECT cod_cliente, turma_id, mes, disciplina_id, aluno_id, presencas, faltas,
           horas_assistidas, horas_faltas, percentual_api
      FROM stg.frequencia_aluno WHERE cod_cliente = p_cod_cliente
    ON CONFLICT DO NOTHING;

    INSERT INTO dw.fato_aula_dia
        (cod_cliente, turma_id, disciplina_id, data_aula, aulas_total, aulas_concluidas,
         aulas_nao_concluidas, situacoes, modulo)
    SELECT cod_cliente, turma_id, disciplina_id, data_aula, count(*),
           count(*) FILTER (WHERE situacao = 'Concluída'),
           count(*) FILTER (WHERE situacao IS DISTINCT FROM 'Concluída'),
           string_agg(DISTINCT COALESCE(situacao, '(vazia)'), ', ' ORDER BY COALESCE(situacao, '(vazia)')),
           max(modulo)
      FROM stg.aula
     WHERE cod_cliente = p_cod_cliente AND data_aula IS NOT NULL
     GROUP BY cod_cliente, turma_id, disciplina_id, data_aula;

    INSERT INTO dw.fato_falta_dia
        (cod_cliente, turma_id, disciplina_id, aluno_id, data_aula, horas_faltadas)
    SELECT cod_cliente, turma_id, disciplina_id, aluno_id, data_aula, count(*)
      FROM stg.falta
     WHERE cod_cliente = p_cod_cliente AND data_aula IS NOT NULL
     GROUP BY cod_cliente, turma_id, disciplina_id, aluno_id, data_aula;

    -- Presença ou falta por aluno e dia (somente aulas concluídas, dentro do período da matrícula)
    INSERT INTO dw.fato_frequencia_dia
        (cod_cliente, turma_id, aluno_id, data_aula, aulas_dia, horas_faltadas, status, parcial)
    SELECT x.cod_cliente, x.turma_id, x.aluno_id, x.data_aula, x.aulas_dia, x.horas_faltadas,
           CASE WHEN x.horas_faltadas > 0 AND x.horas_faltadas >= v_lim * x.aulas_dia
                THEN 'Falta' ELSE 'Presença' END,
           (x.horas_faltadas > 0 AND x.horas_faltadas < x.aulas_dia)
      FROM (
        SELECT fj.cod_cliente, fj.turma_id, fj.aluno_id, a.data_aula,
               sum(a.aulas_concluidas)::int           AS aulas_dia,
               COALESCE(sum(f.horas_faltadas), 0)::int AS horas_faltadas
          FROM dw.fato_frequencia_janela fj
          JOIN dw.fato_aula_dia a
            ON a.cod_cliente = fj.cod_cliente AND a.turma_id = fj.turma_id
           AND a.disciplina_id = fj.disciplina_id AND a.aulas_concluidas > 0
           AND date_trunc('month', a.data_aula)::date = fj.mes
          -- período da matrícula do aluno na turma: só contam os dias entre o início e o encerramento
          LEFT JOIN (
              SELECT cod_cliente, turma_id, aluno_id, min(data_inicio) AS ini,
                     CASE WHEN bool_or(data_encerramento IS NULL) THEN NULL
                          ELSE max(data_encerramento) END AS fim
                FROM dw.fato_matricula WHERE cod_cliente = p_cod_cliente
               GROUP BY cod_cliente, turma_id, aluno_id
          ) mb ON mb.cod_cliente = fj.cod_cliente AND mb.turma_id = fj.turma_id AND mb.aluno_id = fj.aluno_id
          LEFT JOIN dw.fato_falta_dia f
            ON f.cod_cliente = a.cod_cliente AND f.turma_id = a.turma_id
           AND f.disciplina_id = a.disciplina_id AND f.aluno_id = fj.aluno_id
           AND f.data_aula = a.data_aula
         WHERE fj.cod_cliente = p_cod_cliente
           AND (mb.ini IS NULL OR a.data_aula >= mb.ini)
           AND (mb.fim IS NULL OR a.data_aula <= mb.fim)
         GROUP BY fj.cod_cliente, fj.turma_id, fj.aluno_id, a.data_aula
      ) x;

    -- Calendário por turma e mês
    INSERT INTO dw.calendario_turma_mes
        (cod_cliente, turma_id, mes, mes_parcial, dia_previsto, aulas_previstas, aulas_ocorridas,
         status, datas_a_menos, datas_a_mais, datas_marcadas_nao_concluidas,
         datas_nao_concluidas_fora_do_dia, dias_apos_termino_cadastrado)
    WITH dias AS (
        SELECT cod_cliente, turma_id, date_trunc('month', data_aula)::date AS mes,
               array_agg(data_aula ORDER BY data_aula) FILTER (WHERE aulas_conc > 0)  AS dias_real,
               array_agg(data_aula ORDER BY data_aula) FILTER (WHERE aulas_conc = 0)  AS dias_nc
          FROM (SELECT cod_cliente, turma_id, data_aula, sum(aulas_concluidas) AS aulas_conc
                  FROM dw.fato_aula_dia WHERE cod_cliente = p_cod_cliente
                 GROUP BY cod_cliente, turma_id, data_aula) d
         GROUP BY cod_cliente, turma_id, date_trunc('month', data_aula)::date
    ), j AS (
        SELECT ja.cod_cliente, ja.turma_id, ja.mes, ja.janela_fim, t.data_inicio, t.data_termino,
               stg.dia_semana_previsto(t.horario)    AS isodow,
               COALESCE(d.dias_real, '{}'::date[])   AS dias_real,
               COALESCE(d.dias_nc,   '{}'::date[])   AS dias_nc
          FROM stg.frequencia_janela_atual ja
          JOIN dw.dim_turma t ON t.cod_cliente = ja.cod_cliente AND t.turma_id = ja.turma_id
          LEFT JOIN dias d ON d.cod_cliente = ja.cod_cliente AND d.turma_id = ja.turma_id AND d.mes = ja.mes
         WHERE ja.cod_cliente = p_cod_cliente
    ), p AS (
        -- dias previstos: dia da semana do horário, do início da turma ao fim da janela. Se o término
        -- cadastrado já passou mas ainda há aula concluída, o período vai até a última aula.
        SELECT j.*,
               CASE WHEN j.isodow IS NULL THEN NULL ELSE ARRAY(
                   SELECT g::date
                     FROM generate_series(
                              greatest(j.mes, COALESCE(j.data_inicio, j.mes))::timestamp,
                              (CASE WHEN j.data_termino IS NOT NULL AND j.data_termino < j.janela_fim
                                    THEN least(j.janela_fim, greatest(j.data_termino,
                                         COALESCE((SELECT max(x) FROM unnest(j.dias_real) x), j.data_termino)))
                                    ELSE j.janela_fim END)::timestamp,
                              interval '1 day') g
                    WHERE extract(isodow FROM g) = j.isodow
                    ORDER BY 1) END AS dias_prev
          FROM j
    ), c AS (
        SELECT p.*,
               ARRAY(SELECT unnest(p.dias_prev) EXCEPT SELECT unnest(p.dias_real) ORDER BY 1) AS a_menos,
               ARRAY(SELECT unnest(p.dias_real) EXCEPT SELECT unnest(p.dias_prev) ORDER BY 1) AS a_mais
          FROM p
    )
    SELECT c.cod_cliente, c.turma_id, c.mes,
           (c.janela_fim < (c.mes + interval '1 month' - interval '1 day')::date),
           (ARRAY['Segunda','Terça','Quarta','Quinta','Sexta','Sábado','Domingo'])[c.isodow],
           cardinality(c.dias_prev),
           cardinality(c.dias_real),
           CASE WHEN c.dias_prev IS NULL THEN 'sem dia previsto'
                WHEN cardinality(c.a_menos) = 0 AND cardinality(c.a_mais) = 0 THEN 'igual'
                WHEN cardinality(c.a_mais) = 0 THEN 'menos'
                WHEN cardinality(c.a_menos) = 0 THEN 'mais'
                ELSE 'trocado' END,
           CASE WHEN c.dias_prev IS NULL THEN NULL ELSE c.a_menos END,
           CASE WHEN c.dias_prev IS NULL THEN NULL ELSE c.a_mais END,
           ARRAY(SELECT unnest(c.dias_nc) INTERSECT SELECT unnest(c.a_menos) ORDER BY 1),
           CASE WHEN c.dias_prev IS NULL THEN NULL
                ELSE ARRAY(SELECT unnest(c.dias_nc) EXCEPT SELECT unnest(c.dias_prev) ORDER BY 1) END,
           (SELECT count(*) FROM unnest(c.dias_real) d
             WHERE c.data_termino IS NOT NULL AND d > c.data_termino)::int
      FROM c;
END;
$$;

-- ---------------------------------------------------------------------
-- SEDES: nome de cada código de cliente do Sponte (para os relatórios mostrarem "Bezerra" e não o código)
-- Cadastro manual, uma vez por sede:
--   INSERT INTO dw.sede (cod_cliente, nome) VALUES (<código do cliente>, 'Bezerra')
--   ON CONFLICT (cod_cliente) DO UPDATE SET nome = EXCLUDED.nome;
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS dw.sede (
    cod_cliente integer PRIMARY KEY,
    nome        text    NOT NULL
);

-- ---------------------------------------------------------------------
-- Conferências depois da primeira carga: sql/consultas/validacoes.sql
-- ---------------------------------------------------------------------

-- =====================================================================
-- Migração 005: tabela de sedes (nome de cada código de cliente). Repetível.
-- Banco novo: use sql/01_schema.sql (já inclui). Depois rode sql/02_views_bi.sql.
-- =====================================================================

BEGIN;

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

COMMIT;

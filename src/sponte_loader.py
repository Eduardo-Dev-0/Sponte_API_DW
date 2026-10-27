"""
Etapa 3: carga Sponte -> PostgreSQL (raw) e processamento (dw).

Uso:
    python src/sponte_loader.py                 # coleta da API + grava raw + processa dw
    python src/sponte_loader.py --so-processar  # reprocessa a última carga ok (sem chamar a API)
    python src/sponte_loader.py --atualizar-alunos  # consulta CPF/e-mail de TODOS os alunos do recorte

Dependências: pip install zeep python-dotenv psycopg2-binary
Variáveis no .env: SPONTE_COD_CLIENTE, SPONTE_TOKEN,
                   PG_HOST, PG_PORT (opcional), PG_DB, PG_USER, PG_PASSWORD
"""
import json
import math
import os
import sys
import time
import unicodedata
from datetime import datetime, timezone

import psycopg2
from dotenv import load_dotenv
from psycopg2.extras import Json, execute_values
from zeep import Client
from zeep.helpers import serialize_object

load_dotenv()

WSDL = "https://api.sponteeducacional.net.br/WSAPIEdu.asmx?WSDL"
COD = int(os.environ["SPONTE_COD_CLIENTE"])
TOKEN = os.environ["SPONTE_TOKEN"]

SITUACOES = {"vigente", "aberta"}  # recorte de interesse (comparação sem acento/caixa)

# Campos descartados antes de gravar no raw (minimização de dados pessoais e de volume).
DESCARTAR_MATRICULA = ("Contratante", "Disciplinas", "DisciplinasComTurma")
DESCARTAR_INTEGRANTE = ("Disciplinas",)

# Alunos: só estes campos do GetAlunos4 são gravados. O retorno traz também RG,
# endereço, telefones, LoginPortal e SenhaPortal, que NUNCA devem entrar no banco.
CAMPOS_ALUNO = ("AlunoID", "Nome", "CPF", "Email")
DIAS_ALTERADOS = (1, 7, 15, 30)  # janelas aceitas pelo GetAlunosAlterados

PAUSA = 0.2  # segundos entre chamadas


def norm(s):
    s = unicodedata.normalize("NFKD", str(s or ""))
    return s.encode("ascii", "ignore").decode().strip().lower()


def dumps(o):
    return json.dumps(o, ensure_ascii=False, default=str)


def limpar(d, chaves):
    return {k: v for k, v in d.items() if k not in chaves}


def conectar():
    return psycopg2.connect(
        host=os.environ["PG_HOST"],
        port=os.environ.get("PG_PORT", "5432"),
        dbname=os.environ["PG_DB"],
        user=os.environ["PG_USER"],
        password=os.environ["PG_PASSWORD"],
    )


def chamar(client, op, tid, tentativas=3):
    """Chama um método do Sponte filtrando por TurmaID, com novas tentativas."""
    for n in range(1, tentativas + 1):
        try:
            r = getattr(client.service, op)(
                nCodigoCliente=COD, sToken=TOKEN, sParametrosBusca=f"TurmaID={tid}"
            )
            time.sleep(PAUSA)
            return serialize_object(r) or []
        except Exception:
            if n == tentativas:
                raise
            time.sleep(2 * n)


def coletar(client, previas):
    """Retorna as turmas do recorte com matrículas e integrantes.

    `previas` = turmas que estavam no recorte na carga anterior. Elas são coletadas
    mais uma vez mesmo que a situação tenha mudado (ex.: Vigente -> Concluida),
    para o DW registrar o estado final antes de a turma sair do recorte.
    """
    r = serialize_object(
        client.service.GetModalidadeDasTurmas(
            nCodigoCliente=COD, sToken=TOKEN, sParametrosBusca=""
        )
    )
    ids = sorted({t["TurmaID"] for t in r[0]["ModalidadesTurmas"]["ModalidadeTurma"]})
    print(f"{len(ids)} turmas na base")

    turmas, matriculas, integrantes, falhas = [], [], [], []
    for tid in ids:
        d = chamar(client, "GetTurmas2", tid)
        t = d[0] if d else {}
        if not str(t.get("RetornoOperacao", "")).startswith("01"):
            falhas.append((tid, "GetTurmas2", t.get("RetornoOperacao")))
            continue
        if norm(t.get("Situacao")) not in SITUACOES and tid not in previas:
            continue

        turmas.append(t)
        vagas = t.get("VagasOcupadas") or 0

        m = [x for x in chamar(client, "GetMatriculas", tid) if x.get("AlunoID")]
        if vagas > 0 and not m:
            falhas.append((tid, "GetMatriculas", "turma com vagas ocupadas e 0 matrículas"))
        matriculas += [(tid, limpar(x, DESCARTAR_MATRICULA)) for x in m]

        i_raw = chamar(client, "GetIntegrantesTurmas", tid)
        ints = []
        if i_raw and i_raw[0].get("Integrantes"):
            ints = i_raw[0]["Integrantes"].get("Integrantes") or []
        if vagas > 0 and not ints:
            falhas.append((tid, "GetIntegrantesTurmas", "turma com vagas ocupadas e 0 integrantes"))
        integrantes += [(tid, limpar(x, DESCARTAR_INTEGRANTE)) for x in ints]

        print(f"  turma {tid} [{t.get('Situacao')}]: {len(m)} matrículas, {len(ints)} integrantes")

    return {"turmas": turmas, "matriculas": matriculas,
            "integrantes": integrantes, "falhas": falhas}


def chamar_aluno(client, aluno_id, tentativas=3):
    """GetAlunos4 filtrando por AlunoID (não existe filtro por turma), com novas tentativas."""
    for n in range(1, tentativas + 1):
        try:
            r = client.service.GetAlunos4(
                nCodigoCliente=COD, sToken=TOKEN, sParametrosBusca=f"AlunoID={aluno_id}"
            )
            time.sleep(PAUSA)
            return serialize_object(r) or []
        except Exception:
            if n == tentativas:
                raise
            time.sleep(2 * n)


def alunos_alterados(client, dias):
    r = serialize_object(
        client.service.GetAlunosAlterados(
            nCodigoCliente=COD, sToken=TOKEN, nQtdDias=str(dias)
        )
    )
    item = (r[0] if isinstance(r, list) and r else r) or {}
    return {int(i) for i in str(item.get("Alunos") or "").split(";") if i.strip().isdigit()}


def escolher_alunos(client, ids, ja_buscados, ultima_busca, completo):
    """Decide quais alunos consultar: os nunca consultados e os alterados desde a última consulta."""
    if completo:
        return set(ids), "atualização completa pedida"
    novos = set(ids) - ja_buscados
    alvo, motivo = set(novos), f"{len(novos)} nunca consultados"
    if ja_buscados and ultima_busca is not None:
        horas = (datetime.now(timezone.utc) - ultima_busca).total_seconds() / 3600
        dias = max(1, math.ceil(horas / 24))
        janela = next((d for d in DIAS_ALTERADOS if d >= dias), None)
        if janela is None:
            return set(ids), f"última consulta há mais de {DIAS_ALTERADOS[-1]} dias: atualização completa"
        alterados = alunos_alterados(client, janela) & set(ids)
        alvo |= alterados
        motivo += f" + {len(alterados)} alterados nos últimos {janela} dias"
    return alvo, motivo


def coletar_alunos(client, dados, ja_buscados, ultima_busca, completo):
    ids = sorted({x["AlunoID"] for _, x in dados["matriculas"] if x.get("AlunoID")})
    alvo, motivo = escolher_alunos(client, ids, ja_buscados, ultima_busca, completo)
    print(f"\nAlunos no recorte: {len(ids)} | a consultar: {len(alvo)} ({motivo})")
    alunos, sem_retorno = [], []
    for n, aid in enumerate(sorted(alvo), 1):
        d = chamar_aluno(client, aid)
        item = next((x for x in d if x.get("AlunoID") == aid), None)
        if item is None:
            sem_retorno.append(aid)
        else:
            alunos.append({k: item.get(k) for k in CAMPOS_ALUNO})
        if n % 100 == 0:
            print(f"  {n}/{len(alvo)} alunos consultados")
    dados["alunos"] = alunos
    if sem_retorno:
        print(f"  aviso: {len(sem_retorno)} alunos sem retorno no GetAlunos4 "
              f"(primeiros ids: {sem_retorno[:10]})")


def marcar(conn, carga_id, status, obs):
    with conn, conn.cursor() as cur:
        cur.execute(
            "UPDATE raw.carga SET status = %s, finalizada_em = now(), observacao = %s "
            "WHERE carga_id = %s",
            (status, obs[:2000], carga_id),
        )


def gravar_raw(cur, carga_id, dados):
    execute_values(
        cur,
        "INSERT INTO raw.turma (carga_id, turma_id, payload) VALUES %s",
        [(carga_id, t["TurmaID"], Json(t, dumps=dumps)) for t in dados["turmas"]],
    )
    if dados["matriculas"]:
        execute_values(
            cur,
            "INSERT INTO raw.matricula (carga_id, turma_id, payload) VALUES %s",
            [(carga_id, tid, Json(x, dumps=dumps)) for tid, x in dados["matriculas"]],
            page_size=500,
        )
    if dados["integrantes"]:
        execute_values(
            cur,
            "INSERT INTO raw.integrante (carga_id, turma_id, payload) VALUES %s",
            [(carga_id, tid, Json(x, dumps=dumps)) for tid, x in dados["integrantes"]],
            page_size=500,
        )
    if dados.get("alunos"):
        execute_values(
            cur,
            "INSERT INTO raw.aluno (carga_id, aluno_id, payload) VALUES %s",
            [(carga_id, x["AlunoID"], Json(x, dumps=dumps)) for x in dados["alunos"]],
            page_size=500,
        )


def executar_carga(conn, completo=False):
    # 1) abre a carga e lê as turmas que já estavam no recorte
    with conn, conn.cursor() as cur:
        cur.execute("INSERT INTO raw.carga (cod_cliente) VALUES (%s) RETURNING carga_id", (COD,))
        carga_id = cur.fetchone()[0]
        cur.execute(
            "SELECT turma_id FROM dw.dim_turma "
            "WHERE cod_cliente = %s AND lower(situacao) IN ('vigente', 'aberta')",
            (COD,),
        )
        previas = {r[0] for r in cur.fetchall()}
        # alunos já consultados em cargas ok anteriores e quando foi a última consulta
        cur.execute(
            "SELECT DISTINCT a.aluno_id FROM raw.aluno a JOIN raw.carga c USING (carga_id) "
            "WHERE c.cod_cliente = %s AND c.status = 'ok'",
            (COD,),
        )
        ja_buscados = {r[0] for r in cur.fetchall()}
        cur.execute(
            "SELECT max(c.iniciada_em) FROM raw.carga c "
            "WHERE c.cod_cliente = %s AND c.status = 'ok' "
            "AND EXISTS (SELECT 1 FROM raw.aluno a WHERE a.carga_id = c.carga_id)",
            (COD,),
        )
        ultima_busca = cur.fetchone()[0]
    print(f"Carga {carga_id} aberta | turmas já acompanhadas: {len(previas)}")

    # 2) coleta na API (fora de transação de banco)
    try:
        client = Client(WSDL)
        dados = coletar(client, previas)
        dados["alunos"] = []
        if dados["turmas"] and not dados["falhas"]:  # com falha a carga será abortada: poupa chamadas
            coletar_alunos(client, dados, ja_buscados, ultima_busca, completo)
    except Exception as e:
        marcar(conn, carga_id, "erro", f"{type(e).__name__}: {e}")
        raise

    # Qualquer falha aborta: carga parcial geraria eventos falsos de 'sumiu_da_api'.
    if dados["falhas"] or not dados["turmas"]:
        msg = f"falhas={dados['falhas'][:10]} turmas={len(dados['turmas'])}"
        marcar(conn, carga_id, "erro", msg)
        raise SystemExit(f"Carga abortada, nada foi processado: {msg}")

    # 3) grava o raw e fecha a carga como ok na mesma transação
    with conn, conn.cursor() as cur:
        gravar_raw(cur, carga_id, dados)
        cur.execute(
            "UPDATE raw.carga SET status = 'ok', finalizada_em = now(), observacao = %s "
            "WHERE carga_id = %s",
            (f"turmas={len(dados['turmas'])} matriculas={len(dados['matriculas'])} "
             f"integrantes={len(dados['integrantes'])} alunos={len(dados['alunos'])}", carga_id),
        )
    print(f"raw gravado: {len(dados['turmas'])} turmas, {len(dados['matriculas'])} matrículas, "
          f"{len(dados['integrantes'])} integrantes, {len(dados['alunos'])} alunos consultados")


def processar(conn):
    with conn, conn.cursor() as cur:
        cur.execute("SELECT dw.processar_carga(%s)", (COD,))
    with conn, conn.cursor() as cur:
        cur.execute(
            "SELECT tipo, carga_inicial, count(*) FROM dw.fato_matricula_evento "
            "WHERE carga_id = (SELECT carga_id FROM stg.carga_atual WHERE cod_cliente = %s) "
            "GROUP BY 1, 2 ORDER BY 1, 2",
            (COD,),
        )
        print("\nEventos desta carga (tipo | carga_inicial | quantidade):")
        for tipo, inicial, qtd in cur.fetchall():
            print(f"  {tipo} | {inicial} | {qtd}")


def main():
    conn = conectar()
    try:
        if "--so-processar" not in sys.argv:
            executar_carga(conn, completo="--atualizar-alunos" in sys.argv)
        processar(conn)
    finally:
        conn.close()


if __name__ == "__main__":
    main()

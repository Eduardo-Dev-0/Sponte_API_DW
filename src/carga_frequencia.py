"""
Carga de frequência: GetFrequenciaTurma e GetDiarioAulas, por turma e por mês -> raw -> dw.

Uso:
    python src/carga_frequencia.py                   # meses ainda não carregados + os 2 últimos meses
    python src/carga_frequencia.py --recarregar 3    # recarrega os 3 últimos meses
    python src/carga_frequencia.py --completa        # recarrega todos os meses desde o início das turmas
    python src/carga_frequencia.py --turma 436       # só uma turma
    python src/carga_frequencia.py --so-processar    # recalcula o dw com o que já está no raw (sem API)

Regras:
  * Turmas Vigente, mais as que tiveram aula nos últimos 45 dias (para fechar o último mês depois que
    deixam de ser Vigente).
  * Janela = um mês de calendário (o mês corrente vai até ontem). Cada mês é independente: se uma
    consulta falhar, as outras são gravadas e a que falhou é tentada de novo na próxima carga.
  * Cada turma é carregada desde a primeira aula: começa um mês antes do início cadastrado da turma (ou
    da primeira matrícula, o que for mais cedo) e, se o mês mais antigo tiver aula, volta mais um mês, até
    achar um mês sem aula (máximo de 2024-01).
  * Meses fechados são consultados uma vez. São reconsultados a cada carga: os 2 últimos meses E qualquer
    mês, nos últimos 120 dias, que ainda tenha aula não concluída ou dia de falta parcial (o acadêmico
    conclui aulas e corrige faltas depois). Alteração em mês antigo e sem pendência só entra com
    --completa, que vale rodar de tempos em tempos (por exemplo, uma vez por semana).
  * Alunos que já saíram da turma: a consulta normal só devolve quem está na turma agora. Para cada mês, os
    alunos com matrícula naquele mês que não vieram na resposta são pedidos um a um (AlunoID=), para que a
    frequência de quem passou pela turma continue contando no mês em que estava matriculado. Janelas
    consultadas sem isso (cargas antigas) são reconsultadas uma vez. --sem-ex-alunos desliga esse passo.
  * Só ficam no raw os campos necessários: sem nome de aluno, nome de professor ou conteúdo de aula.
"""
import sys
import time
from datetime import date, timedelta

from psycopg2.extras import Json, execute_values
from zeep import Client
from zeep.helpers import serialize_object

from sponte_loader import COD, TOKEN, WSDL, conectar, dumps

PAUSA = 0.2
RECARGA_PADRAO = 2   # meses recentes reconsultados a cada carga
PENDENCIA_DIAS = 120   # meses com pendência (aula não concluída, falta parcial) nesse período são reconsultados
LIMITE_HISTORICO = date(2024, 1, 1)   # não volta além deste mês ao procurar a primeira aula

CAMPOS_FREQ = ("TotalPresencas", "TotalFaltas", "HorasAssistidas", "HorasFaltas", "PercentualFrequencia")
CAMPOS_FALTA = ("DataAula", "HorarioInicial", "HorarioFinal", "DuracaoAula")
CAMPOS_DISC = ("Modulo", "NomeDisciplina", "ProfessorID", "CHTotal", "NumeroAulas")
CAMPOS_AULA = ("DiarioClasseID", "NumeroAula", "DataAula", "HorarioInicial", "HorarioFinal",
               "ProfessorID", "Situacao")


def lista(x):
    """Os retornos aninhados vêm como {'nome_do_elemento': [..]}; devolve só a lista."""
    if not x:
        return []
    if isinstance(x, list):
        return x
    if isinstance(x, dict):
        for v in x.values():
            if isinstance(v, list):
                return v
    return []


def primeiro_dia(d):
    return d.replace(day=1)


def proximo_mes(d):
    return (d.replace(day=28) + timedelta(days=4)).replace(day=1)


def com_retentativas(fn, tentativas=3):
    for n in range(1, tentativas + 1):
        try:
            r = fn()
            time.sleep(PAUSA)
            return serialize_object(r) or []
        except Exception:
            if n == tentativas:
                raise
            time.sleep(2 * n)


def ler_turmas(cur, so_turma):
    cur.execute(
        "SELECT t.turma_id, LEAST(t.data_inicio, (SELECT min(m.data_inicio) FROM dw.fato_matricula m "
        "    WHERE m.cod_cliente = t.cod_cliente AND m.turma_id = t.turma_id)) AS inicio FROM dw.dim_turma t "
        "WHERE t.cod_cliente = %s AND (lower(t.situacao) = 'vigente' OR t.turma_id IN ("
        "    SELECT turma_id FROM dw.fato_aula_dia WHERE cod_cliente = %s AND data_aula >= current_date - 45)) "
        "ORDER BY t.turma_id", (COD, COD))
    return [dict(turma_id=r[0], data_inicio=r[1]) for r in cur.fetchall() if so_turma in (None, r[0])]


def janelas_a_consultar(cur, turmas, hoje, recarregar, completa, mais_antigo):
    cur.execute(
        "SELECT j.turma_id, j.mes FROM raw.frequencia_janela j "
        "JOIN raw.carga_frequencia c USING (carga_freq_id) WHERE c.cod_cliente = %s AND c.status = 'ok' "
        "AND j.ex_alunos", (COD,))
    ja = {(r[0], r[1]) for r in cur.fetchall()}
    # meses com pendência recente: a correção feita no Sponte só aparece se o mês for reconsultado
    cur.execute(
        "SELECT turma_id, date_trunc('month', data_aula)::date FROM dw.fato_aula_dia "
        "WHERE cod_cliente = %s AND aulas_nao_concluidas > 0 AND data_aula < current_date "
        "  AND data_aula >= current_date - %s "
        "UNION SELECT turma_id, date_trunc('month', data_aula)::date FROM dw.fato_frequencia_dia "
        "WHERE cod_cliente = %s AND parcial AND data_aula >= current_date - %s",
        (COD, PENDENCIA_DIAS, COD, PENDENCIA_DIAS))
    pendentes = {(r[0], r[1]) for r in cur.fetchall()}
    mes_atual = primeiro_dia(hoje)
    recentes = set()
    m = mes_atual
    for _ in range(recarregar):
        recentes.add(m)
        m = primeiro_dia(m - timedelta(days=1))
    out = []
    for t in turmas:
        m = (primeiro_dia(primeiro_dia(t["data_inicio"]) - timedelta(days=1)) if t["data_inicio"]
             else primeiro_dia(hoje - timedelta(days=120)))
        if t["turma_id"] in mais_antigo:   # os meses mais antigos achados em cargas anteriores fazem parte do histórico
            m = min(m, mais_antigo[t["turma_id"]][0])
        while m <= mes_atual:
            fim = min(proximo_mes(m) - timedelta(days=1), hoje - timedelta(days=1))
            if fim >= m and (completa or m in recentes or (t["turma_id"], m) in pendentes
                             or (t["turma_id"], m) not in ja):
                out.append((t["turma_id"], m, fim))
            m = proximo_mes(m)
    return out


def _ler_resposta(resp, tid, mes, linhas, discs):
    """Acrescenta em 'linhas' os alunos da resposta do GetFrequenciaTurma e guarda as disciplinas em 'discs'."""
    alunos = set()
    for turma in resp:
        for d in lista(turma.get("Disciplinas")):
            did = d.get("DisciplinaID")
            if did is None:
                continue
            discs[did] = d
            base = {k: d.get(k) for k in CAMPOS_DISC}
            base["DisciplinaID"] = did
            for a in lista(d.get("Alunos")):
                if a.get("AlunoID") is None:
                    continue
                payload = dict(base)
                payload.update({k: a.get(k) for k in CAMPOS_FREQ})
                payload["AlunoID"] = a.get("AlunoID")
                payload["Faltas"] = [{k: f.get(k) for k in CAMPOS_FALTA} for f in lista(a.get("Faltas"))]
                linhas.append((tid, mes, did, a.get("AlunoID"), payload))
                alunos.add(a.get("AlunoID"))
    return alunos


def buscar_janela(client, tid, mes, fim, candidatos=()):
    """Frequência do mês (todas as disciplinas) e as aulas do diário de cada disciplina.

    Devolve (linhas, aulas, pedidos, retornados). `candidatos` são os alunos com matrícula no mês; os que não
    vieram na consulta normal (já saíram da turma) são pedidos um a um.
    """
    janela = f"Data={mes:%Y/%m/%d} e {fim:%Y/%m/%d}"
    resp = com_retentativas(lambda: client.service.GetFrequenciaTurma(
        nCodigoCliente=COD, sToken=TOKEN, nTurmaID=tid, sParametrosBusca=janela))
    linhas, discs = [], {}
    presentes = _ler_resposta(resp, tid, mes, linhas, discs)
    pedidos = retornados = 0
    for aid in sorted(set(candidatos) - presentes):
        pedidos += 1
        r = com_retentativas(lambda: client.service.GetFrequenciaTurma(
            nCodigoCliente=COD, sToken=TOKEN, nTurmaID=tid, sParametrosBusca=f"AlunoID={aid};{janela}"))
        if aid in _ler_resposta(r, tid, mes, linhas, discs):
            retornados += 1
    aulas = []
    for did, d in discs.items():
        r = com_retentativas(lambda: client.service.GetDiarioAulas(
            nCodigoCliente=COD, sToken=TOKEN, nTurmaID=tid, nDisciplinaID=did,
            dDataInicio=f"{mes:%Y/%m/%d}", dDataTermino=f"{fim:%Y/%m/%d}",
            nModulo=d.get("Modulo") or 1, sSemana=""))
        for item in r:
            for x in lista(item.get("AulasDiario")):
                p = {k: x.get(k) for k in CAMPOS_AULA}
                p["Modulo"] = d.get("Modulo")
                aulas.append((tid, mes, did, p))
    return linhas, aulas, pedidos, retornados


def ler_matriculas(cur, turmas):
    """Por turma: (aluno, início, encerramento) de todas as matrículas, inclusive as que já saíram."""
    cur.execute(
        "SELECT turma_id, aluno_id, min(data_inicio), "
        "       CASE WHEN bool_or(data_encerramento IS NULL) THEN NULL ELSE max(data_encerramento) END "
        "FROM dw.fato_matricula WHERE cod_cliente = %s AND turma_id = ANY(%s) GROUP BY turma_id, aluno_id",
        (COD, [t["turma_id"] for t in turmas]))
    out = {}
    for tid, aid, ini, enc in cur.fetchall():
        out.setdefault(tid, []).append((aid, ini, enc))
    return out


def candidatos(matr, tid, mes, fim):
    """Alunos com matrícula ativa em algum dia de [mes, fim]."""
    return [aid for aid, ini, enc in matr.get(tid, []) if (ini is None or ini <= fim) and (enc is None or enc >= mes)]


def processar(conn):
    with conn, conn.cursor() as cur:
        cur.execute("SELECT dw.processar_frequencia(%s)", (COD,))
    with conn, conn.cursor() as cur:
        cur.execute("SELECT count(*), count(*) FILTER (WHERE parcial), count(*) FILTER (WHERE status = 'Falta') "
                    "FROM dw.fato_frequencia_dia WHERE cod_cliente = %s", (COD,))
        dias, parciais, faltas = cur.fetchone()
        cur.execute("SELECT status, count(*) FROM dw.calendario_turma_mes WHERE cod_cliente = %s "
                    "GROUP BY 1 ORDER BY 1", (COD,))
        cal = dict(cur.fetchall())
    print(f"\ndw processado: {dias} aluno-dias ({faltas} faltas, {parciais} dias parciais a corrigir no Sponte)")
    print(f"calendário turma-mês por status: {cal}")


def main(argv):
    conn = conectar()
    try:
        if "--so-processar" not in argv:
            coletar_e_gravar(conn, argv)
        processar(conn)
    finally:
        conn.close()


def coletar_e_gravar(conn, argv):
    so_turma = int(argv[argv.index("--turma") + 1]) if "--turma" in argv else None
    recarregar = int(argv[argv.index("--recarregar") + 1]) if "--recarregar" in argv else RECARGA_PADRAO
    completa = "--completa" in argv
    sem_ex = "--sem-ex-alunos" in argv
    hoje = date.today()

    with conn, conn.cursor() as cur:
        turmas = ler_turmas(cur, so_turma)
        matr = {} if sem_ex else ler_matriculas(cur, turmas)
        cur.execute("SELECT DISTINCT ON (j.turma_id) j.turma_id, j.mes, j.n_aulas FROM raw.frequencia_janela j "
                    "JOIN raw.carga_frequencia c USING (carga_freq_id) "
                    "WHERE c.cod_cliente = %s AND c.status = 'ok' "
                    "ORDER BY j.turma_id, j.mes, j.carga_freq_id DESC", (COD,))
        mais_antigo = {r[0]: (r[1], r[2]) for r in cur.fetchall()}   # mês mais antigo já consultado e nº de aulas
        janelas = janelas_a_consultar(cur, turmas, hoje, recarregar, completa, mais_antigo)
        cur.execute("INSERT INTO raw.carga_frequencia (cod_cliente) VALUES (%s) RETURNING carga_freq_id", (COD,))
        carga_id = cur.fetchone()[0]
    print(f"Carga de frequência {carga_id} | {len(turmas)} turmas | {len(janelas)} turma-mês a consultar")

    client = Client(WSDL)
    j_rows, f_rows, a_rows, falhas = [], [], [], []
    ex_pedidos = ex_retornados = 0
    for n, (tid, mes, fim) in enumerate(janelas, 1):
        try:
            linhas, aulas, ped, ret = buscar_janela(client, tid, mes, fim, candidatos(matr, tid, mes, fim))
            ex_pedidos += ped
            ex_retornados += ret
        except Exception as e:
            falhas.append((tid, f"{mes:%Y-%m}", f"{type(e).__name__}: {e}"[:150]))
            print(f"  turma {tid} {mes:%Y-%m}: ERRO {type(e).__name__}")
            continue
        j_rows.append((carga_id, tid, mes, mes, fim, len(linhas), len(aulas), not sem_ex))
        f_rows += [(carga_id, t, m, d, a, Json(p, dumps=dumps)) for t, m, d, a, p in linhas]
        a_rows += [(carga_id, t, m, d, Json(p, dumps=dumps)) for t, m, d, p in aulas]
        if n % 20 == 0 or n == len(janelas):
            print(f"  {n}/{len(janelas)} turma-mês consultados")

    # Histórico completo: se o mês mais antigo conhecido da turma tem aula, volta mais um mês, até achar um vazio
    for _, tid, mes, _i, _f, _nl, n_aulas, _ex in j_rows:
        if tid not in mais_antigo or mes < mais_antigo[tid][0]:
            mais_antigo[tid] = (mes, n_aulas)
    for t in turmas:
        tid = t["turma_id"]
        mes_ant, n = mais_antigo.get(tid, (None, 0))
        while mes_ant and n > 0 and mes_ant > LIMITE_HISTORICO:
            mes_ant = primeiro_dia(mes_ant - timedelta(days=1))
            fim_ant = proximo_mes(mes_ant) - timedelta(days=1)
            try:
                linhas, aulas, ped, ret = buscar_janela(client, tid, mes_ant, fim_ant,
                                                        candidatos(matr, tid, mes_ant, fim_ant))
                ex_pedidos += ped
                ex_retornados += ret
            except Exception as e:
                falhas.append((tid, f"{mes_ant:%Y-%m}", f"{type(e).__name__}: {e}"[:150]))
                break
            j_rows.append((carga_id, tid, mes_ant, mes_ant, fim_ant, len(linhas), len(aulas), not sem_ex))
            f_rows += [(carga_id, t_, m_, d_, a_, Json(p_, dumps=dumps)) for t_, m_, d_, a_, p_ in linhas]
            a_rows += [(carga_id, t_, m_, d_, Json(p_, dumps=dumps)) for t_, m_, d_, p_ in aulas]
            n = len(aulas)
            print(f"  turma {tid}: histórico estendido até {mes_ant:%Y-%m} ({n} aulas no diário)")

    with conn, conn.cursor() as cur:
        if j_rows:
            execute_values(cur, "INSERT INTO raw.frequencia_janela (carga_freq_id, turma_id, mes, janela_inicio, "
                                "janela_fim, n_linhas, n_aulas, ex_alunos) VALUES %s", j_rows)
        if f_rows:
            execute_values(cur, "INSERT INTO raw.frequencia (carga_freq_id, turma_id, mes, disciplina_id, aluno_id, "
                                "payload) VALUES %s", f_rows, page_size=500)
        if a_rows:
            execute_values(cur, "INSERT INTO raw.diario_aula (carga_freq_id, turma_id, mes, disciplina_id, "
                                "payload) VALUES %s", a_rows, page_size=500)
        ok = bool(j_rows) or not janelas
        cur.execute("UPDATE raw.carga_frequencia SET status = %s, finalizada_em = now(), observacao = %s "
                    "WHERE carga_freq_id = %s",
                    ("ok" if ok else "erro",
                     f"janelas={len(j_rows)} linhas={len(f_rows)} aulas={len(a_rows)} falhas={falhas[:10]}", carga_id))
    print(f"raw gravado: {len(j_rows)} turma-mês, {len(f_rows)} linhas de aluno, {len(a_rows)} aulas")
    if ex_pedidos:
        print(f"alunos que já saíram da turma: {ex_pedidos} consultas, {ex_retornados} com frequência devolvida pela API")
        if ex_retornados == 0:
            print("AVISO: a API não devolveu a frequência de nenhum aluno que saiu da turma pelo filtro AlunoID. "
                  "Rode src/sonda_ex_alunos.py e envie a saída. Para não repetir essas consultas, use --sem-ex-alunos.")
    if falhas:
        print(f"AVISO: {len(falhas)} turma-mês falharam e serão tentados de novo na próxima carga: {falhas[:5]}")
    if janelas and not j_rows:
        raise SystemExit("Nenhuma consulta funcionou; nada foi processado.")


if __name__ == "__main__":
    main(sys.argv[1:])

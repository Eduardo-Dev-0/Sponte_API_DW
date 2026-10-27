"""
Auditoria de frequência (somente leitura). Não imprime nomes de alunos nem de professores.

Para cada turma Vigente e cada mês, confere:
  1) CALENDÁRIO: os dias com aula CONCLUÍDA batem com os dias previstos (dia da semana do horário)?
       menos  = dia previsto sem aula concluída (provável feriado ou evento; ou aula só "marcada")
       mais   = aula concluída em dia que não era previsto (investigar)
       trocado= falta em um dia previsto e sobra em outro (aula movida de dia)
  2) HORAS DO DIA: horas de aula concluídas por dia (linhas do diário) x o previsto.
  3) SITUAÇÃO: aulas que não estão "Concluída" e já passaram (diário sem fechamento? aula não realizada?).
  4) REGRA DO DIA: por aluno e dia de aula, o aluno tem presença, falta em todas as horas ou falta PARCIAL?

Uso:  python src/auditoria_frequencia.py                 (últimos 3 meses, o atual até ontem)
      python src/auditoria_frequencia.py --meses 6
      python src/auditoria_frequencia.py --turma 436
Saídas (pasta data/, ignorada pelo Git):
      auditoria_calendario.csv   uma linha por turma e mês
      auditoria_parciais.csv     um registro por dia de falta parcial (turma, disciplina, AlunoID, data)
"""
import csv
import os
import re
import sys
import time
from collections import Counter
from datetime import date, datetime, timedelta
from pathlib import Path

import psycopg2
from dotenv import load_dotenv
from zeep import Client
from zeep.helpers import serialize_object

load_dotenv()
WSDL = "https://api.sponteeducacional.net.br/WSAPIEdu.asmx?WSDL"
COD = int(os.environ["SPONTE_COD_CLIENTE"])
TOKEN = os.environ["SPONTE_TOKEN"]
ROOT = Path(__file__).resolve().parent.parent
PAUSA = 0.2

DIAS = {"segunda": 0, "terça": 1, "terca": 1, "quarta": 2, "quinta": 3, "sexta": 4,
        "sábado": 5, "sabado": 5, "domingo": 6}
NOME_DIA = ["Segunda", "Terça", "Quarta", "Quinta", "Sexta", "Sábado", "Domingo"]


def criar_cliente():
    return Client(WSDL)


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


def data_br(s):
    try:
        return datetime.strptime(str(s)[:10], "%d/%m/%Y").date()
    except ValueError:
        return None


def hhmm(s):
    return str(s or "")[:5]


def dia_previsto(horario):
    """'Terça 18:00 às 22:00' -> 1 (terça). None se não houver um único dia claro."""
    if not horario:
        return None
    cabeca = re.split(r"\d", horario)[0]
    if re.search(r"\s+e\s+|,|/", cabeca):
        return None   # mais de um dia no texto
    m = re.match(r"^\s*([^\s\d-]+)", horario)
    return DIAS.get(m.group(1).lower().replace("-feira", "")) if m else None


def horas_previstas(horario):
    m = re.search(r"(\d{1,2}):(\d{2})\s+às\s+(\d{1,2}):(\d{2})", horario or "")
    if not m:
        return None
    a, b = int(m[1]) * 60 + int(m[2]), int(m[3]) * 60 + int(m[4])
    return round((b - a) / 60) if b > a else None


def intervalo(a, b):
    d = a
    while d <= b:
        yield d
        d += timedelta(days=1)


def meses(n):
    """Os n meses mais recentes (o atual vai só até ontem). Devolve (início, fim, parcial)."""
    hoje = date.today()
    ref = hoje.replace(day=1)
    out = []
    for _ in range(n):
        prox = (ref.replace(day=28) + timedelta(days=4)).replace(day=1)
        fim_mes = prox - timedelta(days=1)
        fim = min(fim_mes, hoje - timedelta(days=1))
        if fim >= ref:
            out.append((ref, fim, fim_mes > fim))
        ref = (ref - timedelta(days=1)).replace(day=1)
    return list(reversed(out))


def ler_turmas(so_turma):
    conn = psycopg2.connect(
        host=os.environ["PG_HOST"], port=os.environ.get("PG_PORT", "5432"),
        dbname=os.environ["PG_DB"], user=os.environ["PG_USER"], password=os.environ["PG_PASSWORD"],
    )
    cur = conn.cursor()
    cur.execute(
        "SELECT turma_id, horario, data_inicio, data_termino FROM dw.dim_turma "
        "WHERE cod_cliente = %s AND lower(situacao) = 'vigente' ORDER BY turma_id", (COD,))
    rows = [dict(turma_id=r[0], horario=r[1], data_inicio=r[2], data_termino=r[3]) for r in cur.fetchall()]
    conn.close()
    return [t for t in rows if so_turma in (None, t["turma_id"])]


def auditar(client, t, ini, fim, parcial, parciais_out):
    tid, horario = t["turma_id"], t["horario"]
    wd, hp = dia_previsto(horario), horas_previstas(horario)

    filtro = f"Data={ini:%Y/%m/%d} e {fim:%Y/%m/%d}"
    resp = serialize_object(client.service.GetFrequenciaTurma(
        nCodigoCliente=COD, sToken=TOKEN, nTurmaID=tid, sParametrosBusca=filtro)) or []
    time.sleep(PAUSA)
    discs, alunos_por_disc = {}, {}
    for turma in resp:
        for d in lista(turma.get("Disciplinas")):
            discs[d.get("DisciplinaID")] = d
            alunos_por_disc[d.get("DisciplinaID")] = [
                (a.get("AlunoID"), lista(a.get("Faltas"))) for a in lista(d.get("Alunos"))]

    aulas_all = []   # (disciplina, data, horário inicial, situação)
    for did, d in discs.items():
        r = serialize_object(client.service.GetDiarioAulas(
            nCodigoCliente=COD, sToken=TOKEN, nTurmaID=tid, nDisciplinaID=did,
            dDataInicio=f"{ini:%Y/%m/%d}", dDataTermino=f"{fim:%Y/%m/%d}",
            nModulo=d.get("Modulo") or 1, sSemana="")) or []
        time.sleep(PAUSA)
        for item in r:
            for x in lista(item.get("AulasDiario")):
                aulas_all.append((did, data_br(x.get("DataAula")), hhmm(x.get("HorarioInicial")), x.get("Situacao")))
    aulas_all = [a for a in aulas_all if a[1]]

    # Cada linha do diário é 1 hora de aula. O horário inicial se repete entre as horas do mesmo dia,
    # então as horas do dia são contadas por linhas, nunca por horário.
    horas_conc = Counter(a[1] for a in aulas_all if a[3] == "Concluída")
    dias_real = set(horas_conc)                       # dias com ao menos uma aula Concluída
    datas_todas = {a[1] for a in aulas_all}
    dias_marcados = datas_todas - dias_real           # só aulas não concluídas
    conc_por_dia, nc_por_dia = {}, {}
    for did, dia, _, sit in aulas_all:
        (conc_por_dia if sit == "Concluída" else nc_por_dia).setdefault(dia, set()).add(did)
    nc_coincide = sum(1 for dia, ds in nc_por_dia.items() if conc_por_dia.get(dia) and (ds - conc_por_dia[dia]))
    multi = sum(1 for ds in conc_por_dia.values() if len(ds) > 1)
    situ = Counter(a[3] for a in aulas_all)
    nc_passadas = sum(1 for a in aulas_all if a[3] != "Concluída" and a[1] < date.today())

    # Dias previstos: dia da semana do horário, entre o início da turma e o fim do mês. Se o término
    # cadastrado já passou mas ainda há aula, o período vai até a última aula (e fica sinalizado).
    ini_e = max(ini, t["data_inicio"] or ini)
    fim_e = fim
    if t["data_termino"] and t["data_termino"] < fim:
        fim_e = min(fim, max(t["data_termino"], max(dias_real)) if dias_real else t["data_termino"])
    apos_termino = sum(1 for d in dias_real if t["data_termino"] and d > t["data_termino"])
    esperadas = [d for d in intervalo(ini_e, fim_e) if d.weekday() == wd] if wd is not None else None

    if esperadas is None:
        sem_registro = marcada_nc = fora = fora_nc = []
        status = "sem dia previsto"
    else:
        esp = set(esperadas)
        sem_aula = [d for d in esperadas if d not in dias_real]
        sem_registro = [d for d in sem_aula if d not in datas_todas]       # nenhuma aula no diário
        marcada_nc = [d for d in sem_aula if d in datas_todas]             # aula marcada, nenhuma concluída
        fora = sorted(d for d in dias_real if d not in esp)                # aula concluída em dia não previsto
        fora_nc = sorted(d for d in dias_marcados if d not in esp)         # aula não concluída em dia não previsto
        status = ("igual" if not sem_aula and not fora else
                  "menos" if sem_aula and not fora else
                  "mais" if fora and not sem_aula else "trocado")
    horas_diferentes = sum(1 for n in horas_conc.values() if hp is not None and n != hp)

    # regra do dia, por disciplina: presença, falta em todas as horas ou parcial
    pres = falta = parc = fora_conc = 0
    for did, alunos in alunos_por_disc.items():
        n_dia = Counter(a[1] for a in aulas_all if a[0] == did and a[3] == "Concluída")
        for aluno_id, faltas in alunos:
            fa = Counter(data_br(x.get("DataAula")) for x in faltas)
            for dia, n in n_dia.items():
                k = fa.get(dia, 0)
                if k == 0:
                    pres += 1
                elif k >= n:
                    falta += 1
                else:
                    parc += 1
                    parciais_out.append(dict(turma_id=tid, mes=f"{ini:%Y-%m}", disciplina_id=did,
                                             aluno_id=aluno_id, data=dia, horas_faltadas=k, horas_do_dia=n))
            fora_conc += sum(v for dia, v in fa.items() if dia not in n_dia)

    lst = lambda xs: " ".join(map(str, xs))
    return dict(
        turma_id=tid, mes=f"{ini:%Y-%m}", mes_parcial="sim" if parcial else "não",
        horario=horario, dia_previsto=NOME_DIA[wd] if wd is not None else "", horas_previstas=hp or "",
        data_termino_cadastro=t["data_termino"] or "",
        dias_previstos=len(esperadas) if esperadas is not None else "",
        dias_realizados=len(dias_real), dias_marcados_nao_concluidos=len(dias_marcados), status=status,
        datas_sem_registro=lst(sem_registro), datas_marcadas_nao_concluidas=lst(marcada_nc),
        datas_fora_do_dia=lst(fora), datas_nao_concluidas_fora_do_dia=lst(fora_nc),
        dias_realizados_apos_data_termino=apos_termino,
        aulas_total=len(aulas_all), aulas_concluidas=situ.get("Concluída", 0),
        aulas_confirmadas=situ.get("Confirmada", 0),
        aulas_outras=len(aulas_all) - situ.get("Concluída", 0) - situ.get("Confirmada", 0),
        aulas_nao_concluidas_passadas=nc_passadas,
        horas_concluidas_por_dia=" ".join(f"{k.day:02d}={v}" for k, v in sorted(horas_conc.items())),
        dias_com_horas_diferentes_do_previsto=horas_diferentes,
        dias_com_mais_de_uma_disciplina_concluida=multi,
        dias_nao_concluidos_junto_de_concluida_de_outra_disciplina=nc_coincide,
        aluno_dia_presenca=pres, aluno_dia_falta=falta, aluno_dia_parcial=parc,
        faltas_em_dia_sem_aula_concluida=fora_conc,
    )


def main(argv):
    n_meses = int(argv[argv.index("--meses") + 1]) if "--meses" in argv else 3
    so_turma = int(argv[argv.index("--turma") + 1]) if "--turma" in argv else None
    turmas = ler_turmas(so_turma)
    janelas = meses(n_meses)
    print(f"{len(turmas)} turmas Vigente | meses: {[f'{j[0]:%Y-%m}' for j in janelas]} (o atual vai até ontem)")
    client = criar_cliente()

    linhas, parciais = [], []
    for ini, fim, parcial in janelas:
        for t in turmas:
            if t["data_inicio"] and t["data_inicio"] > fim:
                continue
            try:
                r = auditar(client, t, ini, fim, parcial, parciais)
            except Exception as e:
                r = dict(turma_id=t["turma_id"], mes=f"{ini:%Y-%m}", status=f"erro: {type(e).__name__}: {e}"[:120])
            linhas.append(r)
            print(f"turma {r['turma_id']} | {r['mes']}{'*' if parcial else ''} | {r.get('dia_previsto') or '?'} "
                  f"| previstos {r.get('dias_previstos', '-')} | realizados {r.get('dias_realizados', '-')} "
                  f"| marcados sem conclusão {r.get('dias_marcados_nao_concluidos', '-')} | {r['status']}"
                  f"{' | parciais ' + str(r['aluno_dia_parcial']) if r.get('aluno_dia_parcial') else ''}"
                  f"{' | aula após o término cadastrado' if r.get('dias_realizados_apos_data_termino') else ''}")

    (ROOT / "data").mkdir(exist_ok=True)
    campos = list(next((l for l in linhas if "dias_realizados" in l), {"turma_id": 0, "mes": 0, "status": 0}).keys())
    with open(ROOT / "data" / "auditoria_calendario.csv", "w", newline="", encoding="utf-8-sig") as f:
        w = csv.DictWriter(f, fieldnames=campos, delimiter=";", extrasaction="ignore", restval="")
        w.writeheader()
        w.writerows(linhas)
    with open(ROOT / "data" / "auditoria_parciais.csv", "w", newline="", encoding="utf-8-sig") as f:
        w = csv.DictWriter(f, fieldnames=["turma_id", "mes", "disciplina_id", "aluno_id", "data",
                                          "horas_faltadas", "horas_do_dia"], delimiter=";")
        w.writeheader()
        w.writerows(parciais)

    ok = [l for l in linhas if "dias_realizados" in l]
    print("\n=== RESUMO ===")
    print("turma-mês por status:", dict(Counter(l["status"] for l in linhas)))
    print(f"aulas não concluídas que já passaram: {sum(l['aulas_nao_concluidas_passadas'] for l in ok)} "
          f"em {sum(1 for l in ok if l['aulas_nao_concluidas_passadas'])} turma-mês")
    print(f"dias com horas concluídas diferentes do previsto: {sum(l['dias_com_horas_diferentes_do_previsto'] for l in ok)} "
          f"| dias com mais de uma disciplina concluída: {sum(l['dias_com_mais_de_uma_disciplina_concluida'] for l in ok)} "
          f"| dias com aula não concluída junto de aula concluída de outra disciplina: "
          f"{sum(l['dias_nao_concluidos_junto_de_concluida_de_outra_disciplina'] for l in ok)}")
    print(f"dias realizados depois do término cadastrado da turma: "
          f"{sum(l['dias_realizados_apos_data_termino'] for l in ok)} "
          f"(turmas: {sorted({l['turma_id'] for l in ok if l['dias_realizados_apos_data_termino']})})")
    print(f"aluno x dia: presença={sum(l['aluno_dia_presenca'] for l in ok)} | "
          f"falta em todas as horas={sum(l['aluno_dia_falta'] for l in ok)} | "
          f"falta PARCIAL={sum(l['aluno_dia_parcial'] for l in ok)} | "
          f"faltas em dia sem aula concluída={sum(l['faltas_em_dia_sem_aula_concluida'] for l in ok)}")
    for l in ok:
        if l["status"] not in ("igual", "sem dia previsto"):
            print(f"  turma {l['turma_id']} {l['mes']} [{l['status']}] previstos={l['dias_previstos']} realizados={l['dias_realizados']}"
                  f" | sem registro: {l['datas_sem_registro'] or '-'} | marcada e não concluída: {l['datas_marcadas_nao_concluidas'] or '-'}"
                  f" | concluída em dia não previsto: {l['datas_fora_do_dia'] or '-'}")
    print("\nArquivos: data\\auditoria_calendario.csv e data\\auditoria_parciais.csv")


if __name__ == "__main__":
    main(sys.argv[1:])

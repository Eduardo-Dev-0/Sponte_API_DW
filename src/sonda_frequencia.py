"""
Sonda de frequência (somente leitura). Nunca imprime nomes de alunos ou professores.

Responde, para UMA turma Vigente:
  1) Como vêm os dados do GetFrequenciaTurma (campos, formatos de horas e percentual)?
  2) As faltas listadas fecham com os totais? O percentual é por aula ou por hora?
  3) Os totais de uma janela de 2 meses = soma de duas janelas de 1 mês? (decide se podemos
     guardar a frequência em janelas mensais e somar depois por turma, aluno ou curso)
  4) O que o diário de aulas (GetDiarioAulas) acrescenta: situação da aula e quantidade de aulas.

Uso:  python src/sonda_frequencia.py              (escolhe uma turma sozinha)
      python src/sonda_frequencia.py --turma 437  (turma específica)
Requer o .env do loader (SPONTE_* e PG_*) e ao menos uma carga ok no banco.
"""
import os
import re
import sys
from collections import Counter
from datetime import date, datetime, timedelta

import psycopg2
from dotenv import load_dotenv
from zeep import Client
from zeep.helpers import serialize_object

load_dotenv()
WSDL = "https://api.sponteeducacional.net.br/WSAPIEdu.asmx?WSDL"
COD = int(os.environ["SPONTE_COD_CLIENTE"])
TOKEN = os.environ["SPONTE_TOKEN"]


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


def num(s):
    """Converte '12:30', '85,71', '1.234,50' ou '85.71%' em número; None se não der."""
    if s is None:
        return None
    t = str(s).strip().replace("%", "").strip()
    if re.fullmatch(r"\d+:\d{2}", t):
        h, m = t.split(":")
        return int(h) + int(m) / 60
    if "," in t:
        t = t.replace(".", "").replace(",", ".")
    try:
        return float(t)
    except ValueError:
        return None


def data_br(s):
    try:
        return datetime.strptime(str(s)[:10], "%d/%m/%Y").date()
    except ValueError:
        return None


def escolher_turma(argv):
    if "--turma" in argv:
        return int(argv[argv.index("--turma") + 1])
    conn = psycopg2.connect(
        host=os.environ["PG_HOST"], port=os.environ.get("PG_PORT", "5432"),
        dbname=os.environ["PG_DB"], user=os.environ["PG_USER"], password=os.environ["PG_PASSWORD"],
    )
    cur = conn.cursor()
    cur.execute(
        "SELECT t.turma_id FROM dw.dim_turma t "
        "JOIN dw.fato_matricula f ON f.cod_cliente = t.cod_cliente AND f.turma_id = t.turma_id "
        "                        AND f.ativa_na_api "
        "WHERE lower(t.situacao) = 'vigente' AND t.data_inicio <= current_date - 75 "
        "GROUP BY t.turma_id HAVING count(*) FILTER (WHERE f.situacao = 'Vigente') >= 3 "
        "ORDER BY count(*) FILTER (WHERE f.situacao = 'Vigente'), t.turma_id LIMIT 1"
    )
    row = cur.fetchone()
    conn.close()
    if not row:
        raise SystemExit("Nenhuma turma Vigente com início há mais de 75 dias. Use --turma <id>.")
    return row[0]


def main(argv):
    client = criar_cliente()
    tid = escolher_turma(argv)

    hoje = date.today()
    fim_m1 = hoje.replace(day=1) - timedelta(days=1)   # último dia do mês passado
    ini_m1 = fim_m1.replace(day=1)
    fim_m2 = ini_m1 - timedelta(days=1)                # mês retrasado
    ini_m2 = fim_m2.replace(day=1)
    jan = lambda a, b: f"Data={a:%Y/%m/%d} e {b:%Y/%m/%d}"
    print(f"Turma de teste: {tid} | hoje: {hoje}")
    print(f"Janelas: m2={ini_m2}..{fim_m2} | m1={ini_m1}..{fim_m1} | 2 meses={ini_m2}..{fim_m1}")

    def freq(filtro):
        r = client.service.GetFrequenciaTurma(
            nCodigoCliente=COD, sToken=TOKEN, nTurmaID=tid, sParametrosBusca=filtro)
        return serialize_object(r) or []

    def achatar(resp):
        linhas = []
        for turma in resp:
            for disc in lista(turma.get("Disciplinas")):
                for al in lista(disc.get("Alunos")):
                    linhas.append((disc, al, lista(al.get("Faltas"))))
        return linhas

    def resumir(rotulo, filtro):
        resp = freq(filtro)
        linhas = achatar(resp)
        ret = resp[0].get("RetornoOperacao") if resp and isinstance(resp[0], dict) else None
        print(f"\n[{rotulo}] filtro={filtro!r} | retorno={ret!r}")
        if not linhas:
            print("   sem linhas de aluno")
            return {"linhas": {}, "disc": {}, "raw": []}
        discs = {}
        for d, _, _ in linhas:
            discs[d.get("DisciplinaID")] = d
        pres = sum(a.get("TotalPresencas") or 0 for _, a, _ in linhas)
        falt = sum(a.get("TotalFaltas") or 0 for _, a, _ in linhas)
        n_falt_lista = sum(len(f) for _, _, f in linhas)
        diverg = sum(1 for _, a, f in linhas if len(f) != (a.get("TotalFaltas") or 0))
        alunos = {a.get("AlunoID") for _, a, _ in linhas}
        print(f"   disciplinas={len(discs)} | alunos distintos={len(alunos)} | linhas aluno x disciplina={len(linhas)}")
        print(f"   soma TotalPresencas={pres} | soma TotalFaltas={falt} | faltas listadas={n_falt_lista} "
              f"| linhas em que a lista de faltas difere de TotalFaltas={diverg}")
        # formatos (3 exemplos, sem identificar ninguém)
        ex = [(a.get("HorasAssistidas"), a.get("HorasFaltas"), a.get("PercentualFrequencia")) for _, a, _ in linhas[:3]]
        print(f"   exemplos (HorasAssistidas, HorasFaltas, PercentualFrequencia): {ex}")
        ok_aulas = ok_horas = testadas = 0
        for _, a, _ in linhas:
            p, f_ = a.get("TotalPresencas") or 0, a.get("TotalFaltas") or 0
            pct = num(a.get("PercentualFrequencia"))
            ha, hf = num(a.get("HorasAssistidas")), num(a.get("HorasFaltas"))
            if pct is None or (p + f_) == 0:
                continue
            testadas += 1
            if abs(100 * p / (p + f_) - pct) <= 0.6:
                ok_aulas += 1
            if ha is not None and hf is not None and (ha + hf) > 0 and abs(100 * ha / (ha + hf) - pct) <= 0.6:
                ok_horas += 1
        print(f"   percentual confere com presenças/(presenças+faltas): {ok_aulas}/{testadas} "
              f"| com horas assistidas/(assistidas+faltas): {ok_horas}/{testadas}")
        datas = [data_br(x.get("DataAula")) for _, _, f in linhas for x in f]
        datas = [d for d in datas if d]
        if datas:
            print(f"   datas das faltas: {min(datas)} a {max(datas)} | formato de exemplo: "
                  f"{[x.get('DataAula') for _, _, f in linhas for x in f][:1]}")
        combos = Counter((x.get("HorarioInicial"), x.get("HorarioFinal"), x.get("DuracaoAula"))
                         for _, _, f in linhas for x in f)
        if combos:
            print(f"   faixas de horário das faltas (início, fim, duração): {dict(combos.most_common(5))}")
        for did, d in list(discs.items())[:5]:
            n_al = sum(1 for dd, _, _ in linhas if dd.get("DisciplinaID") == did)
            print(f"   disciplina {did} | módulo {d.get('Modulo')} | NumeroAulas={d.get('NumeroAulas')} "
                  f"| CHTotal={d.get('CHTotal')} | alunos={n_al}")
        chaves = {(d.get("DisciplinaID"), a.get("AlunoID")): (a.get("TotalPresencas") or 0, a.get("TotalFaltas") or 0)
                  for d, a, _ in linhas}
        return {"linhas": chaves, "disc": discs, "pres": pres, "falt": falt, "raw": linhas}

    a = resumir("A: sem filtro de data (a doc diz: últimos 30 dias)", "")
    m1 = resumir("B1: mês passado", jan(ini_m1, fim_m1))
    m2 = resumir("B2: mês retrasado", jan(ini_m2, fim_m2))
    c = resumir("C: os dois meses de uma vez", jan(ini_m2, fim_m1))

    print("\n[Aditividade] os totais da janela de 2 meses = soma das duas janelas de 1 mês?")
    if c["linhas"]:
        igual_p = igual_f = 0
        chaves = set(c["linhas"]) | set(m1["linhas"]) | set(m2["linhas"])
        for k in chaves:
            p1, f1 = m1["linhas"].get(k, (0, 0))
            p2, f2 = m2["linhas"].get(k, (0, 0))
            pc, fc = c["linhas"].get(k, (0, 0))
            igual_p += (pc == p1 + p2)
            igual_f += (fc == f1 + f2)
        print(f"   presenças: {c.get('pres')} (2 meses) x {m1.get('pres', 0) + m2.get('pres', 0)} (soma)"
              f" | faltas: {c.get('falt')} x {m1.get('falt', 0) + m2.get('falt', 0)}")
        print(f"   linhas aluno x disciplina que fecham: presenças {igual_p}/{len(chaves)} | faltas {igual_f}/{len(chaves)}")
    else:
        print("   janela de 2 meses sem dados; escolha outra turma com --turma")

    # Diário de aulas do mês passado, até 3 disciplinas (período máximo da API: 60 dias)
    print("\n[Diário de aulas] GetDiarioAulas no mês passado")
    diario_mes = {}
    for did, d in list(m1["disc"].items())[:3]:
        try:
            r = serialize_object(client.service.GetDiarioAulas(
                nCodigoCliente=COD, sToken=TOKEN, nTurmaID=tid, nDisciplinaID=did,
                dDataInicio=f"{ini_m1:%Y/%m/%d}", dDataTermino=f"{fim_m1:%Y/%m/%d}",
                nModulo=d.get("Modulo") or 1, sSemana="")) or []
        except Exception as e:
            print(f"   disciplina {did}: ERRO {type(e).__name__}: {e}")
            continue
        aulas = [x for item in r for x in lista(item.get("AulasDiario"))]
        diario_mes[did] = aulas
        ret = r[0].get("RetornoOperacao") if r and isinstance(r[0], dict) else None
        situ = Counter(x.get("Situacao") for x in aulas)
        print(f"   disciplina {did}: retorno={ret!r} | aulas no diário={len(aulas)} | NumeroAulas na frequência="
              f"{d.get('NumeroAulas')} | situações das aulas={dict(situ)}")
        # faltas desta disciplina no mesmo mês, por (data, horário inicial)
        fk = Counter((data_br(x.get("DataAula")), str(x.get("HorarioInicial") or "")[:5])
                     for dd, _, f in m1["raw"] if dd.get("DisciplinaID") == did for x in f)
        por_sit, usadas = {}, set()
        for x in aulas:
            k = (data_br(x.get("DataAula")), str(x.get("HorarioInicial") or "")[:5])
            usadas.add(k)
            st = por_sit.setdefault(x.get("Situacao"), {"aulas": 0, "aulas_com_falta": 0, "faltas": 0, "datas": []})
            n = fk.get(k, 0)
            st["aulas"] += 1
            st["aulas_com_falta"] += 1 if n > 0 else 0
            st["faltas"] += n
            st["datas"].append(k[0])
        for st in por_sit.values():
            ds = [x for x in st.pop("datas") if x]
            st["datas"] = f"{min(ds)}..{max(ds)}" if ds else None
        sem_aula = sum(v for k, v in fk.items() if k not in usadas)
        print(f"      por situação da aula: {por_sit}")
        print(f"      faltas sem aula correspondente (data + horário inicial): {sem_aula}/{sum(fk.values())}")
        nc_datas = sorted({data_br(x.get("DataAula")) for x in aulas if x.get("Situacao") != "Concluída"} - {None})
        print(f"      datas das aulas que NÃO estão Concluída: {[str(x) for x in nc_datas]}")

        # Teste da regra do dia: por aluno e por dia de aula (Concluída), faltou em todas as horas, em nenhuma ou em parte?
        conc = [x for x in aulas if x.get("Situacao") == "Concluída"]
        n_dia = Counter(data_br(x.get("DataAula")) for x in conc)
        alunos_disc = [(al, f) for dd, al, f in m1["raw"] if dd.get("DisciplinaID") == did]
        pres = falta = parc = 0
        formas_parc = Counter()
        for al, f in alunos_disc:
            fa = Counter(data_br(x.get("DataAula")) for x in f)
            for dia, n in n_dia.items():
                k = fa.get(dia, 0)
                if k == 0:
                    pres += 1
                elif k >= n:
                    falta += 1
                else:
                    parc += 1
                    formas_parc[f"{k} de {n} horas"] += 1
        fora = sum(1 for _, f in alunos_disc for x in f if data_br(x.get("DataAula")) not in n_dia)
        print(f"      dias de aula Concluída: {len(n_dia)} (horas por dia: {dict(Counter(n_dia.values()))})")
        print(f"      aluno x dia: presença={pres} | falta em todas as horas={falta} | falta PARCIAL={parc} "
              f"{dict(formas_parc)} | faltas em dias sem aula Concluída={fora}")

    # Aulas não concluídas que ocupam o mesmo dia e horário de uma aula concluída de OUTRA disciplina
    ocupado = {}
    for did, aulas in diario_mes.items():
        for x in aulas:
            if x.get("Situacao") == "Concluída":
                ocupado.setdefault((data_br(x.get("DataAula")), str(x.get("HorarioInicial") or "")[:5]), set()).add(did)
    total_nc = coincide = 0
    for did, aulas in diario_mes.items():
        for x in aulas:
            if x.get("Situacao") != "Concluída":
                total_nc += 1
                k = (data_br(x.get("DataAula")), str(x.get("HorarioInicial") or "")[:5])
                coincide += 1 if (ocupado.get(k, set()) - {did}) else 0
    print(f"\n[Aulas não concluídas] {total_nc} no mês | no mesmo dia e horário de uma aula Concluída "
          f"de OUTRA disciplina: {coincide}")


if __name__ == "__main__":
    main(sys.argv[1:])

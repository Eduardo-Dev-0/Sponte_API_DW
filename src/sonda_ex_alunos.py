"""
Sonda dos alunos que passaram pela turma (somente leitura; não imprime nomes).

Pergunta: a consulta normal do GetFrequenciaTurma só traz quem está na turma agora. Quando um aluno que já
saiu é pedido pelo AlunoID, a API devolve a frequência dele no mês em que estava matriculado?

Uso:
    python src/sonda_ex_alunos.py --turma 623 --mes 2026-05
O que ela faz:
  1) conta as matrículas da turma com algum dia no mês (banco) e quantos alunos a resposta normal traz;
  2) pede, um a um, até 6 alunos que estão fora da resposta normal (prefere os que já saíram);
  3) conclui se o filtro AlunoID resolve.
Requer o .env do loader (SPONTE_* e PG_*) e as cargas de cadastro já feitas.
"""
import os
import sys
from collections import Counter
from datetime import date, timedelta

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
    if not x:
        return []
    if isinstance(x, list):
        return x
    if isinstance(x, dict):
        for v in x.values():
            if isinstance(v, list):
                return v
    return []


def arg(argv, nome, padrao):
    return argv[argv.index(nome) + 1] if nome in argv else padrao


def resumo(resp):
    """Alunos devolvidos e, por aluno, (disciplinas, horas contadas, faltas listadas)."""
    por_aluno = {}
    for turma in resp:
        for d in lista(turma.get("Disciplinas")):
            for a in lista(d.get("Alunos")):
                aid = a.get("AlunoID")
                if aid is None:
                    continue
                n_disc, horas, faltas = por_aluno.get(aid, (0, 0, 0))
                por_aluno[aid] = (n_disc + 1,
                                  horas + (a.get("TotalPresencas") or 0) + (a.get("TotalFaltas") or 0),
                                  faltas + len(lista(a.get("Faltas"))))
    return por_aluno


def main(argv):
    tid = int(arg(argv, "--turma", 623))
    ano, mm = arg(argv, "--mes", "2026-05").split("-")
    mes = date(int(ano), int(mm), 1)
    prox = (mes.replace(day=28) + timedelta(days=4)).replace(day=1)
    fim = min(prox - timedelta(days=1), date.today() - timedelta(days=1))
    janela = f"Data={mes:%Y/%m/%d} e {fim:%Y/%m/%d}"

    conn = psycopg2.connect(
        host=os.environ["PG_HOST"], port=os.environ.get("PG_PORT", "5432"),
        dbname=os.environ["PG_DB"], user=os.environ["PG_USER"], password=os.environ["PG_PASSWORD"])
    cur = conn.cursor()
    cur.execute(
        "SELECT aluno_id, min(data_inicio), "
        "       CASE WHEN bool_or(data_encerramento IS NULL) THEN NULL ELSE max(data_encerramento) END, "
        "       (array_agg(situacao ORDER BY data_inicio DESC NULLS LAST))[1] "
        "FROM dw.fato_matricula WHERE cod_cliente = %s AND turma_id = %s GROUP BY aluno_id", (COD, tid))
    matr = {r[0]: (r[1], r[2], r[3]) for r in cur.fetchall()}
    conn.close()
    no_mes = {a: v for a, v in matr.items()
              if (v[0] is None or v[0] <= fim) and (v[1] is None or v[1] >= mes)}

    print(f"Turma {tid}, {mes:%Y-%m} ({janela})")
    print(f"Matrículas com algum dia no mês: {len(no_mes)} | por situação: "
          f"{dict(Counter(v[2] for v in no_mes.values()))}")

    client = criar_cliente()
    normal = serialize_object(client.service.GetFrequenciaTurma(
        nCodigoCliente=COD, sToken=TOKEN, nTurmaID=tid, sParametrosBusca=janela)) or []
    na_resposta = set(resumo(normal))
    print(f"Alunos na resposta normal da API: {len(na_resposta)}")
    faltando = sorted(a for a in no_mes if a not in na_resposta)
    print(f"Com matrícula no mês e FORA da resposta normal: {len(faltando)} "
          f"(situação: {dict(Counter(no_mes[a][2] for a in faltando))})")
    if not faltando:
        print("\nNenhum aluno falta na resposta normal: a diferença não vem daí. Confira a turma e o mês.")
        return

    # prefere quem já saiu da turma (situação diferente de Vigente)
    testar = sorted(faltando, key=lambda a: (no_mes[a][2] == "Vigente", a))[:6]
    devolvidos = 0
    for aid in testar:
        r = serialize_object(client.service.GetFrequenciaTurma(
            nCodigoCliente=COD, sToken=TOKEN, nTurmaID=tid, sParametrosBusca=f"AlunoID={aid};{janela}")) or []
        res = resumo(r).get(aid)
        ini, enc, sit = no_mes[aid]
        if res:
            devolvidos += 1
            print(f"  aluno {aid} ({sit}, encerramento {enc}): DEVOLVIDO | disciplinas={res[0]} "
                  f"| horas contadas={res[1]} | faltas listadas={res[2]}")
        else:
            print(f"  aluno {aid} ({sit}, encerramento {enc}): não devolvido")

    print(f"\nConsultados pelo AlunoID: {len(testar)} | devolvidos: {devolvidos}")
    if devolvidos:
        print("CONCLUSÃO: SIM. A API devolve a frequência de quem saiu da turma quando pedido pelo AlunoID. "
              "O carregador (carga_frequencia.py) já faz isso.")
    else:
        print("CONCLUSÃO: NÃO. Pelo AlunoID a API não devolveu a frequência de quem saiu da turma. "
              "Será preciso outro caminho; envie esta saída.")


if __name__ == "__main__":
    main(sys.argv[1:])

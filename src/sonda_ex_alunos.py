"""
Testes finais: existe algum caminho na API para a frequência dos alunos que já saíram da turma?
(somente leitura; não imprime nomes)

Contexto: a consulta normal do GetFrequenciaTurma só traz quem está na turma agora, e o filtro AlunoID já foi
testado e NÃO devolve quem saiu. Esta sonda testa o que falta:
  C) parâmetros de busca extras, não documentados, na consulta normal (por exemplo, o equivalente da caixa
     "mostrar alunos que passaram pela turma" do Sponte);
  D) o boletim (GetBoletim3), que traz totais de frequência e faltas por aluno, mesmo de quem saiu;
  E) a agenda do aluno (GetAgendaAluno), que lista as aulas ligadas ao aluno em um período.

Uso:
    python src/sonda_ex_alunos.py --turma 623 --mes 2026-05
Requer o .env do loader (SPONTE_* e PG_*) e as cargas de cadastro e de frequência já feitas.
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

# (nome, valor) de parâmetros de busca que a documentação NÃO lista; só vale se o total de alunos aumentar
CANDIDATOS = [
    ("ExibirAlunosQuePassaram", "1"), ("AlunosQuePassaram", "1"), ("MostrarAlunosQuePassaram", "1"),
    ("IncluirAlunosQuePassaram", "1"), ("ExibirInativos", "1"), ("IncluirInativos", "1"), ("Inativos", "1"),
    ("ExibirAlunosInativos", "1"), ("TodosAlunos", "1"), ("Todos", "1"),
    ("SituacaoAluno", "0"), ("SituacaoAluno", "-1"), ("SituacaoAlunoTurma", "0"), ("SituacaoAlunoTurma", "-1"),
    ("SituacaoAlunoTurmaID", "0"), ("SituacaoAlunoTurmaID", "-1"), ("Situacao", "0"), ("Situacao", "-1"),
    ("Ativo", "0"), ("ApenasAtivos", "0"),
]


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


def alunos_da_resposta(resp):
    return {a.get("AlunoID") for t in resp for d in lista(t.get("Disciplinas"))
            for a in lista(d.get("Alunos")) if a.get("AlunoID") is not None}


def coletar(obj, padrao, achados, limite=14):
    """Percorre o retorno e junta (campo, valor) cujo nome combina com o padrão."""
    if len(achados) >= limite:
        return
    if isinstance(obj, dict):
        for k, v in obj.items():
            if isinstance(v, (dict, list)):
                coletar(v, padrao, achados, limite)
            elif re.search(padrao, str(k), re.I) and k not in achados and v not in (None, ""):
                achados[k] = v
    elif isinstance(obj, list):
        for v in obj:
            coletar(v, padrao, achados, limite)


def datas_do_retorno(obj, saida):
    if isinstance(obj, dict):
        for k, v in obj.items():
            if k == "DataAula" and v:
                try:
                    saida.add(datetime.strptime(str(v)[:10], "%d/%m/%Y").date())
                except ValueError:
                    pass
            elif isinstance(v, (dict, list)):
                datas_do_retorno(v, saida)
    elif isinstance(obj, list):
        for v in obj:
            datas_do_retorno(v, saida)


def main(argv):
    tid = int(arg(argv, "--turma", 623))
    ano, mm = arg(argv, "--mes", "2026-05").split("-")
    mes = date(int(ano), int(mm), 1)
    fim = min((mes.replace(day=28) + timedelta(days=4)).replace(day=1) - timedelta(days=1),
              date.today() - timedelta(days=1))
    janela = f"Data={mes:%Y/%m/%d} e {fim:%Y/%m/%d}"

    conn = psycopg2.connect(
        host=os.environ["PG_HOST"], port=os.environ.get("PG_PORT", "5432"),
        dbname=os.environ["PG_DB"], user=os.environ["PG_USER"], password=os.environ["PG_PASSWORD"])
    cur = conn.cursor()
    cur.execute(
        "SELECT aluno_id, min(data_inicio), CASE WHEN bool_or(data_encerramento IS NULL) THEN NULL "
        "ELSE max(data_encerramento) END, (array_agg(situacao ORDER BY data_inicio DESC NULLS LAST))[1] "
        "FROM dw.fato_matricula WHERE cod_cliente = %s AND turma_id = %s GROUP BY aluno_id", (COD, tid))
    matr = {r[0]: (r[1], r[2], r[3]) for r in cur.fetchall()}
    cur.execute("SELECT DISTINCT data_aula FROM dw.fato_aula_dia WHERE cod_cliente = %s AND turma_id = %s "
                "AND date_trunc('month', data_aula)::date = %s AND aulas_concluidas > 0", (COD, tid, mes))
    dias_db = {r[0] for r in cur.fetchall()}
    conn.close()
    no_mes = {a: v for a, v in matr.items()
              if (v[0] is None or v[0] <= fim) and (v[1] is None or v[1] >= mes)}
    client = criar_cliente()

    print(f"Turma {tid}, {mes:%Y-%m} ({janela})")
    print(f"[A] Matrículas com algum dia no mês: {len(no_mes)} | por situação: {dict(Counter(v[2] for v in no_mes.values()))}")
    base = serialize_object(client.service.GetFrequenciaTurma(
        nCodigoCliente=COD, sToken=TOKEN, nTurmaID=tid, sParametrosBusca=janela)) or []
    n_base = len(alunos_da_resposta(base))
    saidos = sorted((a for a, v in no_mes.items() if v[2] != "Vigente"), key=int)
    print(f"[A] Alunos na resposta normal da API: {n_base} | matriculados no mês que já saíram: {len(saidos)}")

    print("\n[C] Parâmetros de busca extras (não documentados) na consulta normal:")
    acertos = []
    for nome, valor in CANDIDATOS:
        try:
            r = serialize_object(client.service.GetFrequenciaTurma(
                nCodigoCliente=COD, sToken=TOKEN, nTurmaID=tid, sParametrosBusca=f"{nome}={valor};{janela}")) or []
        except Exception as e:
            print(f"    {nome}={valor}: ERRO {type(e).__name__}")
            continue
        n = len(alunos_da_resposta(r))
        ret = r[0].get("RetornoOperacao") if r and isinstance(r[0], dict) else None
        marca = "  <== TRAZ MAIS ALUNOS" if n > n_base else ""
        if n > n_base:
            acertos.append(f"{nome}={valor}")
        print(f"    {nome}={valor}: alunos={n} | retorno={str(ret)[:50]!r}{marca}")

    ids = (saidos[:3] + [a for a in no_mes if no_mes[a][2] == "Vigente"][:1])
    print("\n[D] Boletim (GetBoletim3) dos alunos que saíram (e 1 vigente como controle):")
    com_boletim = 0
    for aid in ids:
        try:
            r = serialize_object(client.service.GetBoletim3(
                nCodigoCliente=COD, sToken=TOKEN, nAlunoID=aid, nTurmaID=tid, nDisciplinaID=0, nModulo=0)) or []
        except Exception as e:
            print(f"    aluno {aid} ({no_mes[aid][2]}): ERRO {type(e).__name__}")
            continue
        achados = {}
        coletar(r, r"freq|falta", achados)
        if achados:
            com_boletim += aid in saidos
        print(f"    aluno {aid} ({no_mes[aid][2]}): campos de frequência/faltas = {dict(list(achados.items())[:8])}")

    print("\n[E] Agenda do aluno (GetAgendaAluno) no mês:")
    com_agenda = 0
    for aid in ids:
        try:
            r = serialize_object(client.service.GetAgendaAluno(
                nCodigoCliente=COD, sToken=TOKEN, nAlunoID=aid, sTurmaID=str(tid), sCursoID="",
                dDataInicio=f"{mes:%Y/%m/%d}", dDataTermino=f"{fim:%Y/%m/%d}")) or []
        except Exception as e:
            print(f"    aluno {aid} ({no_mes[aid][2]}): ERRO {type(e).__name__}")
            continue
        datas = set()
        datas_do_retorno(r, datas)
        if datas and aid in saidos:
            com_agenda += 1
        print(f"    aluno {aid} ({no_mes[aid][2]}): dias com aula na agenda = {len(datas)} "
              f"(dias de aula concluída da turma no mês, no banco: {len(dias_db)})")

    print("\n===== CONCLUSÃO =====")
    if acertos:
        print(f"[C] SIM: estes parâmetros trouxeram mais alunos: {acertos}")
        print('    Use: python src/carga_frequencia.py --param-extra "' + acertos[0] + '" (reconsulta o histórico uma vez).')
    else:
        print("[C] NÃO: nenhum parâmetro extra trouxe mais alunos.")
    print(f"[D] Boletim com campos de frequência para {com_boletim} de {min(3, len(saidos))} alunos que saíram "
          "(são totais da turma, sem dia nem mês).")
    print(f"[E] Agenda com aulas para {com_agenda} de {min(3, len(saidos))} alunos que saíram "
          "(lista as aulas, mas sem as faltas).")
    if not acertos:
        print("Sem parâmetro extra, a API não entrega as faltas por dia de quem saiu. Envie esta saída.")


if __name__ == "__main__":
    main(sys.argv[1:])

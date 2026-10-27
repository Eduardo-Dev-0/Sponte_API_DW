"""
Sondas da etapa 3b (somente leitura; nunca imprime dados pessoais):
  1) GetAlunos4 por AlunoID: CPF e e-mail vêm preenchidos e com formato plausível?
  2) GetAlunosAlterados: quantos alunos do recorte mudaram nos últimos 7 dias?
  3) GetQuadroHorarios por TurmaID: dá para montar dia da semana e horário da turma?

Uso: python src/sonda_alunos.py
Requer o .env do loader (SPONTE_* e PG_*) e ao menos uma carga ok no banco.
"""
import os
import re

import psycopg2
from dotenv import load_dotenv
from zeep import Client
from zeep.helpers import serialize_object

load_dotenv()
WSDL = "https://api.sponteeducacional.net.br/WSAPIEdu.asmx?WSDL"
COD = int(os.environ["SPONTE_COD_CLIENTE"])
TOKEN = os.environ["SPONTE_TOKEN"]

# IDs da última carga ok (apenas números)
conn = psycopg2.connect(
    host=os.environ["PG_HOST"],
    port=os.environ.get("PG_PORT", "5432"),
    dbname=os.environ["PG_DB"],
    user=os.environ["PG_USER"],
    password=os.environ["PG_PASSWORD"],
)
cur = conn.cursor()
ULTIMA = "(SELECT max(carga_id) FROM raw.carga WHERE status = 'ok')"
cur.execute(f"SELECT DISTINCT (payload->>'AlunoID')::int FROM raw.matricula "
            f"WHERE carga_id = {ULTIMA}")
alunos_recorte = sorted(r[0] for r in cur.fetchall())
cur.execute(f"SELECT turma_id FROM raw.matricula WHERE carga_id = {ULTIMA} "
            f"GROUP BY turma_id ORDER BY count(*) DESC LIMIT 1")
turma_id = cur.fetchone()[0]
conn.close()
print(f"{len(alunos_recorte)} alunos distintos no recorte | turma de teste: {turma_id}")

client = Client(WSDL)

# 1) GetAlunos4 por AlunoID (3 alunos), só booleanos
print("\n[1] GetAlunos4 com AlunoID=<id>")
for aid in alunos_recorte[:3]:
    try:
        d = serialize_object(client.service.GetAlunos4(
            nCodigoCliente=COD, sToken=TOKEN, sParametrosBusca=f"AlunoID={aid}")) or []
    except Exception as e:
        print(f"  aluno {aid}: ERRO {type(e).__name__}: {e}")
        continue
    itens = [x for x in d if x.get("AlunoID") == aid]
    if not itens:
        print(f"  aluno {aid}: registros={len(d)} sem AlunoID correspondente; "
              f"campos preenchidos: {[k for k, v in (d[0] if d else {}).items() if v not in (None, '', 0)]}")
        continue
    x = itens[0]
    cpf = re.sub(r"\D", "", x.get("CPF") or "")
    mail = x.get("Email") or ""
    print(f"  aluno {aid}: registros={len(itens)} | CPF preenchido={bool(cpf)} "
          f"(11 dígitos={len(cpf) == 11}) | Email preenchido={bool(mail)} (tem @={'@' in mail})")

# 2) GetAlunosAlterados (últimos 7 dias)
print("\n[2] GetAlunosAlterados (7 dias)")
try:
    r = serialize_object(client.service.GetAlunosAlterados(
        nCodigoCliente=COD, sToken=TOKEN, nQtdDias="7"))
    item = r[0] if isinstance(r, list) and r else r
    ids = {int(i) for i in str(item.get("Alunos") or "").split(";") if i.strip().isdigit()}
    print(f"  alterados na base toda: {len(ids)} | dentro do recorte: "
          f"{len(ids & set(alunos_recorte))}")
except Exception as e:
    print(f"  ERRO {type(e).__name__}: {e}")

# 3) GetQuadroHorarios por turma (sem nomes de professores)
print(f"\n[3] GetQuadroHorarios com TurmaID={turma_id}")
try:
    d = serialize_object(client.service.GetQuadroHorarios(
        nCodigoCliente=COD, sToken=TOKEN, sParametrosBusca=f"TurmaID={turma_id}")) or []
    linhas = [x for x in d if x.get("TurmaID")]
    combos = sorted({(x.get("DiaSemana"), x.get("HorarioInicial"), x.get("HorarioFinal"))
                     for x in linhas}, key=str)
    print(f"  linhas={len(linhas)} | combinações distintas (dia, início, fim)={len(combos)}")
    for c in combos[:10]:
        print("   ", c)
    if not linhas and d:
        print("  retorno:", {k: v for k, v in d[0].items() if v not in (None, '', 0)})
except Exception as e:
    print(f"  ERRO {type(e).__name__}: {e}")

"""
Exporta a lista de pendências para corrigir no Sponte (bi.vw_pendencias_sponte) em CSV, para a equipe
trabalhar numa planilha. Só IDs, datas, turma, módulo e disciplina; sem nome de aluno.

Uso:
    python src/exportar_pendencias.py                          # todas as pendências
    python src/exportar_pendencias.py --tipo "Falta parcial"   # um tipo
    python src/exportar_pendencias.py --desde 2026-08-01       # a partir de uma data (mês)
Saída: data/pendencias_sponte_AAAAMMDD.csv (separador ";", abre direto no Excel)
"""
import csv
import sys
from collections import Counter
from datetime import date
from pathlib import Path

from sponte_loader import COD, conectar

ROOT = Path(__file__).resolve().parent.parent


def main(argv):
    tipo = argv[argv.index("--tipo") + 1] if "--tipo" in argv else None
    desde = argv[argv.index("--desde") + 1] if "--desde" in argv else None
    sql, params = "SELECT * FROM bi.vw_pendencias_sponte WHERE cod_cliente = %s", [COD]
    if tipo:
        sql += " AND tipo = %s"
        params.append(tipo)
    if desde:
        sql += " AND mes >= date_trunc('month', %s::date)"
        params.append(desde)
    sql += " ORDER BY mes, data_aula NULLS LAST, turma_id, tipo"
    conn = conectar()
    try:
        with conn.cursor() as cur:
            cur.execute(sql, params)
            cols = [c[0] for c in cur.description]
            linhas = cur.fetchall()
    finally:
        conn.close()
    (ROOT / "data").mkdir(exist_ok=True)
    destino = ROOT / "data" / f"pendencias_sponte_{date.today():%Y%m%d}.csv"
    with open(destino, "w", newline="", encoding="utf-8-sig") as f:
        w = csv.writer(f, delimiter=";")
        w.writerow(cols)
        w.writerows(linhas)
    por_tipo = Counter(l[cols.index("tipo")] for l in linhas)
    print(f"{len(linhas)} pendências exportadas para {destino}")
    for t, n in por_tipo.most_common():
        print(f"  {t}: {n}")


if __name__ == "__main__":
    main(sys.argv[1:])

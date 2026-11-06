#!/usr/bin/env python3
"""Gera a escada da pool SDBR (ticks e quantidades) para uma rede.

Modelo final (05/11):
  - 100% do supply na pool, à venda para o público (sem compra do emissor);
  - escada PROGRESSIVA (padrão): N degraus, cada um dobra o preço e custa
    `crescimento` vezes o anterior (1º degrau = --valor-degrau US$). Com crescimento 2,
    cada degrau vende a mesma fatia do supply (1/N);
  - --crescimento 1 volta à escada antiga (todo degrau custa --valor-degrau, até --fdv-alvo);
  - a poeira do arredondamento vai para o último degrau (soma = supply).

Num degrau [p, 2p] de liquidez concentrada, X tokens rendem X * p * sqrt(2) em moeda.

Uso: escada.py --token 0x.. --moeda 0x.. --casas-moeda 18 [--espacamento 10] > escada.json
"""
import argparse, json
from decimal import Decimal, getcontext

getcontext().prec = 80

SUPPLY = 10**21          # 1 sextilhão de tokens
CASAS = 9
MIN_TICK, MAX_TICK = -887272, 887272


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--token", required=True)
    ap.add_argument("--moeda", required=True)
    ap.add_argument("--casas-moeda", type=int, required=True)
    ap.add_argument("--espacamento", type=int, default=10)
    ap.add_argument("--fdv-alvo", type=Decimal, default=Decimal(10) ** 12,
                    help="valor de mercado (supply x preço) no topo da escada, em US$")
    ap.add_argument("--valor-degrau", type=Decimal, default=Decimal(1000),
                    help="US$ do 1º degrau")
    ap.add_argument("--crescimento", type=Decimal, default=Decimal(2),
                    help="escada progressiva: cada degrau custa X vezes o anterior (ex.: 2)")
    ap.add_argument("--degraus", type=int, default=20, help="nº de degraus na escada progressiva")
    a = ap.parse_args()

    s = Decimal(SUPPLY)
    unid = 10**CASAS
    esc_tok = s
    v = a.valor_degrau
    p_final = a.fdv_alvo / s

    def degraus(p1):
        """Degraus de p1 até p_final: cada um dobra o preço e rende US$ v; o último pode
        ser parcial (mesma liquidez de um degrau cheio, só mais curto).
        Progressiva: N degraus, cada um dobra o preço e rende v * crescimento^k."""
        bordas, qtd, rende = [p1], [], []
        p = p1
        if a.crescimento != 1:
            for k in range(a.degraus):
                vk = v * a.crescimento ** k
                liq = vk / (p.sqrt() * (Decimal(2).sqrt() - 1))
                q = 2 * p
                qtd.append(liq * (1 / p.sqrt() - 1 / q.sqrt()))
                rende.append(liq * (q.sqrt() - p.sqrt()))
                bordas.append(q)
                p = q
            return bordas, qtd, rende
        while p < p_final * (1 - Decimal("1e-40")):
            q = min(2 * p, p_final)
            liq = v / (p.sqrt() * (Decimal(2).sqrt() - 1))       # rende = liq * (sqrt(q) - sqrt(p))
            qtd.append(liq * (1 / p.sqrt() - 1 / q.sqrt()))
            rende.append(liq * (q.sqrt() - p.sqrt()))
            bordas.append(q)
            p = q
        return bordas, qtd, rende

    # P1 tal que a escada inteira vende exatamente o supply: menos tokens quanto maior P1.
    lo, hi = p_final / Decimal(2) ** 200, p_final * Decimal(2) ** 100
    for _ in range(400):
        meio = (lo * hi).sqrt()
        if sum(degraus(meio)[1]) > esc_tok:
            lo = meio
        else:
            hi = meio
    p1 = hi
    bordas_esc, qtd_esc, rende = degraus(p1)
    bordas_usd = bordas_esc
    qtd_tok = qtd_esc
    n = len(qtd_esc)

    token_eh_0 = int(a.token, 16) < int(a.moeda, 16)
    esp = a.espacamento
    ln = Decimal("1.0001").ln()

    def tick(usd):
        bruto = usd * Decimal(10) ** a.casas_moeda / unid      # moeda (unidades) por token (unidade)
        preco = bruto if token_eh_0 else 1 / bruto              # preço da pool = moeda1 por moeda0
        t = int((preco.ln() / ln).to_integral_value())
        t = round(t / esp) * esp
        assert MIN_TICK < t < MAX_TICK, t
        return t

    ticks = [tick(p) for p in bordas_usd]
    faixas = []
    for i, q in enumerate(qtd_tok):
        lo, hi = ticks[i], ticks[i + 1]
        if not token_eh_0:
            lo, hi = hi, lo                                     # token1: preço cai quando o token sobe
        faixas.append({"inferior": lo, "superior": hi, "quantidade": str(int(q * unid))})

    # escada progressiva: o último degrau vai até o preço máximo do Uniswap — sempre há
    # token à venda acima do preço e nenhuma compra é recusada
    if a.crescimento != 1:
        limite = (MAX_TICK // esp) * esp
        if token_eh_0:
            faixas[-1]["superior"] = limite
        else:
            faixas[-1]["inferior"] = -limite
    # a poeira do arredondamento vai para o último degrau: a pool recebe o supply inteiro
    soma = sum(int(f["quantidade"]) for f in faixas)
    faixas[-1]["quantidade"] = str(int(faixas[-1]["quantidade"]) + SUPPLY * unid - soma)
    soma = sum(int(f["quantidade"]) for f in faixas)
    out = {
        "tokenEhMoeda0": token_eh_0,
        "espacamento": esp,
        "tickInicial": ticks[0],
        "supply": str(SUPPLY * unid),
        "naPool": str(soma),
        "faixas": faixas,
        "inferiores": [f["inferior"] for f in faixas],
        "superiores": [f["superior"] for f in faixas],
        "quantidades": [f["quantidade"] for f in faixas],
        "usd": {
            "fdvInicial": f"{p1 * s:.2f}",
            "publicoInicial": f"{p1:.6e}",
            "final": f"{bordas_usd[-1]:.6e}",
            "fdvFinal": f"{bordas_usd[-1] * s:.6e}",
            "degraus": n,
            "arrecadadoNaEscada": f"{sum(rende):.2f}",
        },
        "tickFinal": ticks[-1],
        "inicioUltimoDegrau": ticks[-2],
    }
    assert soma == SUPPLY * unid
    print(json.dumps(out, indent=1))


if __name__ == "__main__":
    main()

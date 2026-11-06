// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { Test } from "forge-std/Test.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IPoolManager } from "v4-core/interfaces/IPoolManager.sol";
import { PoolKey } from "v4-core/types/PoolKey.sol";
import { PoolIdLibrary } from "v4-core/types/PoolId.sol";
import { SwapParams } from "v4-core/types/PoolOperation.sol";
import { TickMath } from "v4-core/libraries/TickMath.sol";
import { StateLibrary } from "v4-core/libraries/StateLibrary.sol";
import { PoolSwapTest } from "v4-core/test/PoolSwapTest.sol";
import { SDBR } from "../src/SDBR.sol";
import { PoolTravada } from "../src/PoolTravada.sol";
import { BaseSDBR } from "./BaseSDBR.sol";

/// Ações aleatórias de quem usa o sistema: compra, venda, pagamento de serviço, coleta de taxas.
contract Agente is Test {
    using PoolIdLibrary for PoolKey;

    SDBR immutable t;
    PoolTravada immutable pool;
    PoolSwapTest immutable router;
    IPoolManager immutable pm;
    address immutable usdt;
    address[] public pessoas;

    constructor(SDBR _t, PoolTravada _pool, PoolSwapTest _router, address _usdt) {
        (t, pool, router, usdt, pm) = (_t, _pool, _router, _usdt, _router.manager());
        pessoas.push(makeAddr("p1"));
        pessoas.push(makeAddr("p2"));
        pessoas.push(makeAddr("p3"));
    }

    function _noLimite(uint160 _limite) internal view returns (bool) {
        (uint160 sp,,,) = StateLibrary.getSlot0(pm, pool.chave().toId());
        return sp == _limite;
    }

    function comprar(uint256 _quem, uint256 _usdt) external {
        address q = pessoas[_quem % pessoas.length];
        _usdt = bound(_usdt, 1e15, 5_000_000e18);
        bool t0 = pool.tokenEhMoeda0();
        uint160 lim = t0 ? TickMath.MAX_SQRT_PRICE - 1 : TickMath.MIN_SQRT_PRICE + 1;
        if (_noLimite(lim)) return; // escada (e extensão) esgotada: não há token à venda
        deal(usdt, q, _usdt);
        vm.startPrank(q);
        IERC20(usdt).approve(address(router), _usdt);
        router.swap(pool.chave(), SwapParams(!t0, -int256(_usdt), lim), PoolSwapTest.TestSettings(false, false), "");
        vm.stopPrank();
    }

    /// Compras grandes para levar o preço até o último degrau (aberto).
    function comprarGrande(uint256 _quem, uint256 _usdt) external {
        address q = pessoas[_quem % pessoas.length];
        _usdt = bound(_usdt, 50_000_000e18, 800_000_000e18);
        bool t0 = pool.tokenEhMoeda0();
        uint160 lim = t0 ? TickMath.MAX_SQRT_PRICE - 1 : TickMath.MIN_SQRT_PRICE + 1;
        deal(usdt, q, _usdt);
        uint256 antes = t.balanceOf(q);
        vm.startPrank(q);
        IERC20(usdt).approve(address(router), _usdt);
        router.swap(pool.chave(), SwapParams(!t0, -int256(_usdt), lim), PoolSwapTest.TestSettings(false, false), "");
        vm.stopPrank();
        assertGt(t.balanceOf(q), antes, "toda compra recebe token");
    }

    function vender(uint256 _quem, uint256 _parte) external {
        address q = pessoas[_quem % pessoas.length];
        uint256 saldo = t.balanceOf(q);
        if (saldo < 1e9) return;
        uint256 qtd = bound(_parte, 1e9, saldo);
        bool t0 = pool.tokenEhMoeda0();
        uint160 lim = t0 ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
        if (_noLimite(lim)) return;
        vm.startPrank(q);
        t.approve(address(router), qtd);
        router.swap(pool.chave(), SwapParams(t0, -int256(qtd), lim), PoolSwapTest.TestSettings(false, false), "");
        vm.stopPrank();
    }

    uint256 public pagamentos;

    function pagar(uint256 _quem, uint256 _parte) external {
        address q = pessoas[_quem % pessoas.length];
        uint256 saldo = t.balanceOf(q);
        if (saldo < 1e15) return;
        uint256 valor = bound(_parte, 1e15, saldo);
        uint256 antes = t.balanceOf(q);
        vm.startPrank(q);
        t.approve(address(pool), valor);
        try pool.pagar(bytes32(_parte), valor) {
            uint256 cobrado = antes - t.balanceOf(q);
            assertLe(cobrado, valor, "nunca cobra mais que o valor");
            assertGe(cobrado, valor - valor / 1e6 - 1, "cobra o valor do servico");
            pagamentos++;
        } catch {
            fail(); // pagamento nunca pode falhar (valor >= 0,000001 SDBR)
        }
        t.approve(address(pool), 0);
        vm.stopPrank();
    }

    function coletar() external {
        pool.coletarTaxas();
    }
}

/// Invariantes do projeto, conferidos depois de CADA ação aleatória do Agente.
contract InvariantesTest is BaseSDBR {
    Agente agente;
    uint128[] liquidezInicial;

    function setUp() public override {
        super.setUp();
        _lancar();
        PoolTravada.Faixa[] memory fx = pool.todasAsFaixas();
        for (uint256 i; i < fx.length; i++) liquidezInicial.push(_liquidez(fx[i]));
        agente = new Agente(t, pool, router, USDT);
        targetContract(address(agente));
    }

    /// 1. O supply nunca muda.
    function invariant_supplyFixo() public view {
        assertEq(t.totalSupply(), SUPPLY);
    }

    /// 2. A liquidez de cada degrau nunca diminui (pagamentos só aumentam).
    function invariant_liquidezNuncaDiminui() public view {
        PoolTravada.Faixa[] memory fx = pool.todasAsFaixas();
        for (uint256 i; i < liquidezInicial.length; i++) assertGe(_liquidez(fx[i]), liquidezInicial[i]);
    }

    /// 3. Faixas de mercado limitadas (no máximo uma por dobra de preço acima da escada).
    function invariant_faixasLimitadas() public view {
        assertLe(pool.todasAsFaixas().length, liquidezInicial.length + 135);
    }

    /// 6. O preço nunca chega perto do máximo (o último degrau vai até lá).
    function invariant_precoLongeDoMaximo() public view {
        int24 tk = _tick();
        assertLt(tk < 0 ? -tk : tk, TickMath.MAX_TICK - 10_000);
    }

    /// 4. As taxas do dono nunca diminuem (o recebedor não negocia neste teste).
    function invariant_taxasDoDonoNuncaDiminuem() public {
        uint256 u = IERC20(USDT).balanceOf(recebedor);
        uint256 s = t.balanceOf(recebedor);
        assertGe(u, ultimoUsdt);
        assertGe(s, ultimoSdbr);
        (ultimoUsdt, ultimoSdbr) = (u, s);
    }

    uint256 ultimoUsdt;
    uint256 ultimoSdbr;

    /// 5. O contrato da pool não acumula saldo solto (só a poeira do lançamento).
    function invariant_poolSemSaldoSolto() public view {
        assertLe(t.balanceOf(address(pool)), 1000e9);
        assertEq(IERC20(USDT).balanceOf(address(pool)), 0);
    }
}

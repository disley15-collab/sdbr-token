// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IPoolManager } from "v4-core/interfaces/IPoolManager.sol";
import { IHooks } from "v4-core/interfaces/IHooks.sol";
import { PoolKey } from "v4-core/types/PoolKey.sol";
import { PoolIdLibrary } from "v4-core/types/PoolId.sol";
import { Currency } from "v4-core/types/Currency.sol";
import { ModifyLiquidityParams } from "v4-core/types/PoolOperation.sol";
import { TickMath } from "v4-core/libraries/TickMath.sol";
import { StateLibrary } from "v4-core/libraries/StateLibrary.sol";
import { CustomRevert } from "v4-core/libraries/CustomRevert.sol";
import { Hooks } from "v4-core/libraries/Hooks.sol";
import { PoolModifyLiquidityTest } from "v4-core/test/PoolModifyLiquidityTest.sol";
import { Origin } from "@layerzerolabs/oapp-evm/contracts/oapp/OApp.sol";
import { SendParam, MessagingFee } from "@layerzerolabs/oft-evm/contracts/interfaces/IOFT.sol";
import { OFTMsgCodec } from "@layerzerolabs/oft-evm/contracts/libs/OFTMsgCodec.sol";
import { EnforcedOptionParam } from "@layerzerolabs/oapp-evm/contracts/oapp/interfaces/IOAppOptionsType3.sol";
import { SDBR } from "../src/SDBR.sol";
import { PoolTravada } from "../src/PoolTravada.sol";
import { BaseSDBR } from "./BaseSDBR.sol";

interface IPermit2 {
    function approve(address token, address spender, uint160 amount, uint48 expiration) external;
    function transferFrom(address from, address to, uint160 amount, address token) external;
}

contract SDBRTest is BaseSDBR {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    // --------------------------------------------------------------- token

    function test_enderecosReaisETokenEhToken0() public {
        _lancar();
        assertEq(address(t), TOKEN_REAL);
        assertEq(address(pool), POOL_REAL);
        assertTrue(pool.tokenEhMoeda0(), "SDBR e o token0");
        assertEq(Currency.unwrap(pool.chave().currency0), TOKEN_REAL);
    }

    function test_supplySoNasceNaBscMesmoComOMesmoCodigo() public {
        SDBR naBsc = _publicarToken(SALT);
        assertEq(naBsc.totalSupply(), SUPPLY);
        assertEq(naBsc.decimals(), 9);
        vm.createSelectFork("base");
        SDBR naBase = _publicarToken(SALT);
        assertEq(address(naBase), address(naBsc), "mesmo endereco");
        assertEq(naBase.totalSupply(), 0, "fora da BSC nao cria supply");
    }

    function test_permitEMetadados() public {
        t = _publicarToken(SALT);
        assertEq(t.documentacaoHash(), DOC_HASH);
        assertEq(t.contractURI(), "https://sdbr.soliditybrasil.com.br/token.json");
        (, string memory nome, string memory versao, uint256 chainId, address contrato,,) = t.eip712Domain();
        assertEq(nome, "Solidity Brasil");
        assertEq(versao, "1");
        assertEq(chainId, 56);
        assertEq(contrato, address(t));
        (address dono, uint256 pk) = makeAddrAndKey("donoPermit");
        vm.prank(DEPLOYER);
        t.transfer(dono, 1000e9);
        uint256 prazo = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 ss) = _assinarPermit(pk, dono, comprador, 500e9, prazo);
        t.permit(dono, comprador, 500e9, prazo, v, r, ss);
        assertEq(t.allowance(dono, comprador), 500e9);
        vm.expectRevert(); // a mesma assinatura não vale duas vezes
        t.permit(dono, comprador, 500e9, prazo, v, r, ss);
    }

    function test_compativelComPermit2() public {
        IPermit2 p2 = IPermit2(0x000000000022D473030F116dDEE9F6B43aC78BA3);
        t = _publicarToken(SALT);
        vm.startPrank(DEPLOYER);
        t.approve(address(p2), type(uint256).max);
        p2.approve(address(t), comprador, uint160(700e9), uint48(block.timestamp + 1 days));
        vm.stopPrank();
        vm.prank(comprador);
        p2.transferFrom(DEPLOYER, recebedor, uint160(700e9), address(t));
        assertEq(t.balanceOf(recebedor), 700e9);
    }

    // ------------------------------------------------- ninguém ocupa a pool

    function _erroDoHook(bytes4 _funcao) internal view returns (bytes memory) {
        return abi.encodeWithSelector(
            CustomRevert.WrappedError.selector,
            address(pool),
            _funcao,
            abi.encodeWithSelector(PoolTravada.SoEstaPool.selector),
            abi.encodeWithSelector(Hooks.HookCallFailed.selector)
        );
    }

    function _chaveCom(address _hook) internal view returns (PoolKey memory k) {
        k.currency0 = Currency.wrap(TOKEN_REAL);
        k.currency1 = Currency.wrap(USDT);
        k.fee = 20_000;
        k.tickSpacing = 10;
        k.hooks = IHooks(_hook);
    }

    function test_ninguemCriaAPoolAntesNemComOTokenAindaInexistente() public {
        PoolKey memory k = _chaveCom(POOL_REAL);
        vm.expectRevert(abi.encodeWithSelector(Hooks.InvalidHookResponse.selector));
        PM.initialize(k, TickMath.getSqrtPriceAtTick(0));

        t = _publicarToken(SALT);
        pool = _publicarPool(address(t));
        PoolKey memory chaveReal = pool.chave();
        vm.prank(atacante);
        vm.expectRevert(_erroDoHook(IHooks.beforeInitialize.selector));
        PM.initialize(chaveReal, TickMath.getSqrtPriceAtTick(0));
    }

    function test_ataqueComPoeiraNaPoolSemHookNaoAtrapalha() public {
        _publicarToken(SALT);
        PoolKey memory semHook = _chaveCom(address(0));
        PM.initialize(semHook, TickMath.getSqrtPriceAtTick(0));
        PoolModifyLiquidityTest lp = new PoolModifyLiquidityTest(PM);
        deal(USDT, atacante, 1e18);
        vm.startPrank(atacante);
        IERC20(USDT).approve(address(lp), type(uint256).max);
        lp.modifyLiquidity(semHook, ModifyLiquidityParams(-10, 0, 1e9, 0), "");
        vm.stopPrank();
        _lancar();
        assertTrue(pool.lancado());
    }

    function test_ninguemPoeLiquidezNaPoolTravada() public {
        _lancar();
        _comprar(atacante, 5000e18); // o atacante tem SDBR E USDT: só o hook o impede
        PoolModifyLiquidityTest lp = new PoolModifyLiquidityTest(PM);
        PoolKey memory chaveReal = pool.chave();
        deal(USDT, atacante, 1e18);
        vm.startPrank(atacante);
        IERC20(USDT).approve(address(lp), type(uint256).max);
        t.approve(address(lp), type(uint256).max);
        int24 tk = (_tick() / 10) * 10;
        vm.expectRevert(_erroDoHook(IHooks.beforeAddLiquidity.selector));
        lp.modifyLiquidity(chaveReal, ModifyLiquidityParams(tk - 100, tk + 100, 1e12, 0), "");
        vm.stopPrank();
    }

    function test_hookSoAceitaOPoolManager() public {
        t = _publicarToken(SALT);
        pool = _publicarPool(address(t));
        PoolKey memory k;
        vm.expectRevert(PoolTravada.SoPoolManager.selector);
        pool.beforeInitialize(address(0), k, 0);
    }

    // ------------------------------------------------------------- lançamento

    function test_lancamentoColoca100PorCentoNaPool() public {
        _lancar();
        assertEq(t.balanceOf(DEPLOYER), 0, "carteira de publicacao zerada");
        assertLe(t.balanceOf(address(pool)), 1000e9, "so poeira de arredondamento fica no contrato");
        assertGe(t.balanceOf(address(PM)), SUPPLY - 1000e9, "o supply esta na pool");
        assertEq(int256(_tick()), vm.parseJsonInt(json, ".tickInicial"));
        uint256 fdv = _fdvUsd();
        emit log_named_uint("valor de mercado inicial (US$)", fdv);
        assertApproxEqRel(fdv, 14_142, 0.01e18);
    }

    function test_lancarSemAprovacaoNaoMoveNada() public {
        t = _publicarToken(SALT);
        pool = _publicarPool(address(t));
        json = _escada(address(t));
        (PoolTravada.Faixa[] memory fx,) = _faixas();
        vm.prank(DEPLOYER);
        vm.expectRevert();
        pool.lancar(int24(vm.parseJsonInt(json, ".tickInicial")), fx);
        assertEq(t.balanceOf(DEPLOYER), SUPPLY);
        assertFalse(pool.lancado());
    }

    function test_lancarSoUmaVezESoOLancador() public {
        _lancar();
        PoolTravada.Faixa[] memory nada;
        vm.expectRevert(PoolTravada.SoLancador.selector);
        pool.lancar(0, nada);
        vm.prank(DEPLOYER);
        vm.expectRevert(PoolTravada.JaLancado.selector);
        pool.lancar(0, nada);
    }

    // ---------------------------------------------------------------- escada

    function _bordaDoDegrau(uint256 _k) internal view returns (uint160) {
        return TickMath.getSqrtPriceAtTick(int24(pool.tokenEhMoeda0() ? ticksSup[_k] : ticksInf[_k]));
    }

    function test_cadaDegrauDobraOPrecoECustaODobro() public {
        _lancar();
        uint256 fdvAntes = _fdvUsd();
        for (uint256 k; k < 5; k++) {
            uint256 antes = 1e27;
            deal(USDT, comprador, antes);
            _comprarAte(comprador, antes, _bordaDoDegrau(k));
            uint256 gasto = antes - IERC20(USDT).balanceOf(comprador);
            uint256 esperado = (1000e18 << k) * 100 / 98; // US$1.000 x 2^k, mais a taxa
            emit log_named_uint("degrau custou (US$)", gasto / 1e18);
            assertApproxEqRel(gasto, esperado, 0.002e18, "cada degrau custa o dobro do anterior");
            uint256 fdv = _fdvUsd();
            assertApproxEqRel(fdv, fdvAntes * 2, 0.002e18, "e dobra o preco");
            fdvAntes = fdv;
        }
    }

    function test_umBilhaoEmComprasRende20MilhoesENaoTravaCompras() public {
        _lancar();
        uint256 gasto = 1_050_000_000e18;
        _comprar(comprador, gasto);
        pool.coletarTaxas();
        uint256 taxas = IERC20(USDT).balanceOf(recebedor);
        emit log_named_uint("compradores gastaram (US$)", gasto / 1e18);
        emit log_named_uint("valor de mercado depois (US$)", _fdvUsd());
        emit log_named_uint("SUAS TAXAS (US$)", taxas / 1e18);
        assertGe(taxas, 20_000_000e18, "pelo menos US$20 milhoes em taxas");
        // e o mercado continua: mais compras recebem token, nada é recusado
        for (uint256 i; i < 3; i++) {
            uint256 recebido = _comprar(cliente, 10_000_000e18);
            assertGt(recebido, 0, "compra depois de US$1 bi recebe token");
        }
        assertLt(int256(_tick()), int256(TickMath.MAX_TICK - 10_000), "preco longe do maximo");
        emit log_named_uint("valor de mercado depois de mais US$30 mi (US$)", _fdvUsd());
    }

    function test_precoNaoPodeSerEmpurradoDeGraca() public {
        _lancar();
        _comprar(comprador, 1_050_000_000e18);
        int24 antes = _tick();
        uint256 recebido = _comprarAte(atacante, 1e18, TickMath.MAX_SQRT_PRICE - 1); // US$1 tentando ir ao máximo
        assertGt(recebido, 0, "quem compra recebe token");
        assertLt(int256(_tick()) - int256(antes), 50, "US$1 quase nao mexe no preco");
    }

    function test_taxasDe2PorcentoSoParaORecebedor() public {
        _lancar();
        uint256 tok = _comprar(comprador, 1000e18);
        _vender(comprador, tok / 2);
        pool.coletarTaxas();
        assertApproxEqRel(IERC20(USDT).balanceOf(recebedor), 20e18, 0.01e18, "2% de US$1.000");
        assertApproxEqRel(t.balanceOf(recebedor), tok / 2 * 2 / 100, 0.01e18, "2% da venda");
        vm.expectRevert(PoolTravada.SoRecebedor.selector);
        pool.transferirRecebedor(comprador);
        vm.prank(recebedor);
        vm.expectRevert(PoolTravada.EnderecoZero.selector);
        pool.transferirRecebedor(address(0));
    }

    // ------------------------------------------------------- pagamentos

    function test_pagarViraLiquidezNoProximoDegrauInteiro() public {
        _lancar();
        uint256 tok = _comprar(cliente, 500e18); // meio do 1º degrau
        PoolTravada.Faixa[] memory fx = pool.todasAsFaixas();
        uint128 antes1 = _liquidez(fx[1]);
        uint128 antes0 = _liquidez(fx[0]);
        uint256 valor = tok / 3;
        vm.startPrank(cliente);
        t.approve(address(pool), valor);
        vm.expectEmit(true, true, false, false, address(pool));
        emit PoolTravada.Pago(cliente, keccak256("pedido-42"), 0, 0);
        pool.pagar(keccak256("pedido-42"), valor);
        vm.stopPrank();
        assertEq(_liquidez(fx[0]), antes0, "o degrau parcialmente vendido nao muda");
        assertGt(_liquidez(fx[1]), antes1, "o pagamento entrou no proximo degrau inteiro");
        uint256 pago = tok - t.balanceOf(cliente);
        assertLe(pago, valor, "puxa no maximo o valor aprovado");
        assertApproxEqRel(pago, valor, 1e12, "e praticamente o valor todo");
        assertLe(t.balanceOf(address(pool)), 1000e9, "nada fica solto no contrato");
    }

    function test_pagarComPermitNumaTransacao() public {
        _lancar();
        (address quem, uint256 pk) = makeAddrAndKey("clientePermit");
        uint256 tok = _comprar(quem, 300e18);
        uint256 prazo = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = _assinarPermit(pk, quem, address(pool), tok, prazo);
        vm.prank(quem);
        pool.pagarComPermit(keccak256("pedido-permit"), tok, prazo, v, r, s);
        assertLe(t.balanceOf(quem), tok / 1e6, "pagou com uma assinatura so");
    }

    function test_pagarDepoisDaEscadaUsaFaixaDeMercadoAcimaDoPreco() public {
        _lancar();
        uint256 n = pool.degrausDaEscada();
        _comprar(comprador, 1_050_000_000e18); // preço dentro do último degrau (aberto)
        uint256 valor = SUPPLY / 1000;
        uint256 antes = t.balanceOf(comprador);
        vm.startPrank(comprador);
        t.approve(address(pool), 2 * valor);
        pool.pagar("mercado-1", valor);
        pool.pagar("mercado-2", valor); // mesmo preço: reusa a mesma faixa de mercado
        vm.stopPrank();
        PoolTravada.Faixa[] memory fx = pool.todasAsFaixas();
        assertEq(fx.length, n + 1, "uma faixa de mercado, reusada");
        assertGt(fx[n].inferior, _tick(), "inteira acima do preco");
        assertApproxEqRel(antes - t.balanceOf(comprador), 2 * valor, 1e12, "cliente pagou o valor");
        _comprar(cliente, 2_000_000_000e18); // preço sobe mais de uma dobra
        vm.startPrank(comprador);
        t.approve(address(pool), valor);
        pool.pagar("mercado-3", valor);
        vm.stopPrank();
        fx = pool.todasAsFaixas();
        assertGt(fx[fx.length - 1].inferior, fx[n].inferior, "faixa nova acima da anterior");
        pool.coletarTaxas();
    }

    function test_coletaPorPartes() public {
        _lancar();
        _comprar(comprador, 50_000e18);
        uint256 n = pool.todasAsFaixas().length;
        pool.coletarTaxasFaixas(0, n / 2);
        pool.coletarTaxasFaixas(n / 2, n);
        assertGt(IERC20(USDT).balanceOf(recebedor), 0);
        vm.expectRevert(PoolTravada.IntervaloInvalido.selector);
        pool.coletarTaxasFaixas(n, n + 1);
    }

    /// M1 da auditoria: o degrau escolhido tem taxas em USDT acumuladas (preço foi e voltou).
    function test_pagarComTaxasNoDegrauNaoTravaETaxasVaoProDono() public {
        _lancar();
        uint256 tok = _comprar(cliente, 400e18);
        // ida e volta pela borda do 1º degrau: o 2º degrau acumula taxa em USDT
        uint256 ida = _comprar(comprador, 1500e18);
        _vender(comprador, ida);
        PoolTravada.Faixa[] memory fx = pool.todasAsFaixas();
        assertTrue(_tick() < fx[1].inferior, "o preco voltou para o 1o degrau");
        uint256 usdtAntes = IERC20(USDT).balanceOf(recebedor);
        uint256 valor = tok / 2;
        vm.startPrank(cliente);
        t.approve(address(pool), valor);
        pool.pagar("com-taxa", valor);
        vm.stopPrank();
        uint256 cobrado = tok - t.balanceOf(cliente);
        assertLe(cobrado, valor);
        assertApproxEqRel(cobrado, valor, 1e12, "cliente paga o valor do servico");
        assertGt(IERC20(USDT).balanceOf(recebedor), usdtAntes, "as taxas do degrau foram para o dono");
    }

    /// M2 da auditoria: taxas em SDBR do degrau não podem abater a conta do cliente.
    function test_taxaEmSdbrDoDegrauNaoAbateAContaDoCliente() public {
        _lancar();
        uint256 tok = _comprar(cliente, 400e18);
        uint256 ida = _comprar(comprador, 6000e18); // passa do 2º degrau
        _vender(comprador, ida); // vende tudo de volta: o 2º degrau acumula taxa em SDBR
        uint256 sdbrAntes = t.balanceOf(recebedor);
        uint256 valor = tok / 2;
        vm.startPrank(cliente);
        t.approve(address(pool), valor);
        pool.pagar("sdbr", valor);
        vm.stopPrank();
        uint256 cobrado = tok - t.balanceOf(cliente);
        assertApproxEqRel(cobrado, valor, 1e12, "cobra o valor inteiro, nao valor - taxas");
        assertGt(t.balanceOf(recebedor), sdbrAntes, "as taxas em SDBR foram para o dono");
    }

    function test_pagarComOTokenComoToken1() public {
        _lancarCom(SALT_TOKEN1);
        assertFalse(pool.tokenEhMoeda0());
        uint256 tok = _comprar(cliente, 700e18);
        vm.startPrank(cliente);
        t.approve(address(pool), tok);
        pool.pagar("t1", tok);
        vm.stopPrank();
        assertLe(t.balanceOf(cliente), tok / 1e6);
    }

    function test_pagarAntesDoLancamentoRecusa() public {
        t = _publicarToken(SALT);
        pool = _publicarPool(address(t));
        vm.expectRevert(PoolTravada.NaoLancado.selector);
        pool.pagar("x", 1);
    }

    // -------------------------------------------------------------- ponte

    function test_ponteBscParaBaseComGasMinimoFixado() public {
        uint256 bscFork = vm.activeFork();
        uint256 baseFork = vm.createFork("base");
        vm.selectFork(baseFork);
        SDBR naBase = _publicarToken(SALT);
        uint32[] memory e = new uint32[](1);
        e[0] = EID_BSC;
        vm.prank(DEPLOYER);
        naBase.ligarRedesEVM(e);

        vm.selectFork(bscFork);
        SDBR naBsc = _publicarToken(SALT);
        e[0] = EID_BASE;
        vm.startPrank(DEPLOYER);
        naBsc.ligarRedesEVM(e);
        EnforcedOptionParam[] memory o = new EnforcedOptionParam[](1);
        o[0] = EnforcedOptionParam(EID_BASE, 1, abi.encodePacked(uint16(3), uint8(1), uint16(17), uint8(1), uint128(150_000)));
        naBsc.setEnforcedOptions(o);
        vm.stopPrank();

        uint256 valor = 5e18 * 1e9;
        SendParam memory sp = SendParam(EID_BASE, bytes32(uint256(uint160(comprador))), valor, valor, "", "", "");
        MessagingFee memory taxa = naBsc.quoteSend(sp, false);
        vm.deal(DEPLOYER, taxa.nativeFee);
        vm.prank(DEPLOYER);
        naBsc.send{ value: taxa.nativeFee }(sp, taxa, DEPLOYER);
        assertEq(naBsc.totalSupply(), SUPPLY - valor, "queimou na origem");

        vm.selectFork(baseFork);
        (bytes memory m,) = OFTMsgCodec.encode(bytes32(uint256(uint160(comprador))), uint64(valor / 1e9), "");
        vm.prank(EP);
        uint256 g = gasleft();
        naBase.lzReceive(Origin(EID_BSC, bytes32(uint256(uint160(address(naBsc)))), 1), bytes32(uint256(1)), m, address(0), "");
        assertLt(g - gasleft(), 150_000, "cabe no gas minimo fixado");
        assertEq(naBase.balanceOf(comprador), valor, "criou no destino");
    }

    // ------------------------------------------------------------- ajudante

    function _assinarPermit(uint256 _pk, address _dono, address _gasta, uint256 _valor, uint256 _prazo)
        internal
        view
        returns (uint8, bytes32, bytes32)
    {
        bytes32 h = keccak256(
            abi.encode(
                keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"),
                _dono, _gasta, _valor, t.nonces(_dono), _prazo
            )
        );
        return vm.sign(_pk, keccak256(abi.encodePacked("\x19\x01", t.DOMAIN_SEPARATOR(), h)));
    }
}

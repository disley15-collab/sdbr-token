// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { Test, Vm, console2 } from "forge-std/Test.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IPoolManager } from "v4-core/interfaces/IPoolManager.sol";
import { PoolKey } from "v4-core/types/PoolKey.sol";
import { PoolIdLibrary } from "v4-core/types/PoolId.sol";
import { SwapParams } from "v4-core/types/PoolOperation.sol";
import { TickMath } from "v4-core/libraries/TickMath.sol";
import { StateLibrary } from "v4-core/libraries/StateLibrary.sol";
import { PoolSwapTest } from "v4-core/test/PoolSwapTest.sol";
import { Origin } from "@layerzerolabs/oapp-evm/contracts/oapp/OApp.sol";
import { SendParam, MessagingFee } from "@layerzerolabs/oft-evm/contracts/interfaces/IOFT.sol";
import { OFTMsgCodec } from "@layerzerolabs/oft-evm/contracts/libs/OFTMsgCodec.sol";
import { SDBR } from "../src/SDBR.sol";
import { PoolTravada } from "../src/PoolTravada.sol";

/// Bateria contra os contratos JÁ PUBLICADOS (fork da mainnet, nada é enviado à rede).
/// Mede compra, venda, transferência, pagamento, coleta de taxas e ponte entre redes.
contract ProducaoTest is Test {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    SDBR constant T = SDBR(0x00000000001C77283FDB79c1D012930C3c987cbc);
    PoolTravada constant POOL = PoolTravada(0x00000042c7901119a491B1ed862C3D052bF72800);
    IPoolManager constant PM = IPoolManager(0x28e2Ea090877bF75740558f6BFB36A5ffeE9e9dF);
    address constant USDT = 0x55d398326f99059fF775485246999027B3197955;
    address constant EP = 0x1a44076050125825900e736c501f859c50fE728c;
    address constant RECEBEDOR = 0x979514BddD0346FdD218c49B8242b92C1A6D0ffC;
    uint32 constant EID_BSC = 30102;
    uint32 constant EID_BASE = 30184;

    PoolSwapTest router;
    address ana = makeAddr("ana");
    address beto = makeAddr("beto");

    function setUp() public {
        vm.createSelectFork("bsc");
        router = new PoolSwapTest(PM);
    }

    // ------------------------------------------------------------------ compra e venda

    function test_compraDeVariosTamanhos() public {
        uint256[5] memory valores = [uint256(1e18), 10e18, 100e18, 1_000e18, 10_000e18];
        console2.log("=== COMPRAS SEQUENCIAIS (USDT -> SDBR) ===");
        for (uint256 i; i < valores.length; i++) {
            uint256 g = gasleft();
            uint256 rec = _comprar(ana, valores[i]);
            uint256 gas = g - gasleft();
            assertGt(rec, 0, "recebeu SDBR");
            console2.log("USDT pago:", valores[i] / 1e18);
            console2.log("  SDBR recebido (inteiro):", rec / 1e9);
            console2.log("  preco medio (USDT por 1e9 SDBR, x1e9):", valores[i] * 1e9 / rec);
            console2.log("  gas da compra (com router de teste):", gas);
            console2.log("  tick depois:", int256(_tick()));
        }
    }

    function test_compraEVendaDeVoltaNaoTrava() public {
        uint256 pago = 100e18;
        uint256 rec = _comprar(ana, pago);
        uint256 g = gasleft();
        uint256 volta = _vender(ana, rec);
        uint256 gas = g - gasleft();
        assertGt(volta, 0, "venda devolveu USDT");
        assertEq(T.balanceOf(ana), 0, "vendeu tudo");
        console2.log("=== COMPRA 100 USDT E VENDE TUDO NA HORA ===");
        console2.log("SDBR comprado (inteiro):", rec / 1e9);
        console2.log("USDT de volta (centavos):", volta / 1e16);
        console2.log("perda ida+volta (centavos):", (pago - volta) / 1e16);
        console2.log("gas da venda:", gas);
    }

    function test_vendaParcialDeOutroComprador() public {
        _comprar(ana, 500e18);
        uint256 rb = _comprar(beto, 50e18);
        uint256 volta = _vender(beto, rb / 2);
        assertGt(volta, 0, "vendeu metade");
        console2.log("=== BETO COMPRA 50 USDT DEPOIS DA ANA E VENDE METADE ===");
        console2.log("USDT de volta (centavos):", volta / 1e16);
        console2.log("SDBR que ficou com o Beto:", T.balanceOf(beto) / 1e9);
    }

    // ------------------------------------------------------------------ transferências

    function test_transferenciasEAprovacao() public {
        uint256 rec = _comprar(ana, 10e18);
        vm.prank(ana);
        uint256 g = gasleft();
        T.transfer(beto, rec / 2);
        uint256 gTransf = g - gasleft();
        assertEq(T.balanceOf(beto), rec / 2, "chegou inteiro, sem taxa");

        vm.prank(beto);
        T.approve(ana, rec / 4);
        vm.prank(ana);
        g = gasleft();
        T.transferFrom(beto, ana, rec / 4);
        uint256 gTf = g - gasleft();
        assertEq(T.balanceOf(beto), rec / 2 - rec / 4, "transferFrom exato");
        console2.log("=== TRANSFERENCIAS ===");
        console2.log("gas transfer (ja tinha saldo? nao):", gTransf);
        console2.log("gas transferFrom:", gTf);
        console2.log("taxa na transferencia: 0 (valor chegou inteiro)");
    }

    // ------------------------------------------------------------------ pagamento de serviço e taxas

    function test_pagarServicoViraLiquidez() public {
        uint256 rec = _comprar(ana, 200e18);
        uint256 paga = rec / 2;
        uint256 naPoolAntes = T.balanceOf(address(PM));
        vm.startPrank(ana);
        T.approve(address(POOL), paga);
        vm.recordLogs();
        uint256 g = gasleft();
        POOL.pagar(bytes32("pedido-teste-1"), paga);
        uint256 gas = g - gasleft();
        vm.stopPrank();
        uint256 depositado = _depositadoDoEvento();
        uint256 debitado = rec - T.balanceOf(ana);
        assertEq(debitado, depositado, "cliente paga exatamente o que foi depositado");
        assertLe(depositado, paga, "nunca mais que o pedido");
        assertLt(paga - depositado, 1e7, "sobra de arredondamento < 0,01 SDBR fica com o cliente");
        assertEq(T.balanceOf(address(PM)), naPoolAntes + depositado, "tudo foi para a pool");
        assertEq(T.allowance(ana, address(POOL)), paga - depositado, "sobra da aprovacao nao foi usada");
        console2.log("=== PAGAMENTO DE SERVICO EM SDBR ===");
        console2.log("SDBR pedido (inteiro):", paga / 1e9);
        console2.log("sobra de arredondamento que ficou com o cliente (menor unidade):", paga - depositado);
        console2.log("gas do pagar():", gas);
    }

    function test_taxasDe2PorcentoVaoProRecebedor() public {
        _comprar(ana, 1_000e18);
        uint256 rec = T.balanceOf(ana);
        _vender(ana, rec / 3);
        uint256 u0 = IERC20(USDT).balanceOf(RECEBEDOR);
        uint256 s0 = T.balanceOf(RECEBEDOR);
        uint256 g = gasleft();
        POOL.coletarTaxas();
        uint256 gas = g - gasleft();
        uint256 du = IERC20(USDT).balanceOf(RECEBEDOR) - u0;
        uint256 ds = T.balanceOf(RECEBEDOR) - s0;
        assertGt(du, 0, "recebedor ganhou USDT");
        console2.log("=== COLETA DE TAXAS (compra 1000 USDT + venda de 1/3) ===");
        console2.log("USDT para o recebedor (centavos):", du / 1e16);
        console2.log("SDBR para o recebedor (inteiro):", ds / 1e9);
        console2.log("gas do coletarTaxas():", gas);
    }

    // ------------------------------------------------------------------ ponte entre redes

    function test_ponteBscBaseEVoltaComContratosReais() public {
        uint256 rec = _comprar(ana, 50e18);
        uint256 valor = (rec / 1e9 / 2) * 1e9; // inteiro de SDBR (sharedDecimals = 0)
        uint256 supplyAntes = T.totalSupply();

        SendParam memory sp = SendParam(EID_BASE, bytes32(uint256(uint160(ana))), valor, valor, "", "", "");
        MessagingFee memory taxa = T.quoteSend(sp, false);
        vm.deal(ana, 1 ether);
        vm.prank(ana);
        uint256 g = gasleft();
        T.send{ value: taxa.nativeFee }(sp, taxa, ana);
        uint256 gasEnvio = g - gasleft();
        assertEq(T.totalSupply(), supplyAntes - valor, "queimou na BSC");
        console2.log("=== PONTE BSC -> BASE (contratos reais) ===");
        console2.log("SDBR enviado:", valor / 1e9);
        console2.log("taxa LayerZero em BNB (wei):", taxa.nativeFee);
        console2.log("gas do send na BSC:", gasEnvio);

        uint256 bsc = vm.activeFork();
        vm.createSelectFork("base");
        assertEq(T.peers(EID_BSC), bytes32(uint256(uint160(address(T)))), "Base aceita a BSC como par");
        (bytes memory m,) = OFTMsgCodec.encode(bytes32(uint256(uint160(ana))), uint64(valor / 1e9), "");
        vm.prank(EP);
        g = gasleft();
        T.lzReceive(Origin(EID_BSC, bytes32(uint256(uint160(address(T)))), 1), bytes32(uint256(1)), m, address(0), "");
        uint256 gasReceb = g - gasleft();
        assertEq(T.balanceOf(ana), valor, "criou na Base");
        assertLt(gasReceb, 150_000, "cabe no gas fixado (150k)");
        console2.log("gas do recebimento na Base:", gasReceb);

        // volta Base -> BSC
        SendParam memory sv = SendParam(EID_BSC, bytes32(uint256(uint160(beto))), valor, valor, "", "", "");
        MessagingFee memory tv = T.quoteSend(sv, false);
        vm.deal(ana, 1 ether);
        vm.prank(ana);
        T.send{ value: tv.nativeFee }(sv, tv, ana);
        assertEq(T.balanceOf(ana), 0, "queimou na Base");
        console2.log("taxa LayerZero da volta em ETH (wei):", tv.nativeFee);

        vm.selectFork(bsc);
        (m,) = OFTMsgCodec.encode(bytes32(uint256(uint160(beto))), uint64(valor / 1e9), "");
        vm.prank(EP);
        T.lzReceive(Origin(EID_BASE, bytes32(uint256(uint160(address(T)))), 1), bytes32(uint256(2)), m, address(0), "");
        assertEq(T.balanceOf(beto), valor, "voltou para a BSC");
        assertEq(T.totalSupply(), supplyAntes, "supply total igual ao inicio");
        uint256 volta = _vender(beto, valor);
        assertGt(volta, 0, "SDBR que fez ida e volta vende normal");
        console2.log("Beto vendeu o SDBR que voltou da Base, USDT (centavos):", volta / 1e16);
    }

    function test_ponteRecusaQuemNaoEhOEndpoint() public {
        (bytes memory m,) = OFTMsgCodec.encode(bytes32(uint256(uint160(ana))), uint64(1_000_000), "");
        vm.expectRevert();
        T.lzReceive(Origin(EID_BASE, bytes32(uint256(uint160(address(T)))), 1), bytes32(uint256(9)), m, address(0), "");
        assertEq(T.balanceOf(ana), 0, "ninguem cria SDBR fingindo ser a ponte");
    }

    // ------------------------------------------------------------------ ajudantes

    function _comprar(address _quem, uint256 _usdt) internal returns (uint256 recebido) {
        bool t0 = POOL.tokenEhMoeda0();
        deal(USDT, _quem, IERC20(USDT).balanceOf(_quem) + _usdt);
        uint256 antes = T.balanceOf(_quem);
        vm.startPrank(_quem);
        IERC20(USDT).approve(address(router), _usdt);
        router.swap(
            POOL.chave(),
            SwapParams(!t0, -int256(_usdt), t0 ? TickMath.MAX_SQRT_PRICE - 1 : TickMath.MIN_SQRT_PRICE + 1),
            PoolSwapTest.TestSettings(false, false),
            ""
        );
        vm.stopPrank();
        return T.balanceOf(_quem) - antes;
    }

    function _vender(address _quem, uint256 _qtd) internal returns (uint256 usdt) {
        bool t0 = POOL.tokenEhMoeda0();
        uint256 antes = IERC20(USDT).balanceOf(_quem);
        vm.startPrank(_quem);
        T.approve(address(router), _qtd);
        router.swap(
            POOL.chave(),
            SwapParams(t0, -int256(_qtd), t0 ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1),
            PoolSwapTest.TestSettings(false, false),
            ""
        );
        vm.stopPrank();
        return IERC20(USDT).balanceOf(_quem) - antes;
    }

    function _depositadoDoEvento() internal returns (uint256) {
        bytes32 sig = keccak256("Pago(address,bytes32,uint256,uint256)");
        Vm.Log[] memory ls = vm.getRecordedLogs();
        for (uint256 i; i < ls.length; i++) {
            if (ls[i].emitter == address(POOL) && ls[i].topics[0] == sig) {
                (uint256 valor,) = abi.decode(ls[i].data, (uint256, uint256));
                return valor;
            }
        }
        revert("evento Pago nao emitido");
    }

    function _tick() internal view returns (int24 tk) {
        (, tk,,) = PM.getSlot0(POOL.chave().toId());
    }
}

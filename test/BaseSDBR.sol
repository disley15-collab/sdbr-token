// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { Test } from "forge-std/Test.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IPoolManager } from "v4-core/interfaces/IPoolManager.sol";
import { PoolKey } from "v4-core/types/PoolKey.sol";
import { PoolIdLibrary } from "v4-core/types/PoolId.sol";
import { SwapParams } from "v4-core/types/PoolOperation.sol";
import { TickMath } from "v4-core/libraries/TickMath.sol";
import { FullMath } from "v4-core/libraries/FullMath.sol";
import { StateLibrary } from "v4-core/libraries/StateLibrary.sol";
import { PoolSwapTest } from "v4-core/test/PoolSwapTest.sol";
import { SDBR } from "../src/SDBR.sol";
import { PoolTravada } from "../src/PoolTravada.sol";
import { ICreateX } from "../src/ICreateX.sol";

/// Base dos testes. Fork da BSC e da Base MAINNET: PoolManager v4, USDT, CreateX e endpoint
/// LayerZero reais. Usa a carteira de publicação e os salts REAIS (script/salt*.json).
abstract contract BaseSDBR is Test {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    address constant CREATEX = 0xba5Ed099633D3B313e4D5F7bdc1305d3c28ba5Ed;
    address constant EP = 0x1a44076050125825900e736c501f859c50fE728c;
    IPoolManager constant PM = IPoolManager(0x28e2Ea090877bF75740558f6BFB36A5ffeE9e9dF);
    address constant USDT = 0x55d398326f99059fF775485246999027B3197955; // 18 casas
    uint32 constant EID_BSC = 30102;
    uint32 constant EID_BASE = 30184;
    address constant DEPLOYER = 0xcDb05fEDD9ef3258e75De23AbF2751aC22156A1c;
    /// salt antigo (0x8EC6…238B): token MAIOR que o USDT, para testar a outra ordem do par
    bytes32 constant SALT_TOKEN1 = 0xcdb05fedd9ef3258e75de23abf2751ac22156a1c00978a3292e8c60cac1a32d7;

    uint256 constant SUPPLY = 1e21 * 1e9;
    bytes32 constant DOC_HASH = keccak256("documentacao SDBR v1");

    bytes32 SALT;
    bytes32 SALT_POOL;
    address TOKEN_REAL;
    address POOL_REAL;

    address comprador = makeAddr("comprador");
    address cliente = makeAddr("cliente");
    address recebedor = makeAddr("recebedor");
    address atacante = makeAddr("atacante");

    SDBR t;
    PoolTravada pool;
    PoolSwapTest router;
    string json;
    int256[] ticksInf;
    int256[] ticksSup;

    function setUp() public virtual {
        string memory s = vm.readFile("script/salt.json");
        string memory p = vm.readFile("script/salt-pool.json");
        (SALT, TOKEN_REAL) = (vm.parseJsonBytes32(s, ".salt"), vm.parseJsonAddress(s, ".endereco"));
        (SALT_POOL, POOL_REAL) = (vm.parseJsonBytes32(p, ".salt"), vm.parseJsonAddress(p, ".endereco"));
        vm.createSelectFork("bsc");
        router = new PoolSwapTest(PM);
    }

    function _publicarToken(bytes32 _salt) internal returns (SDBR) {
        bytes memory init = abi.encodePacked(
            type(SDBR).creationCode,
            abi.encode("Solidity Brasil", "SDBR", EP, DEPLOYER, DEPLOYER, "https://sdbr.soliditybrasil.com.br/token.json", DOC_HASH)
        );
        vm.prank(DEPLOYER);
        return SDBR(ICreateX(CREATEX).deployCreate3(_salt, init));
    }

    function _publicarPool(address _token) internal returns (PoolTravada) {
        bytes memory init =
            abi.encodePacked(type(PoolTravada).creationCode, abi.encode(PM, DEPLOYER, _token, USDT, int24(10), recebedor));
        vm.prank(DEPLOYER);
        return PoolTravada(ICreateX(CREATEX).deployCreate3(SALT_POOL, init));
    }

    function _escada(address _token) internal returns (string memory) {
        string[] memory c = new string[](8);
        (c[0], c[1], c[2], c[3]) = ("python3", "script/escada.py", "--token", vm.toString(_token));
        (c[4], c[5], c[6], c[7]) = ("--moeda", vm.toString(USDT), "--casas-moeda", "18");
        return string(vm.ffi(c));
    }

    function _faixas() internal returns (PoolTravada.Faixa[] memory fx, uint256 total) {
        ticksInf = vm.parseJsonIntArray(json, ".inferiores");
        ticksSup = vm.parseJsonIntArray(json, ".superiores");
        uint256[] memory q = vm.parseJsonUintArray(json, ".quantidades");
        fx = new PoolTravada.Faixa[](q.length);
        for (uint256 i; i < q.length; i++) {
            fx[i] = PoolTravada.Faixa(int24(ticksInf[i]), int24(ticksSup[i]), q[i]);
            total += q[i];
        }
    }

    function _lancar() internal {
        _lancarCom(SALT);
    }

    /// Igual ao script/Publicar.s.sol na BSC.
    function _lancarCom(bytes32 _salt) internal {
        t = _salt == SALT && TOKEN_REAL.code.length > 0 ? SDBR(TOKEN_REAL) : _publicarToken(_salt);
        pool = _publicarPool(address(t));
        json = _escada(address(t));
        (PoolTravada.Faixa[] memory fx, uint256 total) = _faixas();
        assertEq(vm.parseJsonBool(json, ".tokenEhMoeda0"), pool.tokenEhMoeda0());
        assertEq(total, SUPPLY, "a escada leva o supply inteiro");
        vm.startPrank(DEPLOYER);
        t.approve(address(pool), total);
        pool.lancar(int24(vm.parseJsonInt(json, ".tickInicial")), fx);
        vm.stopPrank();
    }

    function _comprar(address _quem, uint256 _usdt) internal returns (uint256 recebido) {
        return _comprarAte(_quem, _usdt, pool.tokenEhMoeda0() ? TickMath.MAX_SQRT_PRICE - 1 : TickMath.MIN_SQRT_PRICE + 1);
    }

    function _comprarAte(address _quem, uint256 _usdt, uint160 _limite) internal returns (uint256 recebido) {
        deal(USDT, _quem, _usdt);
        uint256 antes = t.balanceOf(_quem);
        vm.startPrank(_quem);
        IERC20(USDT).approve(address(router), _usdt);
        router.swap(pool.chave(), SwapParams(!pool.tokenEhMoeda0(), -int256(_usdt), _limite), PoolSwapTest.TestSettings(false, false), "");
        vm.stopPrank();
        return t.balanceOf(_quem) - antes;
    }

    function _vender(address _quem, uint256 _qtd) internal returns (uint256 usdt) {
        uint256 antes = IERC20(USDT).balanceOf(_quem);
        bool t0 = pool.tokenEhMoeda0();
        vm.startPrank(_quem);
        t.approve(address(router), _qtd);
        router.swap(
            pool.chave(),
            SwapParams(t0, -int256(_qtd), t0 ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1),
            PoolSwapTest.TestSettings(false, false),
            ""
        );
        vm.stopPrank();
        return IERC20(USDT).balanceOf(_quem) - antes;
    }

    function _tick() internal view returns (int24 tk) {
        (, tk,,) = PM.getSlot0(pool.chave().toId());
    }

    /// Valor de mercado (supply x preço da pool) em US$, lido do sqrtPrice da cadeia.
    function _fdvUsd() internal view returns (uint256) {
        (uint160 sp,,,) = PM.getSlot0(pool.chave().toId());
        uint256 q96 = 2 ** 96;
        if (pool.tokenEhMoeda0()) return FullMath.mulDiv(FullMath.mulDiv(SUPPLY, sp, q96), sp, q96) / 1e18;
        return FullMath.mulDiv(FullMath.mulDiv(SUPPLY, q96, sp), q96, sp) / 1e18;
    }

    function _liquidez(PoolTravada.Faixa memory f) internal view returns (uint128) {
        bytes32 pos = keccak256(abi.encodePacked(address(pool), f.inferior, f.superior, bytes32(0)));
        return PM.getPositionLiquidity(pool.chave().toId(), pos);
    }
}

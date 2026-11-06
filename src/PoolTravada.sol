// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC20Permit } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { IPoolManager } from "v4-core/interfaces/IPoolManager.sol";
import { IUnlockCallback } from "v4-core/interfaces/callback/IUnlockCallback.sol";
import { IHooks } from "v4-core/interfaces/IHooks.sol";
import { PoolKey } from "v4-core/types/PoolKey.sol";
import { PoolId, PoolIdLibrary } from "v4-core/types/PoolId.sol";
import { Currency } from "v4-core/types/Currency.sol";
import { ModifyLiquidityParams } from "v4-core/types/PoolOperation.sol";
import { BalanceDelta } from "v4-core/types/BalanceDelta.sol";
import { TickMath } from "v4-core/libraries/TickMath.sol";
import { Hooks } from "v4-core/libraries/Hooks.sol";
import { StateLibrary } from "v4-core/libraries/StateLibrary.sol";
import { TransientStateLibrary } from "v4-core/libraries/TransientStateLibrary.sol";
import { LiquidityAmounts } from "v4-periphery/libraries/LiquidityAmounts.sol";

/// @title PoolTravada — a pool do SDBR (Uniswap v4, taxa 2%), com 100% do supply e a
/// liquidez travada PARA SEMPRE.
///
/// @dev Invariantes:
/// 1. A liquidez de cada faixa nunca diminui: não existe função que tire liquidez.
/// 2. Só este contrato cria a pool e põe liquidez. Ele é o HOOK da pool; o PoolManager
///    não chama o hook quando quem age é o próprio hook, e para qualquer outro
///    `beforeInitialize` e `beforeAddLiquidity` recusam. Comprar e vender é livre.
/// 3. As taxas (nas duas moedas) só saem para `recebedorTaxas`, por `coletarTaxas`.
/// 4. Pagamento de serviço (`pagar`) vira liquidez: o SDBR do cliente é depositado no
///    primeiro degrau inteiro acima do preço atual. Se o preço já passou de todos os
///    degraus, vai para uma "faixa de mercado" do próximo múltiplo de uma dobra de preço
///    acima do preço até o preço máximo (no máximo uma posição por dobra). O cliente paga
///    só o principal; as taxas da posição vão ao recebedor na mesma operação.
/// 5. O último degrau vai até o preço máximo do Uniswap: sempre há SDBR à venda acima do
///    preço, nenhuma compra é recusada por falta de liquidez e o preço não pode ser
///    empurrado de graça.
///
/// Publicado pela CreateX num endereço cujos bits de hook são exatamente
/// BEFORE_INITIALIZE | BEFORE_ADD_LIQUIDITY (o construtor confere).
contract PoolTravada is IUnlockCallback {
    using SafeERC20 for IERC20;
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;

    uint24 public constant TAXA = 20_000; // 2% (em milionésimos)
    /// @notice Uma dobra de preço em ticks (ln 2 / ln 1,0001 = 6.931,5), alinhada a 10.
    int24 public constant DOBRA = 6930;
    uint160 internal constant BITS_HOOK = Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG;

    struct Faixa {
        int24 inferior;
        int24 superior;
        uint256 quantidade; // tokens depositados no lançamento (só o token, faixa fora do preço)
    }

    IPoolManager public immutable poolManager;
    address public immutable lancador;
    Currency public immutable token;
    Currency public immutable moeda;
    bool public immutable tokenEhMoeda0;
    int24 public immutable espacamento;

    address public recebedorTaxas;
    bool public lancado;
    /// @notice Nº de degraus da escada do lançamento (as primeiras faixas, em ordem de preço).
    uint256 public degrausDaEscada;
    /// @notice Faixa de mercado por tick inicial (índice + 1; 0 = não existe).
    mapping(int24 inicio => uint256) public faixaDeMercado;
    /// @notice Degraus da escada e, depois deles, as faixas de mercado criadas por `pagar`.
    Faixa[] internal faixas;

    uint8 internal constant LANCAR = 1;
    uint8 internal constant COLETAR = 2;
    uint8 internal constant PAGAR = 3;

    error EnderecoDeHookErrado();
    error EnderecoZero();
    error SoLancador();
    error JaLancado();
    error NaoLancado();
    error SoPoolManager();
    error SoRecebedor();
    error SoEstaPool();
    error LiquidezZero(uint256 faixa);
    error SemFaixaAcima();
    error IntervaloInvalido();

    event Lancado(PoolId indexed id, uint256 faixas, uint256 tokens);
    event Pago(address indexed pagador, bytes32 indexed pedido, uint256 valor, uint256 faixa);
    event TaxasColetadas(address indexed para, uint256 emToken, uint256 emMoeda);
    event FaixaDeMercadoCriada(uint256 indexed indice, int24 inferior, int24 superior);
    event RecebedorTransferido(address indexed recebedor);

    constructor(
        IPoolManager _poolManager,
        address _lancador,
        address _token,
        address _moeda,
        int24 _espacamento,
        address _recebedorTaxas
    ) {
        if (uint160(address(this)) & Hooks.ALL_HOOK_MASK != BITS_HOOK) revert EnderecoDeHookErrado();
        if (_lancador == address(0) || _recebedorTaxas == address(0)) revert EnderecoZero();
        poolManager = _poolManager;
        lancador = _lancador;
        token = Currency.wrap(_token);
        moeda = Currency.wrap(_moeda);
        tokenEhMoeda0 = _token < _moeda;
        espacamento = _espacamento;
        recebedorTaxas = _recebedorTaxas;
    }

    function chave() public view returns (PoolKey memory k) {
        (k.currency0, k.currency1) = tokenEhMoeda0 ? (token, moeda) : (moeda, token);
        k.fee = TAXA;
        k.tickSpacing = espacamento;
        k.hooks = IHooks(address(this));
    }

    function todasAsFaixas() external view returns (Faixa[] memory) {
        return faixas;
    }

    // ---------------------------------------------------------------- hook

    /// Só chega aqui quem NÃO é este contrato: recusa.
    function beforeInitialize(address, PoolKey calldata, uint160) external view returns (bytes4) {
        if (msg.sender != address(poolManager)) revert SoPoolManager();
        revert SoEstaPool();
    }

    /// Só chega aqui quem NÃO é este contrato: recusa.
    function beforeAddLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        external
        view
        returns (bytes4)
    {
        if (msg.sender != address(poolManager)) revert SoPoolManager();
        revert SoEstaPool();
    }

    // ------------------------------------------------------------- entrada

    /// @notice Cria a pool no `_tickInicial` (borda do 1º degrau) e deposita todas as faixas.
    /// O lançador aprova antes a soma das faixas (o supply inteiro).
    function lancar(int24 _tickInicial, Faixa[] calldata _faixas) external {
        if (msg.sender != lancador) revert SoLancador();
        if (lancado) revert JaLancado();
        lancado = true;
        degrausDaEscada = _faixas.length;
        uint256 total;
        for (uint256 i; i < _faixas.length; i++) {
            faixas.push(_faixas[i]);
            total += _faixas[i].quantidade;
        }
        IERC20(Currency.unwrap(token)).safeTransferFrom(msg.sender, address(this), total);
        poolManager.unlock(abi.encode(LANCAR, _tickInicial));
        emit Lancado(chave().toId(), _faixas.length, total);
    }

    /// @notice Paga um serviço em SDBR: o valor vira liquidez travada da pool. Puxa de quem
    /// chama só o que foi de fato depositado (<= `_valor`); aprove antes `_valor`.
    function pagar(bytes32 _pedido, uint256 _valor) public {
        if (!lancado) revert NaoLancado();
        bytes memory r = poolManager.unlock(abi.encode(PAGAR, msg.sender, _valor));
        (uint256 faixa, uint256 depositado) = abi.decode(r, (uint256, uint256));
        emit Pago(msg.sender, _pedido, depositado, faixa);
    }

    /// @notice `pagar` com aprovação por assinatura (ERC-2612) numa transação só. Se a
    /// assinatura já tiver sido usada por outro (front-run), segue com a aprovação existente.
    function pagarComPermit(bytes32 _pedido, uint256 _valor, uint256 _prazo, uint8 _v, bytes32 _r, bytes32 _s) external {
        try IERC20Permit(Currency.unwrap(token)).permit(msg.sender, address(this), _valor, _prazo, _v, _r, _s) { } catch { }
        pagar(_pedido, _valor);
    }

    /// @notice Qualquer um pode chamar; as taxas vão sempre para `recebedorTaxas`.
    function coletarTaxas() external {
        poolManager.unlock(abi.encode(COLETAR, uint256(0), faixas.length));
    }

    /// @notice Coleta só das faixas [de, ate) — para dividir a coleta se houver muitas
    /// faixas de mercado.
    function coletarTaxasFaixas(uint256 _de, uint256 _ate) external {
        if (_de >= _ate || _ate > faixas.length) revert IntervaloInvalido();
        poolManager.unlock(abi.encode(COLETAR, _de, _ate));
    }

    function transferirRecebedor(address _novo) external {
        if (msg.sender != recebedorTaxas) revert SoRecebedor();
        if (_novo == address(0)) revert EnderecoZero();
        recebedorTaxas = _novo;
        emit RecebedorTransferido(_novo);
    }

    // ------------------------------------------------------------ callback

    function unlockCallback(bytes calldata _dados) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert SoPoolManager();
        uint8 op = uint8(_dados[31]);
        if (op == COLETAR) {
            (, uint256 de, uint256 ate) = abi.decode(_dados, (uint8, uint256, uint256));
            _coletar(de, ate);
            return "";
        }
        if (op == PAGAR) {
            (, address pagador, uint256 valor) = abi.decode(_dados, (uint8, address, uint256));
            (uint256 faixa, uint256 depositado) = _depositar(pagador, valor);
            return abi.encode(faixa, depositado);
        }
        (, int24 tickInicial) = abi.decode(_dados, (uint8, int24));
        _lancar(TickMath.getSqrtPriceAtTick(tickInicial));
        return "";
    }

    function _lancar(uint160 _sqrtInicial) internal {
        PoolKey memory k = chave();
        // Só este contrato inicializa (o hook recusa os outros): a pool é nova.
        poolManager.initialize(k, _sqrtInicial);
        for (uint256 i; i < faixas.length; i++) {
            _adicionar(k, i, faixas[i].quantidade);
        }
        _quitarToken(address(this));
    }

    /// Deposita `_valor` de token do pagador no 1º degrau inteiro acima do preço atual.
    /// O cliente paga só o PRINCIPAL; as taxas que a posição tinha acumulado (que o v4
    /// entrega junto ao adicionar liquidez) vão, na mesma operação, para `recebedorTaxas`.
    function _depositar(address _pagador, uint256 _valor) internal returns (uint256 idx, uint256 depositado) {
        PoolKey memory k = chave();
        idx = _proximaFaixaAcima(k);
        depositado = _adicionar(k, idx, _valor);
        poolManager.sync(token);
        IERC20(Currency.unwrap(token)).safeTransferFrom(_pagador, address(poolManager), depositado);
        poolManager.settle();
        _sacar(token);
        _sacar(moeda);
    }

    /// Índice da 1ª faixa da escada inteira do lado do token (acima do preço, em preço do
    /// token). Se o preço já passou de todos os degraus, a faixa de mercado do próximo
    /// múltiplo de DOBRA acima do preço (criada na primeira vez que for usada).
    function _proximaFaixaAcima(PoolKey memory _k) internal returns (uint256) {
        (uint160 atual, int24 tk,,) = poolManager.getSlot0(_k.toId());
        uint256 n = degrausDaEscada;
        for (uint256 i; i < n; i++) {
            Faixa memory f = faixas[i];
            bool inteira = tokenEhMoeda0
                ? atual <= TickMath.getSqrtPriceAtTick(f.inferior)
                : atual >= TickMath.getSqrtPriceAtTick(f.superior);
            if (inteira) return i;
        }
        return _faixaDeMercado(tk, faixas[n - 1]);
    }

    function _faixaDeMercado(int24 _tk, Faixa memory _topo) internal returns (uint256 idx) {
        int24 limite = (TickMath.MAX_TICK / espacamento) * espacamento;
        Faixa memory f;
        int24 inicio;
        if (tokenEhMoeda0) {
            // 1º múltiplo de DOBRA (a partir do início do último degrau) estritamente acima do preço
            int24 base = _tk > _topo.inferior ? _tk : _topo.inferior;
            inicio = _topo.inferior + ((base - _topo.inferior) / DOBRA + 1) * DOBRA;
            if (inicio >= limite) revert SemFaixaAcima();
            (f.inferior, f.superior) = (inicio, limite);
        } else {
            // espelhado: preço do token sobe quando o tick desce
            int24 base = _tk < _topo.superior ? _tk : _topo.superior;
            inicio = _topo.superior - ((_topo.superior - base + DOBRA - 1) / DOBRA) * DOBRA;
            if (inicio == _topo.superior) inicio -= DOBRA;
            if (inicio <= -limite) revert SemFaixaAcima();
            (f.inferior, f.superior) = (-limite, inicio);
        }
        idx = faixaDeMercado[inicio];
        if (idx != 0) return idx - 1;
        faixas.push(f);
        idx = faixas.length - 1;
        faixaDeMercado[inicio] = idx + 1;
        emit FaixaDeMercadoCriada(idx, f.inferior, f.superior);
    }

    /// Adiciona liquidez para `_quantidade` de token na faixa `_i`; devolve o principal devido.
    function _adicionar(PoolKey memory _k, uint256 _i, uint256 _quantidade) internal returns (uint256 principal) {
        Faixa memory f = faixas[_i];
        uint160 a = TickMath.getSqrtPriceAtTick(f.inferior);
        uint160 b = TickMath.getSqrtPriceAtTick(f.superior);
        uint128 liq = tokenEhMoeda0
            ? LiquidityAmounts.getLiquidityForAmount0(a, b, _quantidade)
            : LiquidityAmounts.getLiquidityForAmount1(a, b, _quantidade);
        if (liq == 0) revert LiquidezZero(_i);
        (BalanceDelta chamador, BalanceDelta taxas) =
            poolManager.modifyLiquidity(_k, ModifyLiquidityParams(f.inferior, f.superior, int256(uint256(liq)), 0), "");
        BalanceDelta p = chamador - taxas;
        principal = uint256(uint128(-(tokenEhMoeda0 ? p.amount0() : p.amount1())));
    }

    /// Paga ao PoolManager o token devido, vindo de `_de` (este contrato ou o pagador).
    function _quitarToken(address _de) internal returns (uint256 devido) {
        int256 d = poolManager.currencyDelta(address(this), token);
        if (d >= 0) return 0;
        devido = uint256(-d);
        poolManager.sync(token);
        if (_de == address(this)) IERC20(Currency.unwrap(token)).safeTransfer(address(poolManager), devido);
        else IERC20(Currency.unwrap(token)).safeTransferFrom(_de, address(poolManager), devido);
        poolManager.settle();
    }

    function _coletar(uint256 _de, uint256 _ate) internal {
        PoolKey memory k = chave();
        for (uint256 i = _de; i < _ate; i++) {
            // liquidez 0 = só "cutuca" a posição: as taxas acumuladas viram saldo a sacar.
            poolManager.modifyLiquidity(k, ModifyLiquidityParams(faixas[i].inferior, faixas[i].superior, 0, 0), "");
        }
        uint256 emToken = _sacar(token);
        uint256 emMoeda = _sacar(moeda);
        emit TaxasColetadas(recebedorTaxas, emToken, emMoeda);
    }

    function _sacar(Currency _c) internal returns (uint256 v) {
        int256 d = poolManager.currencyDelta(address(this), _c);
        if (d > 0) {
            v = uint256(d);
            poolManager.take(_c, recebedorTaxas, v);
        }
    }
}

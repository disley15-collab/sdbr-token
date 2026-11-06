// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { Script, console2 } from "forge-std/Script.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { TimelockController } from "@openzeppelin/contracts/governance/TimelockController.sol";
import { ILayerZeroEndpointV2 } from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroEndpointV2.sol";
import { SetConfigParam } from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/IMessageLibManager.sol";
import { UlnConfig } from "@layerzerolabs/lz-evm-messagelib-v2/contracts/uln/UlnBase.sol";
import { ExecutorConfig } from "@layerzerolabs/lz-evm-messagelib-v2/contracts/SendLibBase.sol";
import { EnforcedOptionParam } from "@layerzerolabs/oapp-evm/contracts/oapp/interfaces/IOAppOptionsType3.sol";
import { IPoolManager } from "v4-core/interfaces/IPoolManager.sol";
import { SDBR } from "../src/SDBR.sol";
import { PoolTravada } from "../src/PoolTravada.sol";
import { ICreateX } from "../src/ICreateX.sol";

interface IUlnLeitura {
    function getUlnConfig(address oapp, uint32 eid) external view returns (UlnConfig memory);
    function getExecutorConfig(address oapp, uint32 eid) external view returns (ExecutorConfig memory);
}

/// Publica o SDBR numa rede.
///
/// Todas as redes: token no MESMO endereço (CreateX CREATE3, mesmo código e mesmos
/// argumentos em toda rede — o supply só nasce na BSC, regra do próprio token),
/// liga as outras redes, FIXA a configuração da ponte (bibliotecas, verificadores,
/// executor e gás mínimo de entrega) e entrega dono + delegate a um Timelock de 7 dias.
///
/// BSC: também publica a PoolTravada (que é o hook da pool) e lança a escada com a
/// lançamento numa transação; os 10% de crédito só saem depois do lançamento.
///
/// env: SDBR_PK, SALT, SALT_POOL, DONO, URI, DOC_HASH (keccak do JSON), EIDS (outras redes, por vírgula)
///      e, na BSC: PM, MOEDA, ESCADA (json do script/escada.py)
contract Publicar is Script {
    address constant CREATEX = 0xba5Ed099633D3B313e4D5F7bdc1305d3c28ba5Ed;
    address constant EP = 0x1a44076050125825900e736c501f859c50fE728c;
    uint256 constant ATRASO_TIMELOCK = 7 days;
    uint128 constant GAS_ENTREGA = 150_000; // lzReceive do OFT ~51k (medido) + endpoint (nonce, compose) com folga
    uint8 constant NIL_DVN = type(uint8).max;

    function run() external {
        uint256 pk = vm.envUint("SDBR_PK");
        address eu = vm.addr(pk);
        address dono = vm.envAddress("DONO");
        uint256[] memory outras = vm.envUint("EIDS", ",");
        uint32[] memory eids = new uint32[](outras.length);
        for (uint256 i; i < outras.length; i++) eids[i] = uint32(outras[i]);

        vm.startBroadcast(pk);

        // Retomável: cada passo é pulado se já foi feito (rodar de novo depois de uma falha).
        bytes32 salt = vm.envBytes32("SALT");
        SDBR token = SDBR(ICreateX(CREATEX).computeCreate3Address(keccak256(abi.encode(eu, salt))));
        if (address(token).code.length == 0) {
            bytes memory init = abi.encodePacked(
                type(SDBR).creationCode,
                abi.encode("Solidity Brasil", "SDBR", EP, eu, eu, vm.envString("URI"), vm.envBytes32("DOC_HASH"))
            );
            require(ICreateX(CREATEX).deployCreate3(salt, init) == address(token), "endereco do token");
        }
        console2.log("token", address(token));

        if (token.owner() == eu) {
            if (!_redesLigadas(token, eids)) token.ligarRedesEVM(eids);
            _fixarPonte(token, eids);
            if (block.chainid == token.REDE_CASA()) _lancarNaCasa(token, eu, dono);

            address[] memory propoe = new address[](1);
            propoe[0] = dono;
            address[] memory executa = new address[](1); // address(0) = qualquer um executa depois do prazo
            TimelockController tl = new TimelockController(ATRASO_TIMELOCK, propoe, executa, address(0));
            token.setDelegate(address(tl));
            token.transferOwnership(address(tl));
            console2.log("timelock", address(tl));
        }

        vm.stopBroadcast();
    }

    /// Grava explicitamente a configuração que hoje é o padrão da LayerZero: depois
    /// disso, mudança no padrão deles não afeta o SDBR; só o Timelock muda.
    function _fixarPonte(SDBR _token, uint32[] memory _eids) internal {
        ILayerZeroEndpointV2 ep = ILayerZeroEndpointV2(EP);
        EnforcedOptionParam[] memory opts = new EnforcedOptionParam[](_eids.length * 2);
        uint256 n; // só as redes configuradas NESTA execução (retomável)
        bytes memory gas = abi.encodePacked(uint16(3), uint8(1), uint16(17), uint8(1), GAS_ENTREGA);
        for (uint256 i; i < _eids.length; i++) {
            uint32 e = _eids[i];
            if (!ep.isDefaultSendLibrary(address(_token), e)) continue; // já fixada
            address envio = ep.getSendLibrary(address(_token), e);
            address recebe = ep.defaultReceiveLibrary(e);
            ep.setSendLibrary(address(_token), e, envio);
            ep.setReceiveLibrary(address(_token), e, recebe, 0);

            SetConfigParam[] memory pe = new SetConfigParam[](2);
            pe[0] = SetConfigParam(e, 1, abi.encode(IUlnLeitura(envio).getExecutorConfig(address(_token), e)));
            pe[1] = SetConfigParam(e, 2, abi.encode(_explicita(IUlnLeitura(envio).getUlnConfig(address(_token), e))));
            ep.setConfig(address(_token), envio, pe);

            SetConfigParam[] memory pr = new SetConfigParam[](1);
            pr[0] = SetConfigParam(e, 2, abi.encode(_explicita(IUlnLeitura(recebe).getUlnConfig(address(_token), e))));
            ep.setConfig(address(_token), recebe, pr);

            opts[n++] = EnforcedOptionParam(e, 1, gas); // SEND
            opts[n++] = EnforcedOptionParam(e, 2, gas); // SEND_AND_CALL
        }
        if (n == 0) return;
        assembly { mstore(opts, n) } // encolhe o array para as entradas preenchidas
        _token.setEnforcedOptions(opts);
    }

    function _redesLigadas(SDBR _token, uint32[] memory _eids) internal view returns (bool) {
        for (uint256 i; i < _eids.length; i++) {
            if (_token.peers(_eids[i]) != bytes32(uint256(uint160(address(_token))))) return false;
        }
        return true;
    }

    /// Na ULN, contagem 0 significa "use o padrão": troca por NIL para fixar "nenhum".
    /// Verificadores obrigatórios e confirmações têm de vir preenchidos (0 = padrão).
    function _explicita(UlnConfig memory c) internal pure returns (UlnConfig memory) {
        require(c.confirmations > 0 && c.requiredDVNCount > 0 && c.requiredDVNCount != NIL_DVN, "ULN sem padrao fixavel");
        if (c.optionalDVNCount == 0) {
            c.optionalDVNCount = NIL_DVN;
            c.optionalDVNThreshold = 0;
        }
        return c;
    }

    function _lancarNaCasa(SDBR _token, address _eu, address _dono) internal {
        string memory json = vm.readFile(vm.envString("ESCADA"));
        address moeda = vm.envAddress("MOEDA");
        _dono; // as taxas vão para o dono (recebedorTaxas, no construtor da pool)

        bytes memory initPool = abi.encodePacked(
            type(PoolTravada).creationCode,
            abi.encode(IPoolManager(vm.envAddress("PM")), _eu, address(_token), moeda, int24(10), _dono)
        );
        bytes32 saltPool = vm.envBytes32("SALT_POOL");
        PoolTravada pool = PoolTravada(ICreateX(CREATEX).computeCreate3Address(keccak256(abi.encode(_eu, saltPool))));
        if (address(pool).code.length == 0) {
            require(ICreateX(CREATEX).deployCreate3(saltPool, initPool) == address(pool), "endereco da pool");
        }

        int256[] memory inf = vm.parseJsonIntArray(json, ".inferiores");
        int256[] memory sup = vm.parseJsonIntArray(json, ".superiores");
        uint256[] memory q = vm.parseJsonUintArray(json, ".quantidades");
        PoolTravada.Faixa[] memory fx = new PoolTravada.Faixa[](q.length);
        uint256 naPool;
        for (uint256 i; i < q.length; i++) {
            fx[i] = PoolTravada.Faixa(int24(inf[i]), int24(sup[i]), q[i]);
            naPool += q[i];
        }
        // A escada tem de ter sido gerada para ESTE token, ESTA moeda e ESTE espaçamento.
        require(vm.parseJsonBool(json, ".tokenEhMoeda0") == pool.tokenEhMoeda0(), "escada: ordem do par");
        require(vm.parseJsonUint(json, ".espacamento") == uint256(uint24(pool.espacamento())), "escada: espacamento");
        require(naPool == _token.SUPPLY(), "escada: soma != supply");

        if (!pool.lancado()) {
            _token.approve(address(pool), naPool);
            pool.lancar(int24(vm.parseJsonInt(json, ".tickInicial")), fx);
        }
        require(_token.balanceOf(_eu) == 0, "sobrou SDBR na carteira de publicacao");

        console2.log("pool/hook", address(pool));
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { ERC20Permit } from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import { OFT } from "@layerzerolabs/oft-evm/contracts/OFT.sol";

/// @title SDBR — token da Solidity Brasil
/// @notice O mesmo endereço em toda rede EVM (CreateX CREATE3, mesmo código e mesmos
/// argumentos em toda rede).
///
/// @dev Invariantes (provados em test/):
/// 1. Supply fixo: `SUPPLY` é criado UMA vez, no construtor, e SÓ na BNB Smart Chain
///    (`REDE_CASA`, fixo no código). Não existe função de emitir, queimar, congelar,
///    pausar, taxar transferência nem renomear. Nas outras redes o supply nasce 0 e o
///    token só chega pela ponte LayerZero (queima na origem, cria no destino): o total
///    somado das redes nunca muda.
/// 2. ERC-20 puro (OpenZeppelin 5) + ERC-2612 `permit` + EIP-5267 `eip712Domain`:
///    nenhuma regra própria em transfer/transferFrom/approve.
/// 3. Poderes que restam, todos da ponte: o dono (ligar rede, opções, inspetor de
///    mensagens) e o delegate no endpoint LayerZero (bibliotecas e verificadores).
///    Mudar a ponte equivale a poder emitir, por isso os dois ficam num Timelock de
///    7 dias. Para renunciar de vez: primeiro setDelegate(address(0)), depois
///    renounceOwnership() — só renunciar o dono NÃO tira o delegate.
///
/// 9 casas: com 1 sextilhão de tokens o supply em unidades cabe no int128 do Uniswap v4
/// (com 18 casas, 1e39 estoura o limite de 1,7e38). Casas compartilhadas da ponte = 0:
/// cada envio cabe no uint64 da LayerZero (até 1,8e19 tokens por envio).
contract SDBR is OFT, ERC20Permit {
    /// @notice Endereço do JSON com documentação técnica, empresa, endereço, telefone e
    /// suporte (ERC-7572).
    string public contractURI;

    /// @notice keccak256 do arquivo de documentação no momento da publicação. O conteúdo
    /// do `contractURI` pode ser atualizado; este hash é imutável e prova qual era a
    /// versão original (qualquer um confere com `cast keccak` no arquivo).
    bytes32 public immutable documentacaoHash;

    /// @notice 1 sextilhão de tokens (9 casas).
    uint256 public constant SUPPLY = 1e21 * 1e9;
    /// @notice Única rede onde o supply é criado: BNB Smart Chain.
    uint256 public constant REDE_CASA = 56;

    constructor(
        string memory _nome,
        string memory _simbolo,
        address _endpoint,
        address _dono,
        address _recebedorDoSupply,
        string memory _contractURI,
        bytes32 _documentacaoHash
    ) OFT(_nome, _simbolo, _endpoint, _dono) ERC20Permit(_nome) Ownable(_dono) {
        contractURI = _contractURI;
        documentacaoHash = _documentacaoHash;
        if (block.chainid == REDE_CASA) _mint(_recebedorDoSupply, SUPPLY);
    }

    function decimals() public pure override returns (uint8) {
        return 9;
    }

    function sharedDecimals() public pure override returns (uint8) {
        return 0;
    }

    /// @notice Liga várias redes de uma vez: em rede EVM o par é este mesmo endereço.
    function ligarRedesEVM(uint32[] calldata _eids) external onlyOwner {
        bytes32 eu = bytes32(uint256(uint160(address(this))));
        for (uint256 i; i < _eids.length; i++) _setPeer(_eids[i], eu);
    }
}

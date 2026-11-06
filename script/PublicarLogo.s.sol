// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { Script, console2 } from "forge-std/Script.sol";
import { LogoSDBR } from "../src/LogoSDBR.sol";
import { ICreateX } from "../src/ICreateX.sol";

/// Publica o LogoSDBR no mesmo endereço em toda rede (CreateX CREATE3). Retomável.
/// env: SDBR_PK, SALT_LOGO
contract PublicarLogo is Script {
    address constant CREATEX = 0xba5Ed099633D3B313e4D5F7bdc1305d3c28ba5Ed;

    function run() external {
        uint256 pk = vm.envUint("SDBR_PK");
        bytes32 salt = vm.envBytes32("SALT_LOGO");
        address alvo = ICreateX(CREATEX).computeCreate3Address(keccak256(abi.encode(vm.addr(pk), salt)));
        console2.log("logo", alvo);
        if (alvo.code.length > 0) return;
        vm.startBroadcast(pk);
        require(ICreateX(CREATEX).deployCreate3(salt, type(LogoSDBR).creationCode) == alvo, "endereco");
        vm.stopBroadcast();
    }
}

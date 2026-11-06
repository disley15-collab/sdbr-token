// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { Test } from "forge-std/Test.sol";
import { LogoSDBR } from "../src/LogoSDBR.sol";

contract LogoSDBRTest is Test {
    function test_svgIgualAoArquivoOficial() public {
        LogoSDBR l = new LogoSDBR();
        bytes memory arquivo = vm.readFileBinary("marca/sdbr-logo.svg");
        assertEq(bytes(l.svg()), arquivo, "byte a byte igual ao arquivo");
        assertEq(l.hashSvg(), keccak256(arquivo));
        assertEq(l.TOKEN(), 0x00000000001C77283FDB79c1D012930C3c987cbc);
        assertEq(bytes(l.imagem()).length > 1300, true);
        emit log_named_uint("tamanho do contrato (bytes)", address(l).code.length);
    }
}

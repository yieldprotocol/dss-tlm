// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.6.10;

interface DssTlmAbstract {
    function init(bytes32 ilk, address gemJoin, uint256 yield) external;
    function file(bytes32 ilk, bytes32 what, uint256 data) external;
    function hope(address usr) external;
    function nope(address usr) external;
    function sellGem(bytes32 ilk, address usr, uint256 gemAmt) external;
    function buyGem(bytes32 ilk, address usr, uint256 amt) external;
}
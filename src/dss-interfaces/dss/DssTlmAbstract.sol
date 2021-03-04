// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.6.10;

import "./VatAbstract.sol";
import "./DaiJoinAbstract.sol";
import "./DaiAbstract.sol";

interface DssTlmAbstract {
	mapping (address => uint256) public wards;
    function rely(address usr) external;
    function deny(address usr) external;
    VatAbstract immutable public vat;
    DaiJoinAbstract immutable public daiJoin;
    DaiAbstract immutable public dai;
    address immutable public vow;
    mapping (bytes32 => Ilk) public ilks; // Registered maturing gems

    function init(bytes32 ilk, address gemJoin, uint256 yield) external;
    function file(bytes32 ilk, bytes32 what, uint256 data) external;
    function hope(address usr) external;
    function nope(address usr) external;
    function sellGem(bytes32 ilk, address usr, uint256 gemAmt) external;
    function buyGem(bytes32 ilk, address usr, uint256 amt) external;
}
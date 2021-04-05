pragma solidity >=0.6.5;

import { DaiJoinAbstract } from "./dss-interfaces/dss/DaiJoinAbstract.sol";
import { DaiAbstract } from "./dss-interfaces/dss/DaiAbstract.sol";
import { VatAbstract } from "./dss-interfaces/dss/VatAbstract.sol";

interface DssTlmAbstract {
    function wards(address) external view returns (uint256);
    function rely(address usr) external;
    function deny(address usr) external;
    function vat() external view returns (VatAbstract);
    function daiJoin() external view returns (DaiJoinAbstract);
    function dai() external view returns (DaiAbstract);
    function vow() external view returns (address);
    function ilks(bytes32) external view returns(address, uint256); // Registered maturing gems

    function init(bytes32 ilk, address gemJoin, uint256 yield) external;
    function file(bytes32 ilk, bytes32 what, uint256 data) external;
    function hope(address usr) external;
    function nope(address usr) external;
    function sellGem(bytes32 ilk, address usr, uint256 gemAmt) external;
    function buyGem(bytes32 ilk, address usr, uint256 amt) external;
}
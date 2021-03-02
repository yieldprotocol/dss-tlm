pragma solidity ^0.6.10;
import "./AuthGemJoinAbstract.sol";
import "./DaiJoinAbstract.sol";


interface DssTlmAbstract {
    //todo: remove unneeded functions here
    function gemJoin() external view returns(AuthGemJoinAbstract);
    function daiJoin() external view returns(DaiJoinAbstract);
    function tin() external view returns(uint256);
    function tout() external view returns(uint256);
    function file(bytes32 what, uint256 data) external;
    function sellGem(address usr, uint256 gemAmt) external;
    function buyGem(address usr, uint256 gemAmt) external;
}

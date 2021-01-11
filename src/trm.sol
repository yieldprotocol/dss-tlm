pragma solidity ^0.6.7;

import { DaiJoinAbstract } from "dss-interfaces/dss/DaiJoinAbstract.sol";
import { DaiAbstract } from "dss-interfaces/dss/DaiAbstract.sol";
import { VatAbstract } from "dss-interfaces/dss/VatAbstract.sol";

interface AuthGemJoinAbstract {
    function dec() external view returns (uint256);
    function ilk() external view returns (bytes32);
    function gem() external view returns (address);
    function join(address, uint256, address) external;
}

interface FYDaiAbstract {
    function maturity() external view returns (uint256);
}

// Term Rates Module
// Allows anyone to go sell fyDai at a maturity-adjusted price

contract DssTrm {

    // --- Auth ---
    mapping (address => uint256) public wards;
    function rely(address usr) external auth { wards[usr] = 1; emit Rely(usr); }
    function deny(address usr) external auth { wards[usr] = 0; emit Deny(usr); }
    modifier auth { require(wards[msg.sender] == 1); _; }

    // --- Data ---
    struct Ilk {
        address gemJoin;
        uint256 art;                 // Current Debt              [wad]
        uint256 line;                 // Debt Ceiling              [rad]
        uint256 yield;                // Target yield, per second  [ray]
        uint256 to18ConversionFactor; // Multiplier to WAD         [uint]
    }

    VatAbstract immutable public vat;
    DaiJoinAbstract immutable public daiJoin;

    mapping (bytes32 => Ilk) public ilks;

    // --- Events ---
    event Rely(address indexed usr);
    event Deny(address indexed usr);
    event File(bytes32 indexed what, uint256 data);
    event SellGem(address indexed owner, uint256 gem, uint256 dai);

    // --- Init ---
    constructor(address daiJoin_) public {
        wards[msg.sender] = 1;
        emit Rely(msg.sender);
        // AuthGemJoinAbstract gemJoin__ = gemJoin = AuthGemJoinAbstract(gemJoin_);
        DaiJoinAbstract daiJoin__ = daiJoin = DaiJoinAbstract(daiJoin_);
        VatAbstract vat__ = vat = VatAbstract(address(daiJoin__.vat()));
        DaiAbstract dai__ = DaiAbstract(address(daiJoin__.dai()));
        
        dai__.approve(daiJoin_, uint256(-1));
        vat__.hope(daiJoin_);
    }

    // --- Math ---
    uint256 constant WAD = 10 ** 18;
    uint256 constant RAY = 10 ** 27;

    function rpow(uint x, uint n, uint base) internal pure returns (uint z) {
        assembly {
            switch x case 0 {switch n case 0 {z := base} default {z := 0}}
            default {
                switch mod(n, 2) case 0 { z := base } default { z := x }
                let half := div(base, 2)  // for rounding.
                for { n := div(n, 2) } n { n := div(n,2) } {
                    let xx := mul(x, x)
                    if iszero(eq(div(xx, x), x)) { revert(0,0) }
                    let xxRound := add(xx, half)
                    if lt(xxRound, xx) { revert(0,0) }
                    x := div(xxRound, base)
                    if mod(n,2) {
                        let zx := mul(z, x)
                        if and(iszero(iszero(x)), iszero(eq(div(zx, x), z))) { revert(0,0) }
                        let zxRound := add(zx, half)
                        if lt(zxRound, zx) { revert(0,0) }
                        z := div(zxRound, base)
                    }
                }
            }
        }
    }

    function add(uint256 x, uint256 y) internal pure returns (uint256 z) {
        require((z = x + y) >= x);
    }
    function sub(uint256 x, uint256 y) internal pure returns (uint256 z) {
        require((z = x - y) <= x);
    }
    function mul(uint256 x, uint256 y) internal pure returns (uint256 z) {
        require(y == 0 || (z = x * y) / y == x);
    }
    //rounds to zero if x*y < WAD / 2
    function rmul(uint x, uint y) internal pure returns (uint z) {
        z = add(mul(x, y), RAY / 2) / RAY;
    }
    //rounds to zero if x*y < RAY / 2
    function rdiv(uint x, uint y) internal pure returns (uint z) {
        z = add(mul(x, RAY), y / 2) / y;
    }

    // --- Administration ---
    function init(bytes32 ilk, address gemJoin) external note auth {
        require(ilks[ilk].gemJoin == address(0), "DssTrm/ilk-already-init");
        ilks[ilk].gemJoin = gemJoin;
        ilks[ilk].to18ConversionFactor = 10 ** (18 - AuthGemJoinAbstract(gemJoin).dec());
    }

    function file(bytes32 what, uint256 data) external auth {
        if (what == "line") ilks[ilk].line = data;
        else if (what == "yield") ilks[ilk].yield = data;
        else revert("DssTrm/file-unrecognized-param");

        emit File(what, data);
    }

    // hope can be used to transfer control of the PSM vault to another contract
    // This can be used to upgrade the contract
    function hope(address usr) external auth {
        vat.hope(usr);
    }
    function nope(address usr) external auth {
        vat.nope(usr);
    }

    // --- Primary Functions ---
    function sellGem(bytes32 ilk, address usr, uint256 gemAmt) external {
        AuthGemJoinAbstract gemJoin = AuthGemJoinAbstract(ilks[ilk].gemJoin);
        FYDaiAbstract fyDai = IFYDai(address(gemJoin.gem()));
        uint256 gemAmt18 = mul(gemAmt, to18ConversionFactor);
        uint256 time = fyDai.maturity().sub(block.timestamp); // Reverts after maturity
        uint256 price = rdiv(RAY, rpow(add(RAY, ilks[ilk].yield), time, RAY));
        uint256 daiAmt = rmul(gemAmt18, price);
        ilks[ilk].art = add(ilks[ilk].art, daiAmt);
        require(mul(ilks[ilk].art, RAY) <= ilks[ilk].line, "DssTrm/ceiling-exceeded");
        
        // Don't we need to `transferFrom` the fyDai from `msg.sender`?
        gemJoin.join(address(this), gemAmt, msg.sender);
        vat.frob(ilk, address(this), address(this), address(this), int256(gemAmt18), int256(daiAmt));
        daiJoin.exit(usr, daiAmt);

        emit SellGem(usr, gemAmt, daiAmt);
    }
}

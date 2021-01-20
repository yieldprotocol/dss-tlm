pragma solidity ^0.6.7;

import { DaiJoinAbstract } from "./dss-interfaces/dss/DaiJoinAbstract.sol";
import { DaiAbstract } from "./dss-interfaces/dss/DaiAbstract.sol";
import { VatAbstract } from "./dss-interfaces/dss/VatAbstract.sol";
import { LibNote } from "./dss/lib.sol";

/// @dev A GemJoin with restricted `join` access.
interface AuthGemJoinAbstract {
    function ilk() external view returns (bytes32);
    function gem() external view returns (MaturingGemAbstract);
    function join(address, uint256) external;
    function exit(address, uint256) external;
}

/// @dev An ERC20 that can mature and be redeemed, such as fyDai
interface MaturingGemAbstract {
    function approve(address spender, uint256 amount) external returns (bool);
    function balanceOf(address usr) external view returns (uint256);
    function maturity() external view returns (uint256);
    function transferFrom(address src, address dst, uint wad) external returns (bool);
    function redeem(address src, address dst, uint256 amount) external returns (uint256);
}

/// @title Term Lending Module
/// @dev Allows anyone to sell fyDai to MakerDao at a price determined from a governance
/// controlled interest rate.
contract DssTlm is LibNote {

    // --- Auth ---
    mapping (address => uint256) public wards;
    function rely(address usr) external auth { wards[usr] = 1; emit Rely(usr); }
    function deny(address usr) external auth { wards[usr] = 0; emit Deny(usr); }
    modifier auth { require(wards[msg.sender] == 1); _; }

    // --- Events ---
    event Rely(address indexed usr);
    event Deny(address indexed usr);

    // --- Data ---
    struct Ilk {
        address gemJoin;
        uint256 yield;                // Target yield per second  [wad]
    }

    VatAbstract immutable public vat;
    DaiJoinAbstract immutable public daiJoin;
    DaiAbstract immutable public dai;
    address immutable public vow;

    mapping (bytes32 => Ilk) public ilks; // Registered maturing gems

    // --- Init ---
    constructor(address daiJoin_, address vow_) public {
        wards[msg.sender] = 1;
        emit Rely(msg.sender);
        // AuthGemJoinAbstract gemJoin__ = gemJoin = AuthGemJoinAbstract(gemJoin_);
        DaiJoinAbstract daiJoin__ = daiJoin = DaiJoinAbstract(daiJoin_);
        VatAbstract vat__ = vat = VatAbstract(address(daiJoin__.vat()));
        DaiAbstract dai__ = dai = DaiAbstract(address(daiJoin__.dai()));
        vow = vow_;

        dai__.approve(daiJoin_, uint256(-1));
        vat__.hope(daiJoin_);
    }

    // --- Math ---
    uint256 constant WAD = 10 ** 18;
    uint256 constant RAY = 10 ** 27;

    /// @dev Power of a base-decimal x to an integer n.
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

    /// @dev Convert a wad to a ray
    function ray(uint256 wad) internal pure returns (uint256) {
        return wad * 1e9;
    }
    /// @dev Convert a wad to a rad
    function rad(uint256 wad) internal pure returns (uint256) {
        return wad * RAY;
    }
    /// @dev Overflow-protected x + y
    function add(uint256 x, uint256 y) internal pure returns (uint256 z) {
        require((z = x + y) >= x, "DssTlm/add-overflow");
    }
    /// @dev Overflow-protected x - y
    function sub(uint256 x, uint256 y) internal pure returns (uint256 z) {
        require((z = x - y) <= x, "DssTlm/sub-overflow");
    }
    /// @dev Overflow-protected x * y
    function mul(uint256 x, uint256 y) internal pure returns (uint256 z) {
        require(y == 0 || (z = x * y) / y == x, "DssTlm/mul-overflow");
    }
    /// @dev x * y, where x is a decimal of base RAY. Rounds to zero if x*y < WAD / 2
    function rmul(uint x, uint y) internal pure returns (uint z) {
        z = add(mul(x, y), RAY / 2) / RAY;
    }
    /// @dev x / y, where x is a decimal of base RAY. Rounds to zero if x*y < RAY / 2
    function rdiv(uint x, uint y) internal pure returns (uint z) {
        z = add(mul(x, RAY), y / 2) / y;
    }

    // --- Administration ---
    /// @dev Add a maturing gem to DssTlm.
    /// A gemJoin ward must call `gemJoin.rely(address(tlm))` as well.
    function init(bytes32 ilk, address gemJoin, uint256 yield) external note auth {
        require(ilks[ilk].gemJoin == address(0), "DssTlm/ilk-already-init");
        ilks[ilk].gemJoin = gemJoin;
        ilks[ilk].yield = yield;

        AuthGemJoinAbstract(gemJoin).gem().approve(gemJoin, uint256(-1));
    }

    /// @dev Set up the ceiling debt or target yield for a maturing gem.
    function file(bytes32 ilk, bytes32 what, uint256 data) external note auth {
        if (what == "yield") ilks[ilk].yield = data; // 5% per year is 0.05 * RAY / seconds_in_a_year, or about 1585e15.
        else revert("DssTlm/file-unrecognized-param");
    }

    // hope can be used to transfer control of the TLM vault to another contract
    // This can be used to upgrade the contract
    function hope(address usr) external note auth {
        vat.hope(usr);
    }
    function nope(address usr) external note auth {
        vat.nope(usr);
    }

    // --- Primary Functions ---
    /// @dev Sell maturing gems to DssTlm and receive Dai in exchange
    function sellGem(bytes32 ilk, address usr, uint256 gemAmt) external note {
        AuthGemJoinAbstract gemJoin = AuthGemJoinAbstract(ilks[ilk].gemJoin);
        MaturingGemAbstract gem = gemJoin.gem();
        uint256 time = sub(gem.maturity(), block.timestamp); // Reverts after maturity
        uint256 price = rdiv(RAY, rpow(add(RAY, ilks[ilk].yield), time, RAY));
        uint256 daiAmt = rmul(gemAmt, price);

        gem.transferFrom(msg.sender, address(this), gemAmt);
        gemJoin.join(address(this), gemAmt);
        vat.frob(ilk, address(this), address(this), address(this), int256(gemAmt), int256(daiAmt));
        daiJoin.exit(usr, daiAmt);
    }

    /// @dev After maturity, redeem into Dai the maturing gems held by DssTlm, pay any debt to Vat, and send any surplus to Vow
    function redeemGem(bytes32 ilk) external note {
        AuthGemJoinAbstract gemJoin = AuthGemJoinAbstract(ilks[ilk].gemJoin);
        MaturingGemAbstract gem = gemJoin.gem();
        require(block.timestamp >= gem.maturity(), "DssTlm/not-mature");

        // grab fydai and redeem into dai
        (uint256 ink, uint256 art) = vat.urns(ilk, address(this));
        vat.grab(ilk, address(this), address(this), address(this), -int(ink), -int(art));
        gemJoin.exit(address(this), ink);
        gem.redeem(address(this), address(this), ink);

        // repay debt
        daiJoin.join(address(this), dai.balanceOf(address(this)));
        vat.heal(vat.sin(address(this)));

        // collect surplus in vow
        vat.move(address(this), vow, vat.dai(address(this)));
    }
}

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

/// @dev An ERC3156 Flash Lender
interface FlashAbstract {
    function maxFlashAmount(address token) external view returns (uint256);
    function flashFee(address token, uint256 amount) external view returns (uint256);
    function flashLoan(address receiver, address token, uint256 amount, bytes calldata data) external;
}

/// @title Term Lending Module
/// @dev Allows anyone to go sell a maturity gem to the TLM at a maturity-adjusted price
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
        uint256 art;                  // Current Debt             [wad]
        uint256 line;                 // Debt Ceiling             [rad]
        uint256 yield;                // Target yield per second  [wad]
    }

    VatAbstract immutable public vat;
    DaiJoinAbstract immutable public daiJoin;
    DaiAbstract immutable public dai;
    FlashAbstract immutable public flash;
    address immutable public vow;

    mapping (bytes32 => Ilk) public ilks; // Registered maturing gems

    // --- Init ---
    constructor(address daiJoin_, address vow_, address flash_) public {
        wards[msg.sender] = 1;
        emit Rely(msg.sender);
        // AuthGemJoinAbstract gemJoin__ = gemJoin = AuthGemJoinAbstract(gemJoin_);
        DaiJoinAbstract daiJoin__ = daiJoin = DaiJoinAbstract(daiJoin_);
        VatAbstract vat__ = vat = VatAbstract(address(daiJoin__.vat()));
        DaiAbstract dai__ = dai = DaiAbstract(address(daiJoin__.dai()));
        flash = FlashAbstract(flash_);
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
    function init(bytes32 ilk, address gemJoin) external note auth {
        require(ilks[ilk].gemJoin == address(0), "DssTlm/ilk-already-init");
        ilks[ilk].gemJoin = gemJoin;

        AuthGemJoinAbstract(gemJoin).gem().approve(gemJoin, uint256(-1));
    }

    /// @dev Set up the ceiling debt or target yield for a maturing gem.
    function file(bytes32 ilk, bytes32 what, uint256 data) external note auth {
        if (what == "line") ilks[ilk].line = data;
        else if (what == "yield") ilks[ilk].yield = data; // 5% per year is 0.05 * RAY / seconds_in_a_year, or about 1585e15.
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
        ilks[ilk].art = add(ilks[ilk].art, daiAmt);
        require(mul(ilks[ilk].art, RAY) <= ilks[ilk].line, "DssTlm/ceiling-exceeded");
        
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

        // To get the gems out of the Urn we use a Dai flash loan from the dss-flash module (MIP-25)
        uint256 art = ilks[ilk].art;
        uint256 fee = flash.flashFee(address(dai), art);
        dai.approve(address(flash), add(art, fee));
        flash.flashLoan(address(this), address(dai), art, abi.encode(ilk)); // The `onFlashLoan` callback gets executed before the next line
        uint256 joy = dai.balanceOf(address(this));                         // Back from the flash loan, we could have a surplus for the vow
        daiJoin.join(address(this), joy);
        vat.move(address(this), vow, rad(joy));
    }

    /// @dev ERC3156 Flash Loan callback. Restricted to this contract, through the registered flash lender.
    /// This function pays the DssTlm debt in Vat with funds previously provided via a flash loan, then extracts the mature gems from Vat,
    /// and redeems them for Dai, which will repay the flash loan.
    function onFlashLoan(address sender, address token, uint256 amount, uint256 fee, bytes calldata data) external note {
        require(msg.sender == address(flash), "DssTlm/only-dss-flash");
        require(sender == address(this), "DssTlm/only-self");

        bytes32 ilk = abi.decode(data, (bytes32));
        AuthGemJoinAbstract gemJoin = AuthGemJoinAbstract(ilks[ilk].gemJoin);
        MaturingGemAbstract gem = gemJoin.gem();

        uint256 gemAmt = gem.balanceOf(address(gemJoin));
        uint256 art = ilks[ilk].art;
        daiJoin.join(address(this), art); // Assuming `rate` == 1.0
        vat.frob(ilk, address(this), address(this), address(this), -int256(gemAmt), -int256(art));
        gemJoin.exit(address(this), gemAmt);
        gem.redeem(address(this), address(this), gem.balanceOf(address(this))); // This should return more dai than necessary to repay the flash loan
    }
}

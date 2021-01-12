pragma solidity ^0.6.7;

import { DaiJoinAbstract } from "./dss-interfaces/dss/DaiJoinAbstract.sol";
import { DaiAbstract } from "./dss-interfaces/dss/DaiAbstract.sol";
import { VatAbstract } from "./dss-interfaces/dss/VatAbstract.sol";
import { LibNote } from "./dss/lib.sol";

interface AuthGemJoinAbstract {
    function dec() external view returns (uint256);
    function ilk() external view returns (bytes32);
    function gem() external view returns (address);
    function join(address, uint256, address) external;
    function exit(address, uint256) external;
}

interface MaturingGemAbstract {
    function approve(address spender, uint256 amount) external view returns (bool);
    function balanceOf(address usr) external view returns (uint256);
    function maturity() external view returns (uint256);
    function redeem(address from, address to, uint256 amount) external returns (uint256);
}

interface FlashAbstract {
    function flashFee(address token, uint256 amount) external view returns (uint256);
    function flashLoan(address receiver, address token, uint256 amount, bytes calldata data) external view returns (uint256);
}

// Term Lending Module
// Allows anyone to go sell a maturity gem to the TLM at a maturity-adjusted price

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
        uint256 art;                  // Current Debt              [wad]
        uint256 line;                 // Debt Ceiling              [rad]
        uint256 yield;                // Target yield, per second  [ray]
        uint256 to18ConversionFactor; // Multiplier to WAD         [uint]
    }

    VatAbstract immutable public vat;
    DaiJoinAbstract immutable public daiJoin;
    DaiAbstract immutable public dai;
    FlashAbstract immutable public flash;
    address immutable public vow;

    mapping (bytes32 => Ilk) public ilks;

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
        require(ilks[ilk].gemJoin == address(0), "DssTlm/ilk-already-init");
        ilks[ilk].gemJoin = gemJoin;
        ilks[ilk].to18ConversionFactor = 10 ** (18 - AuthGemJoinAbstract(gemJoin).dec());

        MaturingGemAbstract(AuthGemJoinAbstract(gemJoin).gem()).approve(gemJoin, uint256(-1));
    }

    function file(bytes32 ilk, bytes32 what, uint256 data) external note auth {
        if (what == "line") ilks[ilk].line = data;
        else if (what == "yield") ilks[ilk].yield = data;
        else revert("DssTlm/file-unrecognized-param");
    }

    // hope can be used to transfer control of the PSM vault to another contract
    // This can be used to upgrade the contract
    function hope(address usr) external note auth {
        vat.hope(usr);
    }
    function nope(address usr) external note auth {
        vat.nope(usr);
    }

    // --- Primary Functions ---
    function sellGem(bytes32 ilk, address usr, uint256 gemAmt) external note {
        AuthGemJoinAbstract gemJoin = AuthGemJoinAbstract(ilks[ilk].gemJoin);
        MaturingGemAbstract gem = MaturingGemAbstract(address(gemJoin.gem()));
        uint256 gemAmt18 = mul(gemAmt, ilks[ilk].to18ConversionFactor);
        uint256 time = sub(gem.maturity(), block.timestamp); // Reverts after maturity
        uint256 price = rdiv(RAY, rpow(add(RAY, ilks[ilk].yield), time, RAY));
        uint256 daiAmt = rmul(gemAmt18, price);
        ilks[ilk].art = add(ilks[ilk].art, daiAmt);
        require(mul(ilks[ilk].art, RAY) <= ilks[ilk].line, "DssTlm/ceiling-exceeded");
        
        // AuthGemJoin includes the `transferFrom` from `msg.sender` in `join`
        gemJoin.join(address(this), gemAmt, msg.sender);
        vat.frob(ilk, address(this), address(this), address(this), int256(gemAmt18), int256(daiAmt));
        daiJoin.exit(usr, daiAmt);
    }

    function redeemGem(bytes32 ilk) external note {
        AuthGemJoinAbstract gemJoin = AuthGemJoinAbstract(ilks[ilk].gemJoin);
        MaturingGemAbstract gem = MaturingGemAbstract(address(gemJoin.gem()));
        require(block.timestamp >= gem.maturity(), "DssTlm/not-mature");

        // To get the gems out of the Urn we use a Dai flash loan from the dss-flash module (MIP-25)
        uint256 art = ilks[ilk].art;
        uint256 fee = flash.flashFee(address(dai), art);
        dai.approve(address(flash), add(art, fee));
        flash.flashLoan(address(this), address(dai), art, abi.encode(ilk)); // The `onFlashLoan` callback gets executed before the next line
        vat.move(address(this), vow, dai.balanceOf(address(this))); // Back from the flash loan, if we have any dai left we send it to the vow
    }

    function onFlashLoan(address sender, address token, uint256 amount, uint256 fee, bytes calldata data) external note {
        require(msg.sender == address(flash), "DssTlm/only-dss-flash");
        require(sender == address(this), "DssTlm/only-self");

        bytes32 ilk = abi.decode(data, (bytes32));
        AuthGemJoinAbstract gemJoin = AuthGemJoinAbstract(ilks[ilk].gemJoin);
        MaturingGemAbstract gem = MaturingGemAbstract(address(gemJoin.gem()));

        uint256 gemAmt = gem.balanceOf(address(gemJoin));
        uint256 art = ilks[ilk].art;
        daiJoin.join(address(this), art); // Assuming `rate` == 1.0
        vat.frob(ilk, address(this), address(this), address(this), -int256(gemAmt), -int256(art));
        gemJoin.exit(address(this), gemAmt);
        gem.redeem(address(this), address(this), gem.balanceOf(address(this))); // This should return more dai than necessary to repay the flash loan
    }
}

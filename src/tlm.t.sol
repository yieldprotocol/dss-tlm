pragma solidity ^0.6.7;

import "./ds-test/test.sol";
import "./ds-value/value.sol";
import "./ds-token/token.sol";
import "./ds-math/math.sol";
import "./dss-gem-joins/join-auth.sol";
import {Vat}              from "./dss/vat.sol";
import {Spotter}          from "./dss/spot.sol";
import {Vow}              from "./dss/vow.sol";
import {GemJoin, DaiJoin} from "./dss/join.sol";
import {Dai}              from "./dss/dai.sol";

import "./str-utils.sol";
import "./tlm.sol";

interface Hevm {
    function warp(uint256) external;
    function store(address,bytes32,bytes32) external;
}

/// @dev FYDai are redeemable for Dai at a 1:1 ratio after maturity.
contract TestFYDai is DSMath, DSToken {
    Dai public dai;
    uint256 public maturity;

    mapping(address => mapping(address => bool)) public delegated;

    constructor(address dai_, uint256 maturity_, bytes32 symbol_, uint256 decimals_) public DSToken(symbol_) {
        dai = Dai(dai_);
        maturity = maturity_;
        decimals = decimals_;
    }

    modifier onlyHolderOrDelegate(address holder, string memory errorMessage) {
        require(
            msg.sender == holder || delegated[holder][msg.sender],
            errorMessage
        );
        _;
    }

    function addDelegate(address delegate) public {
        delegated[msg.sender][delegate] = true;
    }

    function redeem(address src, address dst, uint256 wad) public
        onlyHolderOrDelegate(src, "FYDai: Only Holder Or Delegate")
        returns (uint256)
    {
        require(balanceOf[src] >= wad, "ds-token-insufficient-balance");
        balanceOf[src] = sub(balanceOf[src], wad);
        totalSupply = sub(totalSupply, wad);
        emit Burn(src, wad);

        dai.transfer(dst, wad);
        return wad;
    }
}


/// @dev Mock Vat
contract TestVat is Vat {
    function mint(address usr, uint256 rad) public {
        dai[usr] += rad;
    }
}

/// @dev Mock Vow
contract TestVow is Vow {
    constructor(address vat, address flapper, address flopper)
        public Vow(vat, flapper, flopper) {}
    // Total surplus
    function Joy() public view returns (uint256) {
        return vat.dai(address(this));
    }
}

/* contract User {

    Dai public dai;
    AuthGemJoin public gemJoin;
    DssTlm public tlm;

    constructor(Dai dai_, AuthGemJoin gemJoin_, DssTlm tlm_) public {
        dai = dai_;
        gemJoin = gemJoin_;
        tlm = tlm_;
    }

    function sellGem(bytes32 ilkA, uint256 wad) public {
        DSToken(address(gemJoin.gem())).approve(address(gemJoin));
        tlm.sellGem(ilkA, address(this), wad);
    }
} */

/// @dev DssTlm tests
contract DssTlmTest is DSTest {
    using StringUtils for uint256;
    using StringUtils for bytes32;

    Hevm hevm;

    address me;

    TestVat vat;
    Spotter spot;
    TestVow vow;
    DSValue pip;
    TestFYDai fyDai;
    DaiJoin daiJoin;
    Dai dai;

    AuthGemJoin gemJoinA;
    DssTlm tlm;

    // CHEAT_CODE = 0x7109709ECfa91a80626fF3989D68f67F5b1DD12D
    bytes20 constant CHEAT_CODE =
        bytes20(uint160(uint256(keccak256('hevm cheat code'))));

    bytes32 constant ilkA = "fyDai";

    uint256 constant NOW = 1609459199;
    uint256 constant MATURITY = 1640995199;

    uint256 constant WAD = 10 ** 18;
    uint256 constant RAY = 10 ** 27;
    uint256 constant RAD = 10 ** 45;

    /// @dev Convert a wad to ray
    function ray(uint256 wad) internal pure returns (uint256) {
        return wad * 10 ** 9;
    }

    /// @dev Convert a wad to rad
    function rad(uint256 wad) internal pure returns (uint256) {
        return wad * 10 ** 27;
    }

    /// @dev Set up the testing environment
    function setUp() public {
        me = address(this);
        hevm = Hevm(address(CHEAT_CODE));
        hevm.warp(NOW);

        // Deploy DSS
        vat = new TestVat();
        vow = new TestVow(address(vat), address(0), address(0));
        spot = new Spotter(address(vat));
        pip = new DSValue();
        dai = new Dai(0);
        daiJoin = new DaiJoin(address(vat), address(dai));

        // Deploy DssTlm
        fyDai = new TestFYDai(address(dai), MATURITY, ilkA, 18);
        gemJoinA = new AuthGemJoin(address(vat), ilkA, address(fyDai));
        tlm = new DssTlm(address(daiJoin), address(vow));

        // Init DSS
        vat.rely(address(spot));
        vat.rely(address(daiJoin));
        dai.rely(address(daiJoin));
        vat.rely(address(gemJoinA));

        pip.poke(bytes32(uint256(1 ether))); // Spot = $1
        vat.init(ilkA);
        spot.file(ilkA, bytes32("pip"), address(pip));
        spot.file(ilkA, bytes32("mat"), ray(1 ether));
        spot.poke(ilkA);
        vat.file(ilkA, "line", rad(1000 ether));
        vat.file("Line",      rad(1000 ether));

        vat.rely(address(tlm));

        // Fund fyDai and flash
        vat.hope(address(daiJoin));
        vat.mint(me, rad(1000 ether));
        daiJoin.exit(me, 1000 ether);
        dai.transfer(address(fyDai), 1000 ether); // Funds for redeeming
    }

    /// @dev Test we can add new fyDai series
    function test_init_ilk() public {
        // 5% per year is (1.05)^(1/seconds_in_a_year) * RAY
        // which is about 1000000001547125985827094528
        uint256 target = 1000000001547125985827094528;
        tlm.init(ilkA, address(gemJoinA), target);
        (address gemJoinAAddress,) = tlm.ilks(ilkA);
        assertEq(gemJoinAAddress, address(gemJoinA));
    }

    /// @dev Test we can set the debt ceiling and target yield for registered fyDai series
    function test_file_ilk() public {
        // 5% per year is (1.05)^(1/seconds_in_a_year) * RAY
        // which is about 1000000001547125985827094528
        uint256 target = 1000000001547125985827094528;

        tlm.init(ilkA, address(gemJoinA), target);
        (, uint256 yield) = tlm.ilks(ilkA);
        assertEq(yield, target);
    }

    /// @dev Helper function to add an fyDai series to DssTlm
    function setup_gemJoinA() internal {
        // 5% per year is (1.05)^(1/seconds_in_a_year) * RAY
        // which is about 1000000001547125985827094528
        uint256 target = 1000000001547125985827094528;

        tlm.init(ilkA, address(gemJoinA), target);
        fyDai.approve(address(tlm));
        gemJoinA.rely(address(tlm));
        fyDai.mint(1000 ether); // Give some fyDai to this contract
    }

    /// @dev Test users can sell fyDai to DssTlm, with a target yield of 0%
    function test_sellGem_no_yield() public {
        setup_gemJoinA();
        tlm.file(ilkA, "yield", RAY);

        assertEq(fyDai.balanceOf(me), 1000 ether);
        assertEq(vat.gem(ilkA, me), 0);
        assertEq(vat.dai(me), 0);
        assertEq(dai.balanceOf(me), 0);
        assertEq(vow.Joy(), 0);

        tlm.sellGem(ilkA, me, 100 ether);

        assertEq(fyDai.balanceOf(me), 900 ether);
        assertEq(vat.gem(ilkA, me), 0);
        assertEq(vat.dai(me), 0);
        assertEq(dai.balanceOf(me), 100 ether);
        assertEq(vow.Joy(), 0);
        (uint256 inkme, uint256 artme) = vat.urns(ilkA, me);
        assertEq(inkme, 0);
        assertEq(artme, 0);
        (uint256 inktlm, uint256 arttlm) = vat.urns(ilkA, address(tlm));
        assertEq(inktlm, 100 ether);
        assertEq(arttlm, 100 ether);
    }

    /// @dev Test users can sell fyDai to DssTlm, with a target yield above 0%
    function test_sellGem_yield() public {
        setup_gemJoinA();

        assertEq(fyDai.balanceOf(me), 1000 ether);
        assertEq(vat.gem(ilkA, me), 0);
        assertEq(vat.dai(me), 0);
        assertEq(dai.balanceOf(me), 0);
        assertEq(vow.Joy(), 0);

        tlm.sellGem(ilkA, me, 100 ether);

        assertEq(fyDai.balanceOf(me), 900 ether);
        assertEq(vat.gem(ilkA, me), 0);
        assertEq(vat.dai(me), 0);
        assertGe(dai.balanceOf(me), 95 ether); // Should this be very close to 95?
        assertLe(dai.balanceOf(me), 96 ether);
        assertEq(vow.Joy(), 0);
        (uint256 inkme, uint256 artme) = vat.urns(ilkA, me);
        assertEq(inkme, 0);
        assertEq(artme, 0);
        (uint256 inktlm, uint256 arttlm) = vat.urns(ilkA, address(tlm));
        assertEq(inktlm, 100 ether);
        assertGe(arttlm, 95 ether);
        assertLe(arttlm, 96 ether);
    }

    /// @dev Test users can buy fyDai at a price of 1 Dai
    function test_buyGem() public {
        setup_gemJoinA();
        tlm.sellGem(ilkA, me, 100 ether);

        (uint256 ink, uint256 art) = vat.urns(ilkA, address(tlm));
        assertEq(ink, 100 ether);
        assertGe(art, 95 ether);
        assertLe(art, 96 ether);
        assertEq(vow.Joy(), 0);

        vat.mint(me, rad(100 ether));
        daiJoin.exit(me, 100 ether);
        
        dai.approve(address(tlm), 100 ether);
        tlm.buyGem(ilkA, me, 100 ether);

        (ink, art) = vat.urns(ilkA, address(tlm));
        assertEq(ink, 0 ether);
        assertEq(art, 0 ether);
        assertGe(vow.Joy(), rad(4 ether));
        assertLe(vow.Joy(), rad(5 ether));
    }
}

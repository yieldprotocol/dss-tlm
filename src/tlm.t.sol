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

import "./tlm.sol";

interface Hevm {
    function warp(uint256) external;
    function store(address,bytes32,bytes32) external;
}

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

        dai.mint(dst, wad);
        return wad;
    }
}

contract TestVat is Vat {
    function mint(address usr, uint256 rad) public {
        dai[usr] += rad;
    }
}

contract TestVow is Vow {
    constructor(address vat, address flapper, address flopper)
        public Vow(vat, flapper, flopper) {}
    // Total deficit
    function Awe() public view returns (uint256) {
        return vat.sin(address(this));
    }
    // Total surplus
    function Joy() public view returns (uint256) {
        return vat.dai(address(this));
    }
    // Unqueued, pre-auction debt
    function Woe() public view returns (uint256) {
        return sub(sub(Awe(), Sin), Ash);
    }
}

contract TestFlash { }

contract User {

    Dai public dai;
    AuthGemJoin public gemJoin;
    DssTlm public tlm;

    constructor(Dai dai_, AuthGemJoin gemJoin_, DssTlm tlm_) public {
        dai = dai_;
        gemJoin = gemJoin_;
        tlm = tlm_;
    }

    function sellGem(bytes32 ilk, uint256 wad) public {
        DSToken(address(gemJoin.gem())).approve(address(gemJoin));
        tlm.sellGem(ilk, address(this), wad);
    }

    /*
    function buyGem(uint256 wad) public {
        dai.approve(address(tlm), uint256(-1));
        tlm.buyGem(address(this), wad);
    }
    */
}

contract DssTlmTest is DSTest {
    
    Hevm hevm;

    address me;

    TestVat vat;
    Spotter spot;
    TestVow vow;
    DSValue pip;
    TestFYDai fyDai;
    DaiJoin daiJoin;
    Dai dai;
    TestFlash flash;

    AuthGemJoin gemA;
    DssTlm tlmA;

    // CHEAT_CODE = 0x7109709ECfa91a80626fF3989D68f67F5b1DD12D
    bytes20 constant CHEAT_CODE =
        bytes20(uint160(uint256(keccak256('hevm cheat code'))));

    bytes32 constant ilk = "fyDai";

    uint256 constant TOLL_ONE_PCT = 10 ** 16;
    uint256 constant FYDAI_WAD = 10 ** 18;
    uint256 constant MATURITY = 1640995199;

    function ray(uint256 wad) internal pure returns (uint256) {
        return wad * 10 ** 9;
    }

    function rad(uint256 wad) internal pure returns (uint256) {
        return wad * 10 ** 27;
    }

    function setUp() public {
        hevm = Hevm(address(CHEAT_CODE));

        me = address(this);

        vat = new TestVat();
        vat = vat;

        spot = new Spotter(address(vat));
        vat.rely(address(spot));

        flash = new TestFlash();

        vow = new TestVow(address(vat), address(0), address(0));

        dai = new Dai(0);

        fyDai = new TestFYDai(address(dai), MATURITY, "FYDAI", 18);
        fyDai.mint(1000 * FYDAI_WAD);

        vat.init(ilk);

        gemA = new AuthGemJoin(address(vat), ilk, address(fyDai));
        vat.rely(address(gemA));

        daiJoin = new DaiJoin(address(vat), address(dai));
        vat.rely(address(daiJoin));
        dai.rely(address(daiJoin));

        tlmA = new DssTlm(address(daiJoin), address(vow), address(flash));
        // gemA.rely(address(tlmA)); Does this need to go into tlm.init()?
        // gemA.deny(me);

        pip = new DSValue();
        pip.poke(bytes32(uint256(1 ether))); // Spot = $1

        spot.file(ilk, bytes32("pip"), address(pip));
        spot.file(ilk, bytes32("mat"), ray(1 ether));
        spot.poke(ilk);

        vat.file(ilk, "line", rad(1000 ether));
        vat.file("Line",      rad(1000 ether));
    }

    function test_init_ilk() public {
        tlmA.init(ilk, address(gemA));
        // How do I retrieve a struct?
    }


    /*
    function test_sellGem_no_fee() public {
        assertEq(fyDai.balanceOf(me), 1000 * FYDAI_WAD);
        assertEq(vat.gem(ilk, me), 0);
        assertEq(vat.dai(me), 0);
        assertEq(dai.balanceOf(me), 0);
        assertEq(vow.Joy(), 0);

        fyDai.approve(address(gemA));
        tlmA.sellGem(me, 100 * FYDAI_WAD);

        assertEq(fyDai.balanceOf(me), 900 * FYDAI_WAD);
        assertEq(vat.gem(ilk, me), 0);
        assertEq(vat.dai(me), 0);
        assertEq(dai.balanceOf(me), 100 ether);
        assertEq(vow.Joy(), 0);
        (uint256 inkme, uint256 artme) = vat.urns(ilk, me);
        assertEq(inkme, 0);
        assertEq(artme, 0);
        (uint256 inktlm, uint256 arttlm) = vat.urns(ilk, address(tlmA));
        assertEq(inktlm, 100 ether);
        assertEq(arttlm, 100 ether);
    }

    function test_sellGem_fee() public {
        tlmA.file("tin", TOLL_ONE_PCT);

        assertEq(fyDai.balanceOf(me), 1000 * FYDAI_WAD);
        assertEq(vat.gem(ilk, me), 0);
        assertEq(vat.dai(me), 0);
        assertEq(dai.balanceOf(me), 0);
        assertEq(vow.Joy(), 0);

        fyDai.approve(address(gemA));
        tlmA.sellGem(me, 100 * FYDAI_WAD);

        assertEq(fyDai.balanceOf(me), 900 * FYDAI_WAD);
        assertEq(vat.gem(ilk, me), 0);
        assertEq(vat.dai(me), 0);
        assertEq(dai.balanceOf(me), 99 ether);
        assertEq(vow.Joy(), rad(1 ether));
    }

    function test_swap_both_no_fee() public {
        fyDai.approve(address(gemA));
        tlmA.sellGem(me, 100 * FYDAI_WAD);
        dai.approve(address(tlmA), 40 ether);
        tlmA.buyGem(me, 40 * FYDAI_WAD);

        assertEq(fyDai.balanceOf(me), 940 * FYDAI_WAD);
        assertEq(vat.gem(ilk, me), 0);
        assertEq(vat.dai(me), 0);
        assertEq(dai.balanceOf(me), 60 ether);
        assertEq(vow.Joy(), 0);
        (uint256 ink, uint256 art) = vat.urns(ilk, address(tlmA));
        assertEq(ink, 60 ether);
        assertEq(art, 60 ether);
    }

    function test_swap_both_fees() public {
        tlmA.file("tin", 5 * TOLL_ONE_PCT);
        tlmA.file("tout", 10 * TOLL_ONE_PCT);

        fyDai.approve(address(gemA));
        tlmA.sellGem(me, 100 * FYDAI_WAD);

        assertEq(fyDai.balanceOf(me), 900 * FYDAI_WAD);
        assertEq(dai.balanceOf(me), 95 ether);
        assertEq(vow.Joy(), rad(5 ether));
        (uint256 ink1, uint256 art1) = vat.urns(ilk, address(tlmA));
        assertEq(ink1, 100 ether);
        assertEq(art1, 100 ether);

        dai.approve(address(tlmA), 44 ether);
        tlmA.buyGem(me, 40 * FYDAI_WAD);

        assertEq(fyDai.balanceOf(me), 940 * FYDAI_WAD);
        assertEq(dai.balanceOf(me), 51 ether);
        assertEq(vow.Joy(), rad(9 ether));
        (uint256 ink2, uint256 art2) = vat.urns(ilk, address(tlmA));
        assertEq(ink2, 60 ether);
        assertEq(art2, 60 ether);
    }

    function test_swap_both_other() public {
        fyDai.approve(address(gemA));
        tlmA.sellGem(me, 100 * FYDAI_WAD);

        assertEq(fyDai.balanceOf(me), 900 * FYDAI_WAD);
        assertEq(dai.balanceOf(me), 100 ether);
        assertEq(vow.Joy(), rad(0 ether));

        User someUser = new User(dai, gemA, tlmA);
        dai.mint(address(someUser), 45 ether);
        someUser.buyGem(40 * FYDAI_WAD);

        assertEq(fyDai.balanceOf(me), 900 * FYDAI_WAD);
        assertEq(fyDai.balanceOf(address(someUser)), 40 * FYDAI_WAD);
        assertEq(vat.gem(ilk, me), 0 ether);
        assertEq(vat.gem(ilk, address(someUser)), 0 ether);
        assertEq(vat.dai(me), 0);
        assertEq(vat.dai(address(someUser)), 0);
        assertEq(dai.balanceOf(me), 100 ether);
        assertEq(dai.balanceOf(address(someUser)), 5 ether);
        assertEq(vow.Joy(), rad(0 ether));
        (uint256 ink, uint256 art) = vat.urns(ilk, address(tlmA));
        assertEq(ink, 60 ether);
        assertEq(art, 60 ether);
    }

    function test_swap_both_other_small_fee() public {
        tlmA.file("tin", 1);

        User user1 = new User(dai, gemA, tlmA);
        fyDai.transfer(address(user1), 40 * FYDAI_WAD);
        user1.sellGem(40 * FYDAI_WAD);

        assertEq(fyDai.balanceOf(address(user1)), 0 * FYDAI_WAD);
        assertEq(dai.balanceOf(address(user1)), 40 ether - 40);
        assertEq(vow.Joy(), rad(40));
        (uint256 ink1, uint256 art1) = vat.urns(ilk, address(tlmA));
        assertEq(ink1, 40 ether);
        assertEq(art1, 40 ether);

        user1.buyGem(40 * FYDAI_WAD - 1);

        assertEq(fyDai.balanceOf(address(user1)), 40 * FYDAI_WAD - 1);
        assertEq(dai.balanceOf(address(user1)), 999999999960);
        assertEq(vow.Joy(), rad(40));
        (uint256 ink2, uint256 art2) = vat.urns(ilk, address(tlmA));
        assertEq(ink2, 1 * 10 ** 12);
        assertEq(art2, 1 * 10 ** 12);
    }

    function testFail_sellGem_insufficient_gem() public {
        User user1 = new User(dai, gemA, tlmA);
        user1.sellGem(40 * FYDAI_WAD);
    }

    function testFail_swap_both_small_fee_insufficient_dai() public {
        tlmA.file("tin", 1);        // Very small fee pushes you over the edge

        User user1 = new User(dai, gemA, tlmA);
        fyDai.transfer(address(user1), 40 * FYDAI_WAD);
        user1.sellGem(40 * FYDAI_WAD);
        user1.buyGem(40 * FYDAI_WAD);
    }

    function testFail_sellGem_over_line() public {
        fyDai.mint(1000 * FYDAI_WAD);
        fyDai.approve(address(gemA));
        tlmA.buyGem(me, 2000 * FYDAI_WAD);
    }

    function testFail_two_users_insufficient_dai() public {
        User user1 = new User(dai, gemA, tlmA);
        fyDai.transfer(address(user1), 40 * FYDAI_WAD);
        user1.sellGem(40 * FYDAI_WAD);

        User user2 = new User(dai, gemA, tlmA);
        dai.mint(address(user2), 39 ether);
        user2.buyGem(40 * FYDAI_WAD);
    }

    function test_swap_both_zero() public {
        fyDai.approve(address(gemA), uint(-1));
        tlmA.sellGem(me, 0);
        dai.approve(address(tlmA), uint(-1));
        tlmA.buyGem(me, 0);
    }

    function testFail_direct_deposit() public {
        fyDai.approve(address(gemA), uint(-1));
        gemA.join(me, 10 * FYDAI_WAD, me);
    }

    function test_lerp_tin() public {
        Lerp lerp = new Lerp(address(tlmA), "tin", 1 * TOLL_ONE_PCT, 1 * TOLL_ONE_PCT / 10, 9 days);
        assertEq(lerp.what(), "tin");
        assertEq(lerp.start(), 1 * TOLL_ONE_PCT);
        assertEq(lerp.end(), 1 * TOLL_ONE_PCT / 10);
        assertEq(lerp.duration(), 9 days);
        assertTrue(!lerp.started());
        assertTrue(!lerp.done());
        assertEq(lerp.startTime(), 0);
        assertEq(tlmA.tin(), 0);
        tlmA.rely(address(lerp));
        lerp.init();
        assertTrue(lerp.started());
        assertTrue(!lerp.done());
        assertEq(lerp.startTime(), block.timestamp);
        assertEq(tlmA.tin(), 1 * TOLL_ONE_PCT);
        hevm.warp(1 days);
        assertEq(tlmA.tin(), 1 * TOLL_ONE_PCT);
        lerp.tick();
        assertEq(tlmA.tin(), 9 * TOLL_ONE_PCT / 10);    // 0.9%
        hevm.warp(2 days);
        lerp.tick();
        assertEq(tlmA.tin(), 8 * TOLL_ONE_PCT / 10);    // 0.8%
        hevm.warp(2 days + 12 hours);
        lerp.tick();
        assertEq(tlmA.tin(), 75 * TOLL_ONE_PCT / 100);    // 0.75%
        hevm.warp(12 days);
        assertEq(tlmA.wards(address(lerp)), 1);
        lerp.tick();
        assertEq(tlmA.tin(), 1 * TOLL_ONE_PCT / 10);    // 0.1%
        assertTrue(lerp.done());
        assertEq(tlmA.wards(address(lerp)), 0);
    }
    */
}
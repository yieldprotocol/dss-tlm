# TrmPsm

The official implementation of the Term Rates Module, largely derived from the [PSM](https://forum.makerdao.com/t/mip29-peg-stability-module/5071). There are two main components to the TRM:

### AuthGemJoinX

This is an exact duplicate of the `GemJoinX` adapter for the given collateral type with two modifications.

First the method signature of `join()` is changed to include the original message sender at the end as well as adding the `auth` modifier. This should look like:

`function join(address urn, uint256 wad) external note` -> `function join(address urn, uint256 wad, address _msgSender) external note auth`

Second, all instances of `msg.sender` are replaced with `_msgSender` in the `join()` function.

In this repository I have added [join-5-auth.sol](https://github.com/BellwoodStudios/dss-psm/blob/master/src/join-5-auth.sol) for the TRM-friendly version of [join-5.sol](https://github.com/makerdao/dss-gem-joins/blob/master/src/join-5.sol) which is used for USDC. This can be applied to any other gem join adapter.

### DssTrm

This is the actual TRM module which acts as a authed special vault sitting behind the `AuthGemJoinX` contract. `DssTrm` allows you to call `sellGem()` to trade ERC20 DAI for FYDAI. Upon calling one this function the TRM vault will lock FYDAI in the join adapter, take out a dai loan at a maturity-adjusted price and issue ERC20 DAI to the specified user.

#### Administration

The `init` function is used to introduce new fyDai series (`ilk`) to the TRM. A `bytes32` identifier and a `AuthGemJoin` address must be provided.

The `file` function is used to modify the `line` (debt ceiling) and `yield` (target per-second interest rate) parameters for each `ilk`.

#### Approvals

The TRM requires ERC20 approvals to pull in the tokens.

To use `sellGem(ilk, usr, amt)` you must first call `gem.approve(<gemJoinAddress>, amt)`. Example:

    // Trade 100 fyDaiSep21 for DAI
    fyDaiSep21.approve(0x0A59649758aa4d66E25f08Dd01271e891fe52199, 100 * (10 ** 18));
    trm.sellGem(address(this), 100 * (10 ** 18));

#### Notes on Price

When calling `sellGem()`, DAI is minted at a price determined by a target yield and the time to maturity: `price = 1/(1 + yield)^timeToMaturity` and `daiAmt = price * fyDaiAmt`

## Contracts

### Mainnet

### Kovan

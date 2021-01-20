# DssTlm

The official implementation of the Term Lending Module, largely derived from the [PSM](https://forum.makerdao.com/t/mip29-peg-stability-module/5071). There are two main components to the TLM:

The TLM module acts as a authed special vault sitting behind the `AuthGemJoin` contract. `DssTlm` allows you to call `sellGem()` to trade ERC20 DAI for FYDAI. Upon calling one this function the TLM vault will lock FYDAI in the join adapter, take out a dai loan at a maturity-adjusted price and issue ERC20 DAI to the specified user.

#### Administration

The `init` function is used to introduce new fyDai series (`ilk`) to the TLM. A `bytes32` identifier and a `AuthGemJoin` address must be provided.

The `file` function is used to modify the `line` (debt ceiling) and `yield` (target per-second interest rate) parameters for each `ilk`.

#### Approvals

The TLM requires ERC20 approvals to pull in the tokens.

To use `sellGem(ilk, usr, amt)` you must first call `gem.approve(<gemJoinAddress>, amt)`. Example:

    // Trade 100 fyDaiSep21 for DAI
    fyDaiSep21.approve(0x0A59649758aa4d66E25f08Dd01271e891fe52199, 100 * (10 ** 18));
    tlm.sellGem(address(this), 100 * (10 ** 18));

#### Notes on Price

When calling `sellGem()`, DAI is minted at a price determined by a target yield and the time to maturity: `price = 1/(1 + yield)^timeToMaturity` and `daiAmt = price * fyDaiAmt`

## Contracts

### Mainnet

### Kovan

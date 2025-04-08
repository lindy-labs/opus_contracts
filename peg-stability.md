# Peg Stability

Opus employs various mechanisms to incentivize user behaviour towards ensuring the price stability of CASH.

1. A global multiplier value applied to interest rates for all troves
2. Forge fees
3. Incentivized LP staking

## How does the multiplier work?

The global multiplier value is applied to interest rates to steer user behaviour towards restoring CASH to its peg price.&#x20;

* When the spot price of CASH drops below its peg, the global multiplier value increases, thereby increasing interest rates across all Troves. This increases the cost of borrowing, and incentivizes Trove owners to repay their debt to avoid incurring the higher cost of borrowing. Trove owners would then buy CASH from the market, applying upward price pressure on CASH.
* When the spot price of CASH rises above its peg, the global multiplier value decreases, thereby decreasing interest rates across all Troves. This decreases the cost of borrowing, and incentivizes users to borrow CASH to sell on the market and profit from the arbitrage, applying downward price pressure on CASH.

## How do forge fees work?

When the spot price of CASH drops below its peg, it may take a while for the effect of the multiplier on the spot price of CASH to be felt. By imposing a fee on further borrowing of CASH, it increases the cost of borrowing for users, thereby disincentivizing them to do so, and dampens further downward price pressure on CASH.

The forge fee increases exponentially the greater the spot price of CASH is below its peg, up to a maximum of 400% of the amount sought to be borrowed.

See [#forge-fee](technical-documentation/smart-contracts/shrine-module.md#forge-fee "mention") for more details on how the forge fee is calculated.

## What is incentivized LP staking?

Users can provide liquidity to the CASH-USDC pool on Ekubo, and stake the resulting NFT. In addition to the swap fees from the underlying LP, users will also receive a portion of protocol income that is streamed over time. See [stabilizer-module.md](technical-documentation/smart-contracts/stabilizer-module.md "mention") for more details.

Incentivized LP staking deepens the liquidity depth for CASH against other stables on secondary markets, helping to stabilize the price of CASH around its peg.




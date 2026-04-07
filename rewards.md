---
description: Incentives for borrowers.
---

# Rewards

## BTCFi

### Introduction

Users will receive STRK rewards as part of the [Starknet BTCFi ](https://btcfiseason.starknet.org/)initiative if they

1. deposit the following BTC collateral; or
   1. WBTC
   2. LBTC
   3. SolvBTC
   4. tBTC
2. borrow CASH with the following BTC collateral
   1. WBTC
   2. LBTC
   3. SolvBTC
   4. tBTC
   5. xLBTC
   6. xsBTC
   7. xtBTC
   8. xWBTC

Each action will have its own allocation of rewards, and users will share proportionally in it based on the methodology described below.

### Methodology

The Starknet Foundation determines the amount of incentives on a daily basis.&#x20;

* Users who deposit BTC collateral will receive a proportional share of the incentives allocated for that  BTC collateral.
* Users who borrow CASH with BTC collateral deposited will receive incentives based on the interest generated on the amount of CASH borrowed, capped at the maximum borrowing capacity of deposited BTC collateral based on each BTC collateral's liquidation threshold.

{% hint style="info" %}
Example: on a given day, User A deposits ETH (500 USD), WBTC (300 USD) and tBTC (200 USD), and borrows 500 CASH. There is a total of 1000 USD of WBTC and 1000 USD of tBTC eligible for incentives. Assume WBTC has a liquidation threshold of 90%, and tBTC has a liquidation threshold of 80%. This translates to a maximum borrowing capacity of 90% x 300 USD = 270 USD for WBTC, and 80% x 200 USD = 160 USD for tBTC. Since the amount borrowed of 500 CASH exceeds the maximum borrowing capacity of BTC collateral at 430 CASH, user A will earn rewards on the interest generated on 430 CASH. Assume that user A generates 1 USD of interest on this 430 CASH on this given day, and the total interest generated on CASH backed by BTC collateral is 10 CASH.

Assume for a given day that there is a total of 10 STRK for WBTC supply incentives, 10 STRK for tBTC supply incentives, and 100 STRK for interest generated on borrowing CASH backed by BTC collateral, then user A will receive:

1. 300 / 1000 \* 10 = 3 STRK for depositing WBTC
2. 200 / 1000 \* 10 = 2 STRK for depositing tBTC
3. 1 / 10 \* 100 = 10 STRK for the interest generated on borrowing CASH backed by BTC collateral
{% endhint %}

### Participation

Users are automatically part of this initiative if they deposit BTC collateral or borrow CASH with deposited BTC collateral. No further actions required.

### Claiming

Visit the [rewards page here.](https://app.opus.money/rewards)

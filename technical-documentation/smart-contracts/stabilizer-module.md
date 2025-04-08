---
description: Enshrining incentivized liquidity
---

# Stabilizer Module

The Stabilizer module aims to natively incentivize liquidity depth for `yin`around its peg price so as to stabilize its spot price in the market. \
\
Users can stake their CASH/USDC liquidity positions on Ekubo and receive a portion of protocol income (distributed by the Equalizer) as additional yield. Only CASH/USDC liquidity positions that correspond exactly to these parameters can be staked. Alternatively, users can create their positions directly at this Ekubo [page](https://app.ekubo.org/positions/new?quoteCurrency=USDC\&baseCurrency=CASH\&tickSpacing=20\&fee=6805647338418769825990228293189632\&tickLower=-27641000\&tickUpper=-27626000).

| Parameter    | Value    |
| ------------ | -------- |
| Pool fee     | 0.002%   |
| Tick spacing | 0.002%   |
| Min price    | 0.990084 |
| Max price    | 1.00505  |

## Description of key functions

1. `stake`: Transfers an Ekubo liquidity position NFT with the accepted parameters from the caller to the Stabilizer.
2. `unstake`: Transfers an Ekubo liquidity position NFT that was `stake` d by the caller previously from the Stabilizer to the caller, and withdraws all accrued yield.
3. `harvest`: Withdraw accrued yield for a staked Ekubo liquidity position NFT.

## Calculation of accrued yield

The Stabilizer module checks its `yin`balance against a snapshot of the last known balance to determine if there is any yield to be distributed. Yield is in turn distributed by incrementing an accumulator value based on per unit of liquidity monotonically over time. Liquidity is tracked as a `u128`value in [Ekubo](https://docs.ekubo.org/integration-guides/reference/math-1-pager). Therefore, a user's accrued yield can be determined by multiplying its staked Ekubo position NFT's liquidity with the difference in the current accumulator value and a snapshot of the user's last known accumulator value.

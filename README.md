# Introduction

Opus is a cross margin autonomous credit protocol that lets you borrow against a portfolio of carefully curated collateral including yield-bearing assets. With minimal human intervention, the interest rates, maximum loan-to-value ratios and liquidation thresholds are dynamically determined by each user's collateral profile.

The first synthetic product of Opus is CASH, an overcollateralized USD-pegged stablecoin that you can borrow against a basket of collateral at an interest rate based on your collateral profile.

## How is CASH different from other stablecoins?

Opus introduces novel mechanisms that provide stronger guarantees in ensuring that CASH is pegged to the value of USD.

1. A global [multiplier](price-stability.md#how-does-the-multiplier-work) is applied to increase or decrease interest rates across the board, depending on whether the spot market price of CASH is below or above peg.
2. A [forge fee](price-stability.md#how-do-forge-fees-work) is charged on minting of new debt when the spot market price of CASH is below peg.

## What can I do with Opus?

1. [Borrow](borrowing.md) CASH against a set of whitelisted collateral by opening a Trove
2. [Provide](liquidations-and-the-absorber.md#why-should-i-deposit-cash-to-the-absorber) CASH to the Absorber to participate in liquidations and receive liquidated assets and a share of the protocol's income from accrued interest and fees
3. Secure Opus by [liquidating](liquidations-and-the-absorber.md#what-are-the-incentives-to-perform-a-searcher-liquidation) unhealthy Troves yourself or by using the Absorber's liquidity and be compensated

## What do I need in order to use Opus?

To borrow CASH, you need a Starknet-compatible wallet (e.g. ArgentX, Braavos) and sufficient collateral to open a Trove and pay the gas fees.

To be a provider to the Absorber, you need to have CASH. You may either open a Trove and borrow CASH, or buy CASH from a decentralized exchange.

## Does Opus charge any fees?

Opus charges an [interest rate](borrowing.md#how-is-the-interest-rate-calculated) for CASH that you borrow. The interest rate is calculated based on the make up of the collateral deposited into your Trove, and varies over time depending on the prices of the collateral vis-a-vis each other.

In addition, if the market price of CASH is below peg, an initial, one-time [forge fee](price-stability.md#how-do-forge-fees-work) is charged for borrowing CASH. This forge fee is added to your Trove's debt and will accrue interest.

## Is Opus decentralized?

At launch, Opus relies on a superuser admin that is able to grant and revoke all roles. This is necessary to allow the protocol to respond in a timely manner in case of any unforeseeable events, as well as to iterate at a faster pace. A compromised or malicious admin can cause catastrophic damage across the entire protocol. Using Opus therefore requires you to trust that the admin is honest.

Eventually, this admin functionality will be handed over to governance, and the Opus protocol will also ossify as parameters either become autonomous or unadjustable.&#x20;

## What are the risks of using Opus?

1. If you borrow CASH and your Trove is liquidated, you will lose part of or all your collateral.
2. While there are various mechanisms in place to steer the market price of CASH towards its peg price, it is not guaranteed that CASH will be perfectly pegged to the USD at all times, and it is likely that the market price will deviate slightly in either direction depending on the market conditions.
3. Users who provide CASH to the Absorber may receive liquidated assets of a lower value than that they have provided in liquidity, depending on the market conditions. This is akin to taking a long position on the collateral accepted by Opus, and may be viewed as impermanent loss.
4. While Opus takes security very seriously and diligently audits its contracts, a bug or a hack may still occur that results in losses for users of Opus.


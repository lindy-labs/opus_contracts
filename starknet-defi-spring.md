---
description: Incentives for borrowers
---

# Starknet DeFi Spring

## Introduction

Starting from 17 October 2024, users who borrow CASH will receive STRK rewards as part of the [Starknet DeFi Spring](https://www.starknet.io/blog/defi-spring-2-0/) initiative by the Starknet Foundation.

## Methodology

The Starknet Foundation determines the amount of incentives on a daily basis in their discretion.

Users who borrow CASH will earn a share of each day's incentives as a proportion of the total CASH borrowed across all Troves for the day. The amount of CASH borrowed will be aggregated for each address i.e. if one address opens two Troves, the amount of CASH borrowed will be summed up for that address. These will be calculated based on a snapshot taken at the end of each day.

{% hint style="info" %}
**Example:** _on a given day,_ if User A borrows 100 CASH, there is a total debt of 1000 CASH across all troves, and the incentives are 500 STRK, then User A will be entitled to $$\frac{100}{1000} \cdot 500 = 50 \text{ STRK}$$ on that day.
{% endhint %}

The [protocol seeded TVL](technical-documentation/smart-contracts/transmuter-module.md) has been excluded from this initiative.

## Participation

Users will automatically be part of this initiative if they are actively borrowing CASH. No further actions required.

## Claiming

Visit the [rewards page here.](https://app.opus.money/rewards)

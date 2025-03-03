---
description: The arbiter of collateral prices
---

# Seer Module

The Seer module acts as a coordinator of individual oracle modules, reading the price of the underlying collateral tokens of `yang`s from the adapter modules of oracles and submitting them to the Shrine.

In order for an oracle to be onboarded to the Seer, an adapter module needs to be implemented that conforms to the `IOracle` interface. This abstracts away the individualized differences between different oracle designs and implementations, and lets the Seer obtain the prices from multiple sources.&#x20;

Therefore, the adapter module for each oracle is also responsible for the parameters that determine whether a price is valid, and whether a given price is valid.

An advantage of this modular design is the ability to build different mechanisms for price determination for each oracle based on its capabilities as well as different considerations depending on their priority in the protocol.&#x20;

* For example, the adapter for Pragma adopts a pessimistic design that takes the lower of the spot price and the 7-days TWAP price. As the primary oracle, this lets the protocol prioritize robustness against price manipulation attacks and safeguarding against volatility.

The Seer module is designed with simplicity in mind and does not perform any further manipulation of prices obtained from an oracle. If the price from an oracle is invalid, then it will look to the next fallback oracle, if any.

## Description of key functions

* &#x20;`update_prices` : fetch the earliest valid price for each of the `yang`s in Shrine from the list of oracles according to their priority, and update the price in Shrine.

## Calculation of \`yang\` price

It is important to note that the price of a `yang` may be different from the price of its underlying collateral token. As the concept of `yang` is unique to the Shrine, oracles will return the price of a `yang`'s underlying collateral token instead. The Seer is responsible for calculating the `yang` price by multiplying the underlying collateral token's price by the conversion rate of a `yang` to its underlying collateral token.

## Conditions for triggering a price update

There are two possible ways in which a price update can be triggered:

1. sufficient time has elapsed from the last attempt to update prices, whether successful or not; or
2. the caller has been granted access to call `update_prices`, bypassing the requirement in (1).

Option (2) is intended to enable price updates when redistributions occur to ensure that the post-redistribution price correctly reflects any appreciation in the conversion rate of `yang`s to their underlying collateral tokens from the rebasing of redistributed troves' `yang`s. This is important because otherwise troves that are attributed with redistributed debt would have a lower LTV.&#x20;

## Supported Oracles

Presently, the protocol relies on the following oracles in order of priority:

1. [Pragma](https://www.pragma.build/) as the primary oracle, taking the lower of the spot price and the 7-days TWAP;
2. [Ekubo](https://ekubo.org/) oracle pools as the fallback oracle if Pragma's spot price is determined to be invalid, taking the 1H TWAP.


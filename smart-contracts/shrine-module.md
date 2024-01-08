---
description: The core accounting engine
---

# Shrine Module

The Shrine module is the core accounting module for a synthetic, and performs these bookkeeping functions:

1. Recording the balance of deposited collateral (`yang`) and minted synthetic (`yin`) for each debt position (`trove`) and the protocol;
2. Calculating and charging interest for each trove;
3. Storing the prices of `yang`s&#x20;
4. Storing the multiplier value from the Controller module

In addition, the Shrine module also implements the ERC-20 standard for its synthetic.

The Shrine module is intended to be immutable and non-upgradeable. It is purposefully designed to avoid making any external call for security reasons. As the bookkeeper, the Shrine also does not come into possession of any underlying collateral tokens.

Note that the Shrine is meant to be called by other modules only, and not by an end-user directly.

## Key concepts

1. The Shrine uses discrete time for timekeeping. Each block of time is referred to as an `interval`.
   * The `interval` ID is obtained by dividing the block timestamp by `TIME_INTERVAL`, which is a constant in Shrine denoting the number of seconds in each `interval`.
2. A trove refers to a collateralized debt position of a user.
   * A trove is identified by its trove ID. However, the Shrine itself does not enforce any ordering of trove IDs. This is performed by the Abbot.
   * A trove is represented in storage by the `Trove` struct, which keeps track of:
     * `charge_from`: the start interval for the next calculation of accrued interest
     * `last_rate_era`: the rate era of the previous calculation of accrued interest
     * `debt`: the amount of debt&#x20;
   * For a trove to have any debt, it must have at least the minimum value deposited. The minimum trove value is adjustable by the protocol or governance.
3. A `yang` is the internal representation of a token that is accepted as collateral and can be deposited by users into a trove.
   * `yang` is an abstraction of the underlying collateral token, and is normalized to Wad precision of 18 decimal places. Note that the amount of underlying collateral tokens represented by per unit of `yang` is not fixed, and the amount may vary depending on intrinsic mechanisms (e.g. redistributions) and extrinsic events (e.g. donation). It follows from the above that the price of a `yang` is a multiple of the underlying collateral token's price, depending on the amount of underlying collateral tokens represented by per Wad unit of `yang`.
   * Once a collateral token is added as a `yang` to the Shrine, it cannot be removed.&#x20;
     * However, it can be suspended with the following effects:
       * No further deposits can be made. This is enforced by the Sentinel.
       * Its threshold will decrease to zero linearly over the `SUSPENSION_GRACE_PERIOD`.
     * From the time of the suspension and before the `SUSPENSION_GRACE_PERIOD` elapses, the suspension can be reversed. However, once the `SUSPENSION_GRACE_PERIOD` elapses, the `yang` will be permanently suspended i.e. delisted.
   * Each `yang` has a set of parameters attached to it:
     * base rate: the interest rate to be charged for the `yang`
     * threshold: determines the maximum percentage of the `yang`'s value that debt can be forged against
     * cap: determines the maximum amount of underlying collateral tokens that can be used as collateral in the Shrine; note that this is enforced by the Sentinel.
4. `yin` refers to the synthetic ERC-20 of the Shrine. `yin` can be minted to a trove via `Shrine.forge`, or by interacting with another module that calls `Shrine.inject`.
5. The Shrine has a budget that keeps track of whether there is a debt deficit or debt surplus.&#x20;
   * A debt surplus is created when interest is accrued. This debt surplus can be balanced by minting new `yin`.
   * A debt deficit is created when bad debt is incurred. Bad debt can only be created by modules that are authorized to call `Shrine.adjust_budget`. For troves, there will not be a situation of bad debt because redistributions act as the final layer of liquidations.
6. The Shrine has a ceiling that caps the amount of yin that may be generated. When checking if the ceiling is exceeded, any debt surpluses should be included, and any debt deficits should be excluded.
   * However, note that the debt ceiling should not block the minting of any debt surpluses as `yin`.
   * Debt deficits are excluded to prevent a situation where the total `yin` supply exceeds the debt ceiling, but including the deficit would bring the resulting amount below the debt ceiling. In this situation, we do not want to allow more yin to be generated, except for minting of debt surpluses.

## Description of key functions

* `deposit`: increase the amount of a `yang` for a trove
* `withdraw`: decrease the amount of a `yang` for a trove, subject to the trove remaining healthy
* `forge`: increase the debt for a trove and mint `yin`, subject to the trove remaining healthy
* `melt`: decrease the debt for a trove and burn `yin`
* `seize`: decrease the amount of a `yang` for a trove without requiring the trove to remain healthy. This is used in liquidations and shutdown.
* `redistribute`: redistribute the debt and `yang` for a trove. This is used in liquidations.
* `inject`: mint `yin` to the given address
* `eject`: burn `yin` from the given address

## Creation of debt and \`yin\`

There are two primary ways in which debt and `yin` can be created:

1. For troves, debt is created when a user `forge`s `yin`. The `yin` is minted to the trove owner, and the corresponding debt, including any forge fees, is added to the trove's debt. As a trove incurs interest, the interest is added to the Shrine's budget, and eventually minted as debt surpluses via the Equalizer. It is therefore expected that the total amount of `yin`  that is `forge`d and backed by all troves will slightly lag behind the total amount of debt that has been accrued by all troves. While the Shrine's `forge` function is restricted by access control, it is intended for users to be able to interact with the Shrine's `forge` function via the equivalent `forge` function in the Abbot in a permissionless manner. In the case of troves, there is an equivalent concept of debt for `yin` in the Shrine.
2. Debt can be created by the `inject` function, which is similarly restricted by access control. This is intended for use by other modules that allow users to mint debt without the need to create a trove e.g. flash mint. In this case, there is no equivalent concept of debt for `yin` in the Shrine. Other than the flash mint module where the minted `yin` does not persist beyond a flash loan transaction, modules that rely on `inject` to mint `yin` should track the corresponding debt in their implementation. This ensures that it is possible to determine how much `yin` that module is liable to backstop the value of in the event of shutdown.

## Interest rates

Interest is charged whenever an action is taken on a trove.

The interest rate for a trove is determined by multiplying:

1. the weighted average of the base rates of the `yang`s deposited in the trove; with
   * For example, assume that ETH has a base rate of 2% and BTC has a base rate of 1%. A trove has deposited 5 ETH and 0.5 BTC, amounting to 5 Wad units of ETH `yang` and 0.5 Wad unit of BTC `yang`. The average prices of ETH `yang` and BTC `yang` over the charging period are USD 1,000 and USD 10,000 respectively. This gives the trove an average value of USD 10,000 with the value of ETH and BTC in equal ratio. Accordingly, the weighted average base rate is (5,000 / 10,000) \* 2% + (5,000 / 10,000) \* 1% = 1.5%. If ETH price were higher, it would make up a larger percentage of the total collateral value, and so the weighted average base rate would be higher.
2. the average multiplier value for the elapsed time period.

Note that whenever any base rate needs to be updated, all other base rates will also need to be updated even if they are unchanged. The time period spanning the first interval of the previous base rates and the interval right before any base rates were updated is called an `era`. Therefore, each base rate change corresponds to the start of a new `era`. This allows the average base rate to be calculated over an arbitrary number of intervals with changing base rates by breaking the entire duration into discrete `era`s, each with a start interval and an end interval.

Within an era, there are also multiple variations for calculating the average price of a `yang`, depending on the available price history, which in turn determines the value of a trove and the weighted interest rate:

<figure><img src="../.gitbook/assets/Average price determination.png" alt=""><figcaption></figcaption></figure>

Within the interval, it is possible that interest rates for the current block may be charged based on a different price and/or multiplier value for different users depending on when the price oracle and/or multiplier value is updated. However, this does not affect the integrity of the Shrine’s bookkeeping for accrued interest because it is determined only at the point of charging. Once the interval has passed, the latest price and multiplier value will be taken as the canonical value for all calculations moving forward.

## Forge fee

The forge fee is a one-time fee that is charged on newly forged debt if the spot price of `yin` drops below 0.995 USD. We allow for a 0.5% deviation of market price from the target price peg.

The forge fee is calculated according to this [function](https://www.desmos.com/calculator/dtrbkbmazh).

{% embed url="https://www.desmos.com/calculator/qgzjkceuyc" %}

The forge fee is intended to protect against downward depegs by discouraging further minting of `yin` by exponentially increasing the forging cost when the spot price drops below the peg.

## Liquidations

A trove can be liquidated once its loan-to-value ratio (LTV) is above its threshold. Each trove has its unique threshold that is determined by the weighted average of the thresholds of its deposited yangs.

* For example, assume that ETH has a threshold of 80% and BTC has a threshold of 90%. A trove has deposited 5 ETH and 0.5 BTC, amounting to 5 Wad units of ETH `yang` and 0.5 Wad unit of BTC `yang`. The average prices of ETH `yang` and BTC `yang` over the charging period are USD 1,000 and USD 10,000 respectively. This gives the trove an average value of USD 10,000 with the value of ETH and BTC in equal ratio. Accordingly, the weighted average threshold is (5,000 / 10,000) \* 80% + (5,000 / 10,000) \* 90% = 85%. If ETH price were higher, it would make up a larger percentage of the total collateral value, and so the weighted average threshold would be higher.

Briefly, there are three layers of liquidations for troves:

1. Searcher liquidation
2. Absorption i.e. liquidation using `yin` from the Absorber module
3. Redistribution

where redistribution is a built-in mechanism that socializes bad debt in a trove between all of the remaining troves. For more details on searcher liquidations and absorptions, please refer to the [Purger](https://app.gitbook.com/o/G0dVpaR8CLqXhZ3TlTJx/s/BTWxg1bdHQ15qxTg6SOE/\~/changes/1/smart-contract-modules/purger-module) module.

### Redistributions

In a redistribution, the unhealthy trove's collateral and debt is distributed among troves proportionally to its collateral composition.&#x20;

* For example, assume a trove has deposited 5 ETH and 0.5 BTC, amounting to 5 Wad units of ETH `yang` and 0.5 Wad unit of BTC `yang`. The average prices of ETH `yang` and BTC `yang` over the charging period are USD 1,000 and USD 10,000 respectively. This gives the trove an average value of USD 10,000 with the value of ETH and BTC in equal ratio. Assuming the trove has USD 9,000 debt, then USD 4,500 worth of debt and all 5 Wad units of ETH `yang` amounting to USD 5,000 value will be distributed among all troves with ETH `yang` deposited, and USD 4,500 worth of debt and all 0.5 Wad units of BTC `yang` amounting to USD 5,000 value will be distributed among all troves with BTC `yang` deposited.

Redistributions are tracked sequentially using a redistribution ID, using a computation-heavy approach that takes advantage of Starknet's cheaper computation. This was chosen because it would be more gas-efficient to Liquity's storage-heavy approach, which is better-suited for a single-collateral protocol and the more computationally-expensive EVM.

* All troves will have an initial redistribution ID of 0 by default. This is not an issue because it would be updated to the latest ID upon the first deposit of any `yang`.

Note that redistributed debt do not accrue interest until they are "pulled" into a trove. When a trove receives redistributed debt, these redistributed debt will be "pulled" into the trove upon the next transaction for that trove.

On the other hand, redistributed collateral is accounted for immediately. `yang` is redistributed by rebasing the amount of underlying collateral assets corresponding to per Wad unit of `yang`. Since the amount of underlying collateral assets remains constant, by decrementing the redistributed trove's `yang` amount and the total system's `yang` amount, the amount of underlying collateral assets corresponding to per Wad unit of `yang` would increase after a redistribution. It is therefore important that a price update is triggered after a redistribution to ensure the `yang` price accurately reflects the rebasing.\
\
For all purposes other than the calculation of accrued interest, there is no practical significance in the difference in timing between when redistributed debt is attributed to a trove and when redistributed collateral is attributed to a trove, because both are taken into account when determining a trove's value and debt, and consequently its LTV and whether it can be liquidated.

There are a few pointers to take note of when it comes to redistributions.

1. If no other troves has deposited a `yang` that is to be redistributed, then the debt and value attributed to that `yang` will be redistributed among all other `yang`s in the system according to their value proportionally to the total value of all remaining `yang`s in the system.&#x20;
2. When redistributing a trove with more than one `yang`s deposited, if there is a small amount of debt remaining to be redistributed after a `yang` i.e. less than `10 ** 9` , then it is rounded up to the current `yang` , skipping the remaining `yang`(s) altogether. This deals with any loss of precision and ensures the debt is fully redistributed.

Based on the above design, no redistributed debt or `yang` should accrue to the initial `yang` amounts deposited by the protocol via `Shrine.add_yang().`

## Recovery Mode

Recovery mode is activated when the aggregate loan-to-value ratio of all troves in the Shrine is equal to or greater than 70% of the Shrine's threshold, which is in turn calculated based on the weighted average of all deposited `yang`s.

In recovery mode, the threshold for all yangs is gradually adjusted downwards depending on the the extent to which the Shrine's aggregate loan-to-value ratio is greater than the Shrine's recovery mode threshold, down to a floor of 50% of the `yang`'s original threshold. By adjusting the threshold downwards, troves are more susceptible to liquidations. The recovery mode therefore encourages users to either deposit more collateral or repay existing debt to avoid liquidation. This in turn improves the health of the protocol. Recovery mode is also intended to steer user's behaviour towards preventing it from being activated in the first place.

## Emergency mechanism

The Shrine can be killed permanently using `Shrine.kill` . After the Shrine is killed, all user-facing actions (i.e. `deposit`, `withdraw`, `forge` and `melt`) are disabled.

## Other notes

* We are aware that there is a known front-running issue with ERC-20’s `approve()` where an approved address with a pre-existing allowance can front-run a subsequent approval to essentially make two transfers of the full allowance instead of one. We intend for this issue to be handled by front-ends through the use of multicall, and therefore chose not to implement `increase_allowance` and `decrease_allowance` as per Open Zeppelin’s ERC-20. In any event, we note that the equivalent functions have now been removed from Open Zeppelin's Solidity [implementations](https://github.com/OpenZeppelin/openzeppelin-contracts/issues/4583).

## Properties

These are some properties of the Shrine module that should hold true at all times.

* The total amount of a `yang` is equal to the sum of all troves' deposits of that `yang` (this includes any exceptionally redistributed yangs and their accompanying errors) and the initial amount seeded at the time of `add_yang`.
* For a redistribution, the redistributed debt is equal to the sum of the amount of `yang` multiplied by the unit debt for that `yang` and the error for that `yang`, for all `yang`s, minus the carried over error from the previous redistribution, if any.
* A trove that is healthy cannot become unhealthy as a result of `withdraw` or `forge`.
* The accrual of interest is monotonic, meaning it only increases in value.


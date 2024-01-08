---
description: Liquidator of unhealthy troves
---

# Purger Module

The Purger module is the primary interface for the multi-layered liquidation system of Opus, allowing anyone to liquidate unhealthy troves and protect the solvency of the protocol. Users can either liquidate an unhealthy trove using their own `yin` or using the Absorber's `yin` deposited by providers.

## Description of key functions

There are two ways to liquidate an unhealthy trove:

1.  `liquidate`: the caller pays down the unhealthy trove's debt using its own `yin` and gets the corresponding collateral value plus a liquidation penalty as reward.

    <figure><img src="../.gitbook/assets/image (10).png" alt=""><figcaption></figcaption></figure>
2.  `absorb`: an absorption where some or all of the Absorber's `yin` balance is used to pay down the unhealthy trove's debt and the Absorber receives the corresponding collateral value plus a liquidation penalty, and the caller receives a compensation.&#x20;

    * If the Absorber's `yin` balance is insufficient to cover the amount to be paid down, then the remainder debt is redistributed.&#x20;
    * If the Absorber has no `yin` or if the Absorber is not operational, then the entire amount of debt to be paid down is redistributed. The caller will still receive compensation.

    <figure><img src="../.gitbook/assets/image (1).png" alt=""><figcaption></figcaption></figure>

Both functions should revert (via the call to `shrine.melt`) if the Shrine is not live.

**Priority of liquidation methods**

Once a trove becomes unhealthy i.e. its loan-to-value (LTV) ratio exceeds its threshold, then anyone can immediately `liquidate` the trove. The liquidation penalty will increase from 3% up to a maximum of 12.5%, as a function of how much higher the trove's LTV is than its threshold. The penalty is also bound by the maximum possible penalty that can be charged while ensuring the trove's debt is fully backed.&#x20;

Absorption can happen only after an unhealthy trove's LTV has exceeded the LTV at which the maximum possible penalty is reached, or if it has exceeded 90% LTV. The liquidation penalty in this case will similarly be capped to the maximum of 12.5% or the maximum possible penalty.

The maximum possible penalty at any given LTV is calculated as $$\frac{1-ltv}{ltv}$$, which ensures that the liquidation is not [toxic](https://arxiv.org/pdf/2212.07306.pdf) i.e. the trove's LTV is not worse off after the liquidation.&#x20;

## Liquidation parameters

For each liquidation, there are also a few dynamic parameters at play:

* **close amount:** the amount of an unhealthy trove's debt that can be paid down in a liquidation
* **liquidation penalty:** the percentage of the close amount that the address paying down the unhealthy trove's debt will receive in the form of the unhealthy trove's collateral so as to incentivize liquidations
* **compensation:** the value that the caller of `absorb` will receive in the form of the unhealthy trove's collateral so as to incentivize users to call `absorb`.

### Liquidation penalty

The liquidation penalty for `liquidate` is given by the below equations:

$$\textrm{MAX_PENALTY} = 0.125$$

$$\textrm{max_possible_penalty} = \min\left(\textrm{MAX_PENALTY}, \frac{1 - ltv}{ltv}\right)$$

$$\textrm{penalty_at_ltv} = \textrm{MIN_PENALTY} + \left( \frac{ltv}{threshold} \right) - 1$$

$$\textrm{penalty} = \min\left(\textrm{penalty_at_ltv}, \textrm{max_possible_penalty}\right)$$



The liquidation penalty for `absorb` is similar to `liquidate`, with the exception of the following:

$$\textrm{penalty_at_ltv} = \textrm{MIN_PENALTY} + s \left( \frac{ltv}{threshold} \right) - 1$$

where $$0.97 \le s \le 1.06$$

$$s$$ is a scalar that is introduced to control how quickly the absorption penalty reaches the maximum possible penalty for thresholds at or greater than 90%. This lets the protocol control how much to incentivize users to call `absorb` depending on how quick and/or desirable absorptions are for the protocol.

* If the penalty scalar is set to 1, then the absorption penalty is identical to the liquidation penalty.
* If the penalty scalar is set to greater than 1, then the absorption penalty will reach the maximum possible penalty sooner, which will make absorptions possible at a lower LTV.
* If the penalty scalar is set to lower than 1, then the absorption penalty will reach the maximum possible penalty later, which will make absorptions possible only at a higher LTV.
  * Note that 0.97 is a lower bound on the penalty scalar due to the minimum penalty, and the penalty would become negative beyond that point.

#### Resources

* [Graph](https://www.desmos.com/calculator/ztn1w2s1af) for liquidation penalty and close factor for `liquidate`
* [Graph](https://www.desmos.com/calculator/qoizltusle) for liquidation penalty, close factor and compensation for `absorb`

### Close amount

The close amount refers to the amount of debt that can be paid down during a liquidation. Rather than all-or-nothing liquidations, up to the minimum amount of repayment required to bring the trove's LTV back to a healthy level (also referred to as its safety margin) can be liquidated each time. The healthy level is currently defined as 90% of the trove's threshold. For example, assuming a trove with 70% threshold is unhealthy, then the close amount will be the amount of repayment needed to bring the trove's LTV back to 0.9 \* 70% = 63%.\
\
The close amount takes into account the liquidation penalty, as well as the compensation in the case of `absorb`.&#x20;

### Compensation

The compensation to incentivize users to call `absorb` is currently set at the minimum of 3% of a trove's collateral value, or 50 USD, whichever is lower.

## Other notes

* Typically, the amount of a trove's collateral that an address will receive from a liquidation will be proportional to the total amount that is repaid and including the liquidation penalty divided by the trove's value. However, in cases where the trove's loan-to-value exceeds 100%, then the amount of a trove's collateral that an address will receive from a liquidation will be proportional to the amount that is repaid divided by the trove's debt.

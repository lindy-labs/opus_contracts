# Borrowing

## How can I borrow CASH?

To borrow CASH, you need to first open a Trove and deposit collateral that is worth at least the minimum value. At launch, the minimum value will be 100 USD. The minimum trove value is set by the admin, and will eventually be handed over to governance.

You will then be able to borrow CASH and repay your loan in the future with interest.

It is important to note that your Trove can be liquidated if its loan-to-value (LTV) ratio increases above its threshold.

## What collateral is accepted?

| Asset  | Base Rate | Base LTV Threshold |
| ------ | --------- | ------------------ |
| ETH    | 2.5%      | 85%                |
| wBTC   | 3%        | 78%                |
| wstETH | 4%        | 79%                |
| STRK   | 6%        | 63%                |
| xSTRK  | 7.5%      | 60%                |
| sSTRK  | 9%        | 60%                |
| EKUBO  | 5%        | 60%                |

{% hint style="info" %}
New collateral types will be added in short order.
{% endhint %}

An asset's risk profile (i.e. base rate, threshold, cap) will be determined in accordance with the [onboarding guidelines](technical-documentation/governance/onboarding-collateral.md).

Collateral that is accepted may subsequently be temporarily suspended, depending on various factors such as the market conditions for that collateral asset. Suspended assets will have their thresholds gradually decrease linearly over a 6-month period towards zero.

If an asset is suspended for longer than 6 months, it will be permanently delisted. At that point, the suspended asset will be treated as having zero value.

## What is a Trove?

A Trove is where you take out and maintain a loan, similar to a Vault or collateralized debt position (CDP) in other similar protocols.

A single Starknet address can own multiple troves.

Once an address opens a Trove, it becomes the owner of that Trove permanently. Therefore, a Trove that has its debt fully repaid can subsequently be used by the same owner to borrow CASH.

## What are the costs of borrowing CASH?

There are two charges associated with borrowing CASH:

1. a compounding interest rate on the amount borrowed so far that is calculated based on the collateral profile of the Trove, multiplied by the global multiplier value; and
2. a one-off forge fee if the spot price of CASH is below peg at the time of borrowing.

## How is the interest rate calculated?

The interest rate of a Trove is obtained by multiplying:

1. the weighted average of the base rate of each collateral deposited by the Trove, as a percentage of the total Trove's value; with
2. the global multiplier value.

The base rate for a collateral is set by the admin, and will eventually be handed over to governance.

For example, if a Trove's value comprises 60% WBTC and 40% ETH, and WBTC and ETH have a base rate of 2% and 3% respectively, then the weighted average base rate of the Trove is $$60\% \cdot 2\% + 40\% \cdot 3\% = 2.6\%$$.

{% hint style="info" %}
If a Trove only deposits one type of collateral, then the weighted average base rate is simply that collateral's base rate.
{% endhint %}

## What is the multiplier?

The interest rate multiplier is a global value that is applied to the interest rate of all Troves.&#x20;

It is determined by a proportional-integral-derivative (PID) controller that actuates the multiplier value based on the deviation of the spot price of CASH in the market from its peg price. The Controller operates in an autonomous manner without the need for any manual input, other than a price feed for the spot price of CASH.

The Controller will not be active at launch. Until the Controller is deployed, the multiplier will be set to 1, meaning that the base interest rate of Troves shall remain unchanged.

## How is the threshold calculated?

Similar to the interest rate, the threshold for a trove is the weighted average of the threshold of each collateral deposited by the trove, as a percentage of the total Trove's value.

The threshold for a collateral is set by the admin, and will eventually be handed over to governance.

For example, if a Trove's value comprises 60% WBTC and 40% ETH, and WBTC and ETH have a threshold of 90% and 80% respectively, then the weighted average base rate of the Trove is 60% \* 90% + 40% \* 80% = 86%.

Note that if a Trove only deposits one type of collateral, then the weighted average threshold is simply that collateral's threshold.

## When do I need to repay my loan?

You can repay your loan at any time, but your trove may be liquidated if your loan-to-value (LTV) ratio is below your trove's threshold.

## What happens if my Trove is liquidated?

A trove can be partially or fully liquidated.&#x20;

* In the case of a full liquidation, you will lose 100% of the collateral in your Trove, and the Trove's debt will be entirely repaid. This means that you no longer need to repay any debt on the liquidated Trove, and you will have no collateral left to withdraw. However, you will remain as the owner of the Trove, and you can use the same Trove to deposit new collateral and borrow CASH again.
* In the case of a partial liquidation, you will lose some of the collateral in your Trove, and the Trove's debt will be partially repaid. You will eventually still need to repay the outstanding remainder debt (which will accrue interest) in the Trove, and you will have some collateral left to withdraw subject to your Trove's health.


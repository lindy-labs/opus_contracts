# Liquidations and the Absorber

Opus has a multi-layered liquidation engine to protect the solvency of the protocol.

1. Searchers have first priority to liquidate an unhealthy trove once its loan-to-value (LTV) ratio exceeds its threshold. At this stage, searchers can choose to liquidate any amount up to the [minimum needed to make the trove healthy again](technical-documentation/smart-contracts/purger-module.md#close-amount) ("**close amount**").
2. If an unhealthy trove is still not liquidated after its [maximum possible liquidation penalty](technical-documentation/smart-contracts/purger-module.md#liquidation-penalty) has been reached OR it has a threshold greater than 90% and its LTV exceeds its threshold, then anyone can use the Absorber's (i.e. stability pool) liquidity to perform a liquidation of the close amount. This is also referred to as an absorption.
3. If the Absorber has insufficient liquidity, then the debt and collateral of an unhealthy Trove is redistributed pro-rata among other troves. In the event that a pro-rata redistribution is not possible, then they will be transferred to the protocol.

## What are the incentives to perform a searcher liquidation?

If you are a searcher performing a liquidation, you will receive a proportion of the liquidated trove's collateral corresponding to the amount you are repaying on behalf of the liquidated trove plus a liquidation penalty on this amount, as a percentage of the trove's value, that is taken from the trove.

## What is the Absorber?

The Absorber is Opus' implementation of a stability pool, first pioneered by Liquity, adapted for a cross margin system. It pools liquidity from CASH holders that can be called upon by anyone to liquidate unhealthy Troves. The collateral from the liquidation, including the liquidation penalty, are then transferred to the Absorber and CASH holders who have provided liquidity to the Absorber get a pro-rata share of the liquidated collateral.

As absorptions occur, liquity providers will lose a pro-rata share of their CASH deposits, while gaining a pro-rata share of the liquidated collateral. Since absorptions are likely to receive a liquidation penalty, providers to the Absorber will therefore likely receive a greater value of collateral relative to the amount of CASH that has been used for absorptions.

In Opus, liquidity providers may also receive CASH distributions from the protocol's income (e.g. accrued interest and fees).

## Why should I provide CASH to the Absorber?

Users who provide CASH to the Absorber will receive:

1. a pro-rata share of collateral assets from absorptions;
2. a pro-rata share of CASH from the protocol's income, if any;
3. a pro-rata share of reward tokens, if any.

Providers may choose to withdraw their share of collateral assets and reward tokens at any time.&#x20;

For CASH that is distributed to the Absorber as protocol income, they will be automatically distributed between the providers actively providing liquidity at the time the Absorber receives the CASH distribution, and are similarly subject to be used for absorptions. Therefore, it is possible that a provider may be able to withdraw more CASH than was initially provided if no absorptions have occurred and some protocol income has been distributed to the Absorber.

## Can I lose money by providing liquidity to the Absorber?

Yes, it is possible that a liquidated Trove has more debt than its collateral is worth, such as in a flash crash of prices or an oracle failure. This could result in the gain from collateral being of less value than the amount of CASH used for the absorption.

In addition, although Opus takes extensive measures to secure and audit its code, there remains a risk that a hack or a bug results in losses for users.

## Can I withdraw my CASH from the Absorber anytime I want?

No, there are two preconditions that need to be satisfied before you may withdraw your earlier provided CASH from the Absorber.

1. The protocol must not be in recovery mode, unless global shutdown has taken place.
2. The provider must have submitted a request to withdraw liquidity and provided the request is still valid, the withdrawal must be made within the validity period, which is currently a window of 1 hour from the time that the timelock elapses.

The first condition that the protocol must not be in recovery mode is imposed to ensure that the Absorber is able to fulfill its function of securing the protocol's solvency right at the moment when such liquidity is most needed for liquidations i.e. when the protocol is in recovery mode, and liquidations are more likely due to the lowered thresholds.

The second condition is imposed to prevent sophisticated users from running a risk-free yield strategy that allows them to provide liquidity and gain from distributions of the protocol's income as well as rewards, while front-running absorptions by removing their liquidity right before it happens.

Note that a request is invalidated by any of the following:

* the user provides liquidity;&#x20;
* the user submits a new request;
* the validity period has elapsed; or
* the user has removed liquidity for the request.

## Are there any consequences for requesting to remove liquidity?

To prevent sophisticated providers from running a risk-free yield strategy that frontruns absorptions, the timelock duration increases by a factor of 5 if another request is submitted within the cooldown period of 7 days from the previous request. The timelock duration is capped at 7 days.

For example, assuming a provider submits a request at time X with an initial timelock duration of 1 minute, if the provider submits another request within the cooldown period of X + 7 days, then the timelock of the second request increases to 5 minutes, and the cooldown period resets.

Note that you may withdraw your share of collateral assets from absorptions at any time without removing your liquidity i.e. without the above restrictions.

## What are the incentives to perform an absorption?

To incentivize users to monitor and protect the solvency of Opus, anyone who performs an absorption will receive a compensation for doing so. A proportion of the liquidated trove's collateral is paid to the caller as compensation, capped at the lower of 50 USD in value or 3% of the trove's collateral.






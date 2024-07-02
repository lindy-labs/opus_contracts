# Recovery Mode

To protect the solvency of the protocol, the protocol may enter into a state known as Recovery Mode, whereby stricter conditions are imposed on all troves, in certain conditions as further described below.

## When is recovery mode triggered?

Recovery Mode is triggered when the aggregate loan-to-value ratio (LTV) of all troves exceeds a percentage of the aggregate threshold ("**target LTV**"). The target LTV is initially set to 70% of the aggregate LTV, but it is configurable between 50% to 100% and may be changed in the future.

## What happens when recovery mode is triggered?

During Recovery Mode, each trove will have its unique target LTV. Stricter conditions will be imposed on the actions that a trove owner can take (e.g. depositing collateral, withdrawing collateral, minting CASH or repaying CASH) depending on its LTV relative to its target:

* If a trove's LTV is at or below its target LTV, then the trove owner cannot take an action that would cause its LTV to exceed its target LTV.
* If a trove's LTV exceeds its target LTV, then the trove owner cannot take an action that would cause its LTV to worsen.
* If a trove's LTV exceeds its target LTV, and the aggregate LTV of all troves has exceeded the target LTV with the additional buffer, then the trove's threshold would be decreased by up to 50% depending on the extent to which its LTV exceeds this target.&#x20;

## What is the purpose of Recovery Mode?

Recovery Mode is intended to incentivize borrowers to either top-up more collateral or to repay their debt. The possibility that it will be activated also acts to steer user behaviour away from allowing it to be activated in the first place.

Lowering the thresholds of troves with a LTV greater than their target increases their risk of liquidation, which would in turn help to restore the aggregate troves' LTV to below the target percentage of the aggregate threshold. This improves the health of the protocol, which in turn ensures its solvency.

## When do thresholds start to decrease in Recovery Mode?

Threshold will start to decrease when the aggregate LTV of all troves exceeds the target LTV with the additional buffer factor. Initially, this is set to 75% of the aggregate threshold, where the target LTV is set at 70% and the buffer is set at 5%. Note that the buffer is configurable between 1% to 10%, and may be changed in the future. This buffer allows users some time to respond to the change in market conditions.

## Does Recovery Mode change how liquidations can occur?

No, the multi-layered liquidation design is intended to operate as it is in Recovery Mode, based on the new thresholds adjusted by Recovery Mode.

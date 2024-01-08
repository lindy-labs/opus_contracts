---
description: Stability pool as the secondary layer of liquidations
---

# Absorber Module

The Absorber is Opus' implementation of a stability pool that allows yin holders to provide their yin and participate in liquidations (i.e. absorptions) as a consolidated pool.&#x20;

By providing their `yin` to the Absorber, users will be able to:

1. share in the absorption rewards (also referred to as "absorbed assets");
2. receive yield in the form of a portion of the `yin` minted from debt surpluses (e.g. interest from troves and forge fees);
3. share in any additional reward tokens that may be distributed by the protocol or other parties.

Note that there are preconditions to subsequently removing `yin` that was provided earlier.

To prevent confusion with "deposit" and "withdrawal" of `yang` for trove users, we use "provide" and "remove" to refer to users who deposit and withdraw `yin` from the Absorber.

## Description of key functions

1. `provide`: users may provide `yin` and receive internal shares&#x20;
2. `remove`: users who have provided `yin` previously may remove their remaining entitlement provided they have submitted a request (see below) and the conditions for the request have been fulfilled
3. `request`: users may request to `remove` their earlier provided `yin`
4. `reap`: withdraw a provider's entitlement to absorbed assets and rewards
5. `update`: inform the Absorber that an absorption has occured so that the Absorber can account for the absorbed assets. This is intended for the Purger.

## Providing liquidity

<figure><img src="../.gitbook/assets/image (12).png" alt=""><figcaption></figcaption></figure>

When a user provides `yin` to the Absorber, the user is issued a number of shares in an epoch for internal accounting purposes. The epoch starts from index 1, and is incremented when either (1) the Absorber's `yin` balance falls below the minimum amount; or (2) the amount of `yin` per share falls below a certain threshold.

The internal shares are used to account for the following:

1. the remaining amount of `yin` that a provider is entitled to withdraw;
2. the amount of absorbed assets the provider is entitled to based on the absorptions that have occurred while the provider has some entitlement of `yin` in the Absorber; and
3. the amount of rewards, if any, that a provider is entitled to withdraw.

On rare occasions, it is possible for a provider's shares to be carried over to the next epoch if the Absorber still has `yin`. This may happen if the trigger for the new epoch is the amount of yin represented per share falling below a certain threshold. In these cases, we keep track of a conversion rate of an epoch's share to the next epoch's share, and calculate the provider's entitlement in the new epoch. There may be some precision loss from this share conversion across epochs that will favour the protocol.

### Initial shares

Similar to the Gate, the Absorber is also susceptible to the first depositor front-running issue. To mitigate against this by increasing the cost of such an attack, a minimum amount of shares (`1000`) is minted into oblivion at the start of each epoch. This is either deducted from the `yin` provided by the first provider of the epoch or from the leftover `yin` of the previous epoch.

### Absorbed assets

Similar to redistributions in Shrine, absorptions are tracked with an absorption ID using a computation-heavy approach:

* Absorption ID starts from 1. 0 is used as the terminating condition.
* Each absorption is tied to an epoch.
* When `absorb` is called, we derive the amount of absorbed assets that each unit of internal share is entitled to.&#x20;

To calculate a provider's entitlement to absorbed assets, we iterate over the absorption IDs that have occurred since the provider's last absorption ID, and for each absorption ID, we multiply the provider's shares with the corresponding amount of each absorbed asset.

Note that the amount of shares that is minted into oblivion at the start of each epoch is excluded when calculating each share's entitlement to absorbed assets.

### Rewards

The Absorber supports distribution of whitelisted rewards. The only requirement is that the vesting contracts adhere to the `Blesser` interface. Caution should be exercised (e.g. checking for non-standard behaviour like blacklists) when whitelisting a reward token to ensure that a failure to vest reward tokens does not cause an absorption to revert.&#x20;

The accounting and distribution of rewards is functionally similar to that of absorbed assets. The only difference is that rewards are vested whenever a user action is taken (i.e. `provide`, `remove`, `reap`, `update`), in addition to when an absorption occurs (`update`).

Note that the amount of shares that is minted into oblivion at the start of each epoch is excluded when calculating each share's entitlement to rewards.

### Minimum shares for Absorber to operate

As the initial amount of shares minted into oblivion are excluded from receiving absorbed assets and rewards, there is a potential overflow issue when attempting to distribute absorbed assets and rewards if the remaining shares is a very small number.&#x20;

To mitigate against potential overflows, the Absorber is available for absorptions only if there is a minimum number of shares (currently set at `10 ** 6`), even if there is some `yin` in the Absorber.

Note that this requirement is distinct from, and in addition to, the initial shares that is minted to oblivion at the start of each epoch to address the first depositor front-running issue.

## Removing liquidity

<figure><img src="../.gitbook/assets/image (13).png" alt=""><figcaption></figcaption></figure>

A provider who has provided `yin` can subsequently elect to remove such remaining amount. If the Absorber's `yin` has been fully used for a provider's epoch, then the provider may not have any remaining `yin`  entitlement to be withdrawn.

There are two preconditions for removal:

1. if the Shrine is live, the Shrine must not be in recovery mode; and
2. the provider must have submitted a `request` and the removal must be made within the validity period.

Once a provider has submitted a `request`, the timelock (initial value of 1 minute) will start counting down. Once the timelock has elapsed, the provider has 1 hour to call `remove` before the `request` expires. In addition, if a subsequent `request` is made within the cooldown period (currently set at 7 days) of the earlier `request`, then the timelock will increase by a factor of 5, capped at a maximum of 7 days.

The purpose of imposing these restrictions are to:

1. ensure there is sufficient liquidity to absorb any prospective liquidations when the risk of liquidations across the high in recovery mode;
2. prevent risk-free yield-farming tactics where a provider earns yield in the form of interest and reward tokens, if any, but frontruns liquidations by removing liquidity just before the liquidation happens.

Regardless of whether the provider has any remaining `yin` entitlement to be withdrawn, any absorbed assets and rewards that the provider is entitled to will also be withdrawn.

## Withdrawing absorbed assets and rewards

<figure><img src="../.gitbook/assets/image (14).png" alt=""><figcaption></figcaption></figure>

A provider may also opt to withdraw absorbed assets and rewards only by calling `reap`. This action is not subject to any preconditions.

## Emergency Mechanism

The Absorber has a `kill` function that:

1. irreversibly pauses `provide`, preventing users from providing further liquidity; and&#x20;
2. irreversibly pauses the distribution of all rewards, if any.

Users will still be able to `remove` their liquidity after the Absorber is killed.

Note that the Caretaker does not automatically kill the Absorber during global shutdown because the Absorber may be a recipient of any final debt surplus that is minted before final settlement in the Shrine.

In addition, `yin` that has been provided to the Absorber may still be used for absorptions after the Absorber is killed.

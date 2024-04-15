---
description: The user interface of the Shrine
---

# Abbot Module

The Abbot module acts as the sole interface for users to open and manage troves. Further, the Abbot plays an important role in enforcing that trove IDs are issued in a sequential manner to users, starting from one.&#x20;

The Abbot module is intended to be immutable and deployed only once per synthetic.

## Key concepts

1. `deposit` and `withdraw` refers to collateral.
2. `forge` and `melt` refers to the minting and repayment (plus burning) of the synthetic respectively.

## Description of key functions

1. `open_trove`: sets the caller as the owner of a trove ID, deposits collateral tokens of `yang`s into the trove, and forges debt for the trove. Other than setting the owner of a trove ID, this function is essentially a wrapper of `deposit` and `forge`.
2. `close_trove`: repay all debt for a trove and withdraw all collateral tokens of `yang`s. This function does not have any effect on the owner of the trove, which remains unchanged, and the trove owner can re-use this trove in the future. Therefore, this function is essentially a wrapper of `melt` and `withdraw`.
3. `deposit`: Deposit collateral tokens for a `yang` from the caller into a trove. The caller must be the trove owner.
4. `withdraw`: Withdraw collateral tokens for a `yang` from a trove to the caller, who must be the trove owner
5. `forge`: Increase the debt for a trove and mint `yin` to the caller, who must be the trove owner
6. `melt`: Decrease the debt for a trove and burn `yin` from the caller

## Opening a trove

Before any actions can be taken, a user needs to first open a trove by depositing collateral and forging some debt.\
\
Opening a trove reserves a trove ID and makes the caller address the owner of that trove. This is significant because only the owner of a trove can deposit and withdraw collateral from the trove or forge synthetic with the trove's collateral.

## Depositing collateral

<figure><img src="../.gitbook/assets/image (8).png" alt=""><figcaption></figcaption></figure>

When a user deposits collateral into a trove, the underlying tokens are transferred to the Gate for that collateral, and the trove is incremented with the corresponding amount of that `yang` in Shrine.

## Withdrawing collateral

<figure><img src="../.gitbook/assets/image (9).png" alt=""><figcaption></figcaption></figure>

When a user withdraws collateral from a trove, the underlying tokens are transferred from the Gate for that collateral to the user, and the corresponding amount of that `yang` is decremented from the trove in Shrine.

Note that there are a couple of restrictions when it comes to withdrawing collateral from a trove:

1. Only the trove owner can withdraw collateral from a trove.
2. Withdrawal of collateral will revert if it causes the trove's loan-to-value ratio to fall below its threshold.
3. If the trove has non-zero debt, withdrawal of collateral will revert if it causes the trove's value to fall below the minimum value.

## Forging synthetic

<figure><img src="../.gitbook/assets/image (6).png" alt=""><figcaption></figcaption></figure>

When a user forges synthetic for a trove, the synthetic is minted by the Shrine directly to the user. The amount forged is then added to the trove's debt and starts to accrue interest.

Note that there are a couple of restrictions when it comes to forging synthetic for a trove:

1. Only the trove owner can forge synthetic for a trove.
2. Forging of the synthetic will revert if it causes the trove's loan-to-value ratio to fall below its threshold.
3. If the trove has non-zero debt, forging of the synthetic will revert if the trove's value is below the minimum value.

## Melting synthetic

<figure><img src="../.gitbook/assets/image (7).png" alt=""><figcaption></figcaption></figure>

When a user melts synthetic for a trove, the synthetic is directly burnt from the user. The amount melted is then decremented from the trove's debt.

Note that anyone can melt synthetic for a trove. Users interacting with the Abbot without a user interface should exercise caution.

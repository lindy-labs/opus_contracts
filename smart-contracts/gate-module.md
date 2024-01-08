---
description: Adapters for collateral tokens
---

# Gate Module

The Gate module acts as an adapter and custodian for collateral tokens. When users deposit collateral into a trove, the underlying collateral token is sent to the Gate module. Each collateral token will have its own Gate module.

As the Gate is an internal-facing module, users will not be able to, and are not expected to, interact with the Gate directly.

## Description of key functions

1. `enter`: transfers a specified amount of the collateral token from the user to the Gate, and returns the corresponding amount of `yang` .
2. `exit`: transfers an amount of the collateral token corresponding to the specified amount of `yang` from the Gate to the user, and returns the corresponding amount of assets.

## Conversion of assets to and from \`yang\`&#x20;

The Gate module does not enforce a fixed conversion rate from the underlying collateral token to `yang` and vice versa. Instead, the conversion rate is calculated based on the total `yang` amount in Shrine and the collateral token balance of the Gate module at the time of the transaction. This is intentional so that redistributions of collateral in the Shrine can be efficiently performed via rebasing i.e. the amount of underlying collateral token corresponding to per unit of `yang` increases.

A consequence of this design is that it exposes the Gate module to the first depositor front-running vulnerability that is known to afflict ERC-4626. The conventional approach to defend against this exploit is to deduct a small amount of shares from the first depositor and mint it to the zero address so that this amount is non-withdrawable but is accounted for in the total supply when calculating the conversion rate. \
\
In the case of Opus, we mitigate against this vulnerability by requiring a small amount of collateral token (and consequently the `yang` representing this amount) to be donated to the Shrine upon adding the collateral as a `yang` in Shrine via the Sentinel module. This lets Opus bear the burden of the initial deposit instead of the first depositor.&#x20;

## Rounding

Both `enter` and `exit` performs rounding down by default in favour of the protocol.

* When depositing collateral tokens for `yang`, the amount of `yang` is rounded down.
* When withdrawing `yang` for collateral tokens, the amount of collateral tokens is rounded down.

## Properties

These are some properties of the Gate module that should hold true at all times:

1. The conversion rate of a `yang` to its underlying collateral asset is monotonic while the Shrine is live, meaning it never decreases in value.
2. The conversion rate of a `yang` to its underlying collateral asset should remain unchanged in both `enter` (if there is non-zero amount of the collateral asset before `enter` ) and `exit` (if there is non-zero amount of the collateral asset after `exit`)

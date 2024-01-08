---
description: Internal router and gatekeeper for Gates
---

# Sentinel Module

The Sentinel module acts as the internal interface for other modules to interact with Gates. By routing actions involving a collateral to its Gate, the Sentinel abstracts away the need for other modules to know of each Gate's deployed address. It also simplifies the access control between other modules and the Gates - the Sentinel needs to be approved for each Gate module, but other modules that need to interact with the Gates only need to be approved for the Sentinel.

As a wrapper around Gates, the Sentinel mimics the Gate's functions with an additional parameter for the collateral token's address.

In addition, the Sentinel also acts as a gatekeeper by:

1. adding a collateral token as `yang` to the Shrine, ensuring the Gate has been deployed for the token, and enforcing an initial minimum deposit paid for by the protocol to guard against the first depositor front-running; and
2. ensuring that the total amount of underlying collateral tokens for a `yang` does not exceed its supply cap.

## Description of key functions

* `enter`: calls `Gate.enter` of the Gate for the given yang
  * Reverts if the amount of collateral tokens deposited will raise the protocol's balance above the cap for that `yang`
* `exit`:  calls `Gate.exit` of the Gate for the given yang

## Emergency mechanisms

The Sentinel has a `kill_gate()` function that irreversibly pauses `enter` for a Gate when interacting via the Sentinel. This prevents users from depositing further amounts of that `yang`'s collateral token. `exit` will still function as usual so as to allow users to withdraw and for the protocol to wind down.

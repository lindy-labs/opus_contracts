---
description: EIP-3156 Flash Loans
---

# Flash Mint Module

The Flash Mint module is an implementation of EIP-3156 that lets user borrow and repay `yin` in the same transaction.&#x20;

* Flash mints are fee-less.
* The maximum amount that can be borrowed will be a percentage of the circulating `yin` supply.

Note that while the maximum percentage is fixed as a constant, it can be easily adjusted by re-deploying the contract with a different constant should the protocol or governance decide to do so.

## Interaction with the debt ceiling

An important implementation detail is that the Flash Mint module needs to temporarily raise the debt ceiling if the debt ceiling has been exceeded, or will be exceeded as a result of the loan amount.


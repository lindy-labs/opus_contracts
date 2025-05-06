---
description: Direct minting of yin with equivalent assets
---

# Transmuter Module

The Transmuter module allows users to mint yin with a specified asset of equivalent value, and consequently to burn yin in exchange for the same asset. For example, where the yin is a USD-pegged stablecoin, users can use the Transmuter module to mint CASH using USDC on a 1 : 1 basis, subject to a fee if any.

Note that the predetermined asset that has been deposited in exchange for yin can be transferred to an address determined by the admin address (initially the team, and eventually handed over to governance) via `sweep`. This allows the protocol to deploy those assets as it sees fit. In the event of shutdown, it is envisioned that such amounts will be transferred back to the Transmuter for yin holders to reclaim a proportionate share in exchange for their yin's value.

Each Transmuter will be tied to a specific asset. Hence, there may be multiple transmuters for different assets, or even multiple transmuters for the same asset.

For the purposes of bootstrapping the protocol, a restricted variant of the Transmuter has been deployed at launch that allows only the admin multisig to mint up to 250,000 CASH with USDC. Additionally, the USDC has been exchanged for [Spiko](https://www.spiko.io/)'s US Dollar Money Market Fund tokens to generate yield for the protocol.

## Description of key functions

1. `transmute`: mint an amount of yin by depositing an equivalent amount of the predetermined asset, subject to fees if any
2. `reverse`: burn an amount of yin to receive an equivalent amount of the predetermined asset, subject to fees if any
3. `reclaim`: burn an amount of yin to receive a proportionate amount of the predetermined asset in the event of shutdown

## Transmuting asset into yin

<figure><img src="../../.gitbook/assets/image (19).png" alt=""><figcaption></figcaption></figure>

A user can mint yin by depositing the specified asset, subject to the following conditions:

* the amount minted would not cause the total amount minted from the transmuter to exceed its percentage cap of the total yin supply;&#x20;
* the yin ceiling for the transmuter will not be exceeded;
* the spot price of yin is at or greater than the peg price; and
* the Transmuter has not been shut down.

Note that a fee of up to 1% may be charged. The fee, if any, will be charged in yin. For example, assuming a 1% fee for a USD-pegged yin, a user that transmutes 100 USDC will receive 99 yin.

## Reversing yin into asset

<figure><img src="../../.gitbook/assets/image (20).png" alt=""><figcaption></figcaption></figure>

A user can mint yin by depositing the specified asset, subject to the following conditions:

* the admin has enabled the reverse functionality;
* there is a sufficient amount of the specified asset in the Transmuter; and
* the Transmuter has not been shut down.

Note that a fee of up to 1% may be charged. The fee, if any, will be charged in the asset. For example, assuming a 1% fee for a USD-pegged yin, a user that reverses 100 yin will receive 99 USDC.

## Reclaiming after shutdown

<figure><img src="../../.gitbook/assets/image (21).png" alt=""><figcaption></figcaption></figure>

When the Transmuter is shut down, any yin holder may choose to burn yin and receive a proportionate share of the assets in the Transmuter, provided that the admin has enabled the reclaim functionality.

## Shutdown and Emergency Mechanism

Each Transmuter has an emergency `kill` function that irreversibly pauses `transmute` and `reverse`.

Alternatively, a Transmuter can be gracefully deprecated via `settle`, which uses its yin balance to pay down the amount it has minted, and then transfers all remaining yin and assets to an admin-appointed address. Any shortfall of yin will be incurred as a deficit in the Shrine module.

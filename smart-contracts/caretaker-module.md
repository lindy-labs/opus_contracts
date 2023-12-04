---
description: Global shutdown
---

# Caretaker Module

The Caretaker module is responsible for deprecating the entire protocol, and particularly the Shrine,  in a graceful manner by allowing `yin` holders to claim collateral backing their `yin`. Note that other modules such as the Transmuter may have their own shutdown mechanisms that fall outside the purview of the Caretaker, and which similarly backs some amount of `yin` with an equivalent value in assets as far as possible.

## Description of key functions

* `shut`: executes global shutdown by permanently disabling user actions for the Shrine and transferring a percentage of the collateral backing the prevailing total troves' debt to the Caretaker
* `release`: allow trove owners to withdraw all collateral from their trove after global shutdown
* `reclaim`: allow `yin` holders to burn `yin` and receive a percentage of the collateral in the Caretaker, up to the total troves' debt

## Shutdown

<figure><img src="../.gitbook/assets/image (15).png" alt=""><figcaption></figcaption></figure>

Once `shut` is executed, all troves' debt cannot be repaid, and all collateral that is needed to back the value of the total amount of debt forged by troves is transferred from the Shrine to the Caretaker. Anyone may then subsequently burn `yin` to claim a proportional percentage of this collateral, up to the total amount of the troves' debt that the Caretaker is supposed to back. The total troves' debt at the time of shutdown is stored in the Caretaker, and is gradually decremented as users call `reclaim`.

The transfer of collateral at the time of shutdown acts as a final system-wide redistribution on all trove owners because the same percentage of all `yang`s are transferred to the Caretaker.

* This also means that if the total value of `yang`s in the Shrine is less than the total amount of troves' debt, then there would be no collateral remaining for trove owners to withdraw because the entire amount of `yang`s will be used to back the circulating `yin` representing the total amount of troves' debt.

Note that `release` and `reclaim` can be called only after `shut` has occurred.

## Redeeming \`yin\` for assets

<figure><img src="../.gitbook/assets/image (17).png" alt=""><figcaption></figcaption></figure>

After global shutdown, `yin` holders may exchange their `yin` for a percentage of the collateral assets in the Caretaker. The amount of assets a `yin` holder is entitled to is proportional to the remaining amount of `yin` that is reclaimable. Users may rely on `preview_reclaim` to determine the amount of assets they are entitled to for a given `yin` amount.

## Withdrawing remaining collateral from troves

<figure><img src="../.gitbook/assets/image (16).png" alt=""><figcaption></figcaption></figure>

After global shutdown, trove holders may withdraw all remaining collateral in their troves. Due to the system-wide redistribution during global shutdown, the amount of collateral remaining for withdrawal will likely be a fraction of what was deposited in the trove prior to global shutdown. Trove owners may rely on `preview_release` to determine the amount of assets they are entitled to withdraw from their trove.


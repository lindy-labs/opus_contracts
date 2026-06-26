# Topup Rite

#### Topup (`TOPUP`)

Topup replenishes a destination address when its balance of a tracked asset falls below a configured minimum. CASH is borrowed and swapped for the tracked asset (if it is not CASH), then sent to the destination address.

As we will be running a keeper to monitor and trigger this Topup Rite, users can enjoy a frictionless instantaneous auto-topup experience without incentivizing keepers.

At the moment, the following tokens are supported:

* CASH
* USDC

If you would like a token to be supported, please reach out to us on Discord.

## How is this useful to you?

* Automatically topup USDC to your Ready Card. You can use this as your main source of funding (borrow in advance and repay later), as a fallback for everyday use, or when it is sensible to keep a low balance (e.g. travelling).
* Automatically fund your hot wallet via your cold wallet.

## Technical Details

As this is a one-off rite, `has_ended()` always returns `true`.

The parameters for topup are as follows:

| Field               | Description                                                                                    |
| ------------------- | ---------------------------------------------------------------------------------------------- |
| `asset`             | Asset to top up. This can be CASH or any ERC-20 token.                                         |
| `topup_amount`      | Amount to deliver. Set this to `0` to disable the rite.                                        |
| `destination`       | Address that receives the topped-up asset.                                                     |
| `min_asset_balance` | Trigger threshold. The rite becomes ready when the destination balance falls below this value. |
| `slippage`          | Max acceptable price impact and minimum output protection. The cap is `20%`.                   |
| `pool_params`       | Ekubo pool parameters: `fee`, `tick_spacing`, and `extension`.                                 |




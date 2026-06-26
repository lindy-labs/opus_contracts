# Topup Rite

#### Topup (`TOPUP`)

Topup replenishes a destination address when its balance of a tracked asset falls below a configured minimum. CASH is borrowed and swapped for the tracked asset (if it is not CASH), then sent to the destination address.

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




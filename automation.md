# Automation

Automation lets you attach **actions** to your Trove that can be called by anyone when the conditions you define are met. You don't need to be online. You don't need to watch charts. A decentralized network of **keepers** — anyone motivated by a small CASH reward you set — will trigger your action for you.

Think of it like a standing order at a bank, except it's trustless, permissionless, and runs on-chain.

### How it works

1. **You choose an action** and configure it for your Trove — for example, "keep this address topped up with USDC."
2. **You set a keeper reward** in CASH. This incentivizes third parties (keepers) to monitor and trigger your action. This is optional.
3. **A keeper triggers the action** whenever your conditions are met. They receive the CASH reward, if any, as compensation.

You stay in full control. You can change or remove your action at any time, even while one is in progress.

### Safety controls

When you set up automation on your Trove, you define guardrails that protect you:

* **Safety limit** — a maximum loan-to-value (LTV) boundary as a percentage of your Trove's threshold. If the action would push your Trove past this limit, it won't execute. Your Trove stays safe.
* **Max borrow fee** — a cap on the protocol borrowing fee you're willing to accept. If the fee is too high at execution time, the action is skipped.
* **Keeper reward** — the amount of CASH minted to the keeper who triggers the action. You choose how generous to be. A higher reward means faster execution. This is optional and can be set to zero.

You can stop the automation at any time.

## Auto-Topup

The first action available on Opus is Topup — it keeps any address funded with a token of your choice. As we will be running a keeper to monitor and trigger this Topup action, users can enjoy a frictionless instantaneous **Auto-Topup** experience without having to incentivze keepers.

At the moment, the following tokens are supported:

* CASH
* USDC

If you would like a token to be supported, please reach out to us on Discord.

### How is this useful to you?

* Automatically topup USDC to your Ready Card.&#x20;
  * You can use this as your main source of funding (borrow in advance and repay later).
  * You can set it up as a fallback for everyday use so you never run out of cash when you are the cashier and without your wallet or Ledger.
  * In circumstances where it is sensible to keep a low balance (e.g. travelling), and yet you still want cash to be readily available
* Automatically fund your hot wallet via your cold wallet.

**You configure:**

| Setting                | What it means                                                                                   |
| ---------------------- | ----------------------------------------------------------------------------------------------- |
| **Token**              | Which token to deliver (e.g., USDC)                                                             |
| **Amount**             | How much to deliver each time (e.g., 100 USDC)                                                  |
| **Destination**        | Where to send it (e.g., your wallet)                                                            |
| **Trigger**            | The balance threshold — when the destination's token balance drops below this, the action fires |
| **Slippage tolerance** | Your maximum acceptable price impact on the swap (up to 20%)                                    |

**What happens when it triggers:**

1. Your Trove borrows CASH (increasing your debt)
2. The CASH is swapped for your chosen token through Ekubo
3. The token is delivered to your destination address

You can disable Topup at any time by setting the amount to zero.

## For developers

Actions are implemented as permissionless external contracts. The technical details are covered [here](technical-documentation/smart-contracts/archabbot-module/).&#x20;

> Automation is early and evolving. More actions are coming. If you have an idea for one, we'd love to hear from you in Discord or [Telegram](https://t.me/Lucidx0).

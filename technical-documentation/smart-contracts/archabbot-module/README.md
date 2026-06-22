---
description: An upgraded Abbot enabling automation and leverage
---

# Archabbot Module

The Archabbot is an upgraded implementation of the Abbot — a trove manager — with support for automation (also known as **Rites**) and **flash-loan-powered leverage.**

It implements the same `IAbbot` interface as the [Abbot](../abbot-module.md), so standard trove operations work the same way. This includes `deposit`, `withdraw`, `forge`, `melt`, and `close_trove`.

Troves are still opened through the Abbot. `open_trove` is disabled on the Archabbot. This keeps the Abbot as the source of truth for trove ownership.

### What the Archabbot adds

* **Rites** — attachable automation modules that run predefined strategies.
* **Keeper incentives** — permissionless rite execution with user-defined CASH rewards to incentivize decentralized execution.
* **Per-trove safety config** — relative threshold and max forge fee controls for automation.
* **Leverage** — lever up and lever down on a collateral type in one transaction.

### Trove configuration for Rites

Each trove has a `TroveConfig` for users to define the parameters of what the Rite attached to it can perform.

| Field                | Type  | Description                                                                                                                                                                                                                                                                           |
| -------------------- | ----- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `relative_threshold` | `Ray` | <p>Safety multiplier on the trove liquidation threshold (<code>relative_threshold * threshold</code>). If execution of the Rite causes the trove's LTV to exceed this  value, then execution will revert.<br><br>Effective max LTV is  Set to <code>RAY_ONE</code> to disable it.</p> |
| `max_forge_fee_pct`  | `Wad` | <p>Maximum protocol borrow fee accepted when CASH is forged during execution of a Rite. If the borrow fee is greater than this value, then execution will revert.<br><br>Cap is <code>4.0</code> or <code>400%</code>. This acts as slippage protection for automated execution.</p>  |
| `incentive`          | `Wad` | CASH minted to the keeper that triggers a Rite. This must be greater than `0` to create a keeper incentive.                                                                                                                                                                           |

### Rites

A **Rite** is an external contract that implements `IRite`. It encodes an action or strategy that can be triggered by anyone if certain conditions specified by the trove owner for the Rite are met (`is_ready` returns `true`).

Each trove can have at most one rite attached at a time. The trove owner can swap rites at any time. This prevents a buggy rite from bricking a trove.

Rites can support arbitrary operations that do not interact with the trove at all. In this case, it behaves like a keeper-only workflow.

Developers can deploy and attach their own Rites. The frontend will only allow users to select whitelisted Rites. If you wish to whitelist your Rite, please reach out to us on Discord.

#### The `IRite` interface

```cairo
trait IRite<TContractState> {
   fn get_rite_id(self: @TContractState) -> ByteArray;
   fn get_trove_config(self: @TContractState, trove_id: u64) -> Span<felt252>;
   fn set_trove_config(ref self: TContractState, trove_id: u64, config: Span<felt252>);
   fn is_ready(self: @TContractState, trove_id: u64) -> bool;
   fn has_ended(self: @TContractState, trove_id: u64) -> bool;
   fn perform(ref self: TContractState, trove_id: u64);
   fn end(ref self: TContractState, trove_id: u64);
}
```

| Method                                  | Description                                                                                                    |
| --------------------------------------- | -------------------------------------------------------------------------------------------------------------- |
| `get_rite_id`                           | Human-readable identifier such as `"TOPUP"`.                                                                   |
| `get_trove_config` / `set_trove_config` | Rite-specific per-trove config, serialized as `Span<felt252>`. Only the trove owner can set it.                |
| `is_ready`                              | Returns whether the rite can execute. Long-running rites must also check whether the previous execution ended. |
| `has_ended`                             | Returns `true` for one-off rites. Long-running rites use this to report completion.                            |
| `perform`                               | Executes the rite. It must call `archabbot.on_rite_actions(...)` at least once.                                |
| `end`                                   | Settles a long-running rite. It is a no-op for one-off rites.                                                  |

Rites must register the `IRITE_ID` interface through SRC5 before the Archabbot accepts them.

#### Rite execution flow

```
Keeper calls execute_rite(trove_id)
  │
  ├─ Archabbot checks rite.is_ready()
  ├─ Archabbot locks trove_id in transient storage
  │
  ▼
Archabbot calls rite.perform(trove_id)
  │
  ├─ Rite calls archabbot.on_rite_actions(trove_id, [Action, ...])
  │    ├─ Archabbot verifies the caller is the rite for this trove
  │    ├─ Archabbot executes each action
  │    │    └─ `Forge` / `Melt` / `Deposit` / `Withdraw` / `None`
  │    └─ Archabbot increments the callback nonce
  │
  ├─ Rite may call on_rite_actions multiple times
  │
  ▼
Execution returns to Archabbot
  │
  ├─ Archabbot settles the keeper incentive in CASH
  ├─ Archabbot enforces the relative threshold
  ├─ Archabbot verifies at least one callback occurred
  ├─ Archabbot clears transient locks
  └─ Archabbot emits `RiteExecuted`
```

#### Rite actions

Rites instruct the Archabbot through `on_rite_actions`.

| Action                   | Description       | Details                                                   |
| ------------------------ | ----------------- | --------------------------------------------------------- |
| `Forge(amount)`          | Borrow CASH       | CASH is minted directly to the rite contract.             |
| `Melt(amount)`           | Repay CASH debt   | CASH is taken from the Archabbot balance.                 |
| `Deposit(AssetBalance)`  | Add collateral    | The rite must transfer the tokens to the Archabbot first. |
| `Withdraw(AssetBalance)` | Remove collateral | Collateral is sent directly to the rite contract.         |
| `None`                   | No-op             | Useful as a callback acknowledgement, including in `end`. |

#### Ending a rite

`end_rite(trove_id)` is owner-only. It calls `rite.end(trove_id)`.

The rite must still invoke `on_rite_actions` at least once. The relative threshold is **not** enforced after `end_rite`. This avoids bricking long-running rites that temporarily exceed the threshold during settlement.

### Safety mechanisms

* **Transient trove lock** to block concurrent rite execution on one trove.
* **Callback nonce** to enforce at least one `on_rite_actions` call.
* **SRC5 interface check** when setting a rite.
* **Relative threshold enforcement** after each rite execution.
* **Rite swapping at any time** to avoid permanent lock-in from buggy logic.

### Design principles for rites

* **No access control on execution.** Anyone can call `execute_rite`. Keeper incentives support decentralized execution.
* **User-configured over permissioned.** Users define parameters instead of relying on whitelists or admin gates.
* **One rite at a time.** Each trove has at most one active rite.
* **Callback enforcement.** Every rite must call `on_rite_actions` at least once.

### Implemented rites

* [#auto-topup-topup](./#auto-topup-topup "mention")

### Leverage

Leverage uses flash loans from the [Flash Mint Module](../flash-mint-module.md).

These flows are user-initiated. They are not automated by rites. They are also **not** subject to the relative threshold check. The user chooses the risk boundary through `max_ltv`.

#### Lever up

Lever up borrows CASH with a flash mint, swaps into collateral on Ekubo, deposits the collateral, and repays the flash loan from the trove debt.

| Field               | Description                                          |
| ------------------- | ---------------------------------------------------- |
| `trove_id`          | Target trove                                         |
| `max_ltv`           | Revert if the resulting LTV exceeds this value       |
| `yang`              | Collateral asset to acquire                          |
| `max_forge_fee_pct` | Max protocol fee accepted for the forge step         |
| `min_asset_amount`  | Minimum collateral to receive as slippage protection |
| `swaps`             | Ekubo route with one or more hops                    |

#### Lever down

Lever down flash-mints CASH, repays trove debt, withdraws collateral, swaps the collateral for CASH on Ekubo, and repays the flash loan.

Any remaining collateral is re-deposited. Any excess CASH is returned to the user.

| Field      | Description                                               |
| ---------- | --------------------------------------------------------- |
| `trove_id` | Target trove                                              |
| `max_ltv`  | Revert if the resulting LTV exceeds this value            |
| `yang`     | Collateral asset to unwind                                |
| `yang_amt` | Amount of collateral, in yang units, to withdraw and sell |
| `swaps`    | Ekubo route with one or more hops                         |

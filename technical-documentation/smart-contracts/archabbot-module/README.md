---
description: An upgraded Abbot enabling automation and leverage
---

# Archabbot Module

The Archabbot is an upgraded implementation of the Abbot — a trove manager — with support for automation (also known as **Rites**)**.**

It implements the same `IAbbot` interface as the [Abbot](../abbot-module.md), so standard trove operations work the same way. This includes `deposit`, `withdraw`, `forge`, `melt`, and `close_trove`.

Troves are still opened through the Abbot. `open_trove` is disabled on the Archabbot. This keeps the Abbot as the source of truth for trove ownership.

## Automation

Rites are attachable automation modules that run predefined strategies. These strategies can be executed by anyone in a permissionless manner as long as the specified conditions are satisfied, subject to the following parameters and limitations that the user configures in advance:

| Field                | Type  | Description                                                                                                                                                                                                                                                                           |
| -------------------- | ----- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `relative_threshold` | `Ray` | <p>Safety multiplier on the trove liquidation threshold (<code>relative_threshold * threshold</code>). If execution of the Rite causes the trove's LTV to exceed this  value, then execution will revert.<br><br>Effective max LTV is  Set to <code>RAY_ONE</code> to disable it.</p> |
| `max_forge_fee_pct`  | `Wad` | <p>Maximum protocol borrow fee accepted when CASH is forged during execution of a Rite. If the borrow fee is greater than this value, then execution will revert.<br><br>Cap is <code>4.0</code> or <code>400%</code>. This acts as slippage protection for automated execution.</p>  |
| `incentive`          | `Wad` | CASH minted to the keeper that triggers a Rite. This must be greater than `0` to create a keeper incentive.                                                                                                                                                                           |

### Rites

A **Rite** is an external contract that implements `IRite`. It encodes an action or strategy that can be triggered by anyone if certain conditions specified by the trove owner for the Rite are met (`is_ready` returns `true`).

Each trove can have at most one rite attached at a time. The trove owner can swap rites at any time. This prevents a buggy rite from bricking a trove.

Developers can deploy and attach their own Rites. However, only whitelisted Rites will be displayed on the frontend. If you wish to whitelist your Rite, please reach out to us on Discord.

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

In addition to implementing the `IRite` interface, a Rite must also satisfy the following requirements or execution will revert:

* it must register the `IRITE_ID` interface through SRC5; and
* it must make at least one callback with at least one action (could be `None`) to `archabbot.on_rite_actions(...)`.

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

### Implemented rites

* [topup-rite.md](topup-rite.md "mention")

### Using rites as keepers

Rites can support arbitrary operations that do not interact with the trove at all. In this case, it behaves like a keeper-only workflow that runs some arbitrary logic for your use case. The only requirement is to make a single `None` action callback to the Archabbot. This lets anyone take advantage of the harness (e.g. incentives) and keeper network already on Opus.

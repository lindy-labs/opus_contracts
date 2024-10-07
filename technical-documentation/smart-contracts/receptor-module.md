---
description: The controller's sensor
---

# Receptor Module

The Receptor module acts as the sensor of the Controller module by providing the yin's price to Shrine for the Controller to actuate on.

At the moment for CASH, the Receptor relies on Ekubo's [oracle extension](https://github.com/EkuboProtocol/oracle-extension) to read the median time-weighted average price (TWAP) of CASH / {DAI, USDC, USDT}. The TWAP duration is initially set to 3 hours but is expected to be adjusted downwards over time.

## Description of key functions

* &#x20;`update_yin_price` : fetch the current price of yin and submit it to Shrine. This is intended to be executed via the `ITask.execute_task()` interface.

## Conditions for triggering a yin price update

There are two possible ways in which a price update can be triggered:

1. sufficient time has elapsed from the last **successful** attempt to update yin's price; or
2. the caller has been granted access to call `update_yin_price`, bypassing the requirement in (1).

Option (2) is not used in the current design of the protocol.


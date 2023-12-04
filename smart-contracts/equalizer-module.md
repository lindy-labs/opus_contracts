---
description: The financial controller
---

# Equalizer Module

The Equalizer balances the budget of the Shrine by allowing the budget to be reset to zero from time to time, either by minting debt surpluses or by paying down debt deficits.

## Description of key functions

1. `equalize`: mint debt surpluses in the form of `yin` to the Equalizer itself if the Shrine has a positive bduget (this ensures that the amount of `yin` in circulation matches the total amount of debt in the Shrine, so as to prevent an “[infinite debt treadmill that requires ever-growing loans to sustain, and is never repayable](https://bank.dev/vox)”, albeit with a time lag)
2. `normalize`: pay down the debt deficit in the Shrine using the caller's `yin`
3. `allocate`: distribute the Equalizer's `yin` balance to the allocated recipients&#x20;

## Interaction with the debt ceiling

When minting debt surpluses, an important implementation detail is that the Equalizer needs to temporarily raise the debt ceiling if the debt ceiling has been exceeded, or will be exceeded after minting the debt surpluses. This ensures that `yin` can be minted, and there will not be a mismatch between debt and `yin` so that all debt can possibly be repaid.

## Distribution of income

Another important function that the Equalizer performs is the distribution of income to allocated recipients. When debt surpluses are minted, the `yin` is minted to the Equalizer's address. Anyone can then call `allocate` to distribute the `yin` in the Equalizer to the allocated recipients, which are provided by the Allocator module. The implementation of `allocate` is also flexible enough to let any address transfer `yin` to the Equalizer for distribution.

The initial implementation of the Allocator module is a simple contract that takes a list of recipients and their fixed allocated percentages. In the future, the Allocator module can encompass more complex logic for autonomous adjustment of the allocated percentages between a set of recipients.

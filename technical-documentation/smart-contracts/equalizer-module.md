---
description: The financial controller
---

# Equalizer Module

The Equalizer balances the budget of the Shrine by allowing the budget to be reset to zero from time to time, either by minting debt surpluses or by paying down debt deficits.

## Description of key functions

1. `equalize`: mint debt surpluses in the form of `yin` to the Equalizer itself if the Shrine has a positive budget (this ensures that the amount of `yin` in circulation matches the total amount of debt in the Shrine, so as to prevent an “[infinite debt treadmill that requires ever-growing loans to sustain, and is never repayable](https://bank.dev/vox)”, albeit with a time lag)
2. `normalize`: pay down the debt deficit in the Shrine using the caller's `yin`
3. `allocate`: distribute the Equalizer's `yin` balance to the allocated recipients&#x20;

## Interaction with the debt ceiling

When minting debt surpluses, an important implementation detail is that the Equalizer needs to temporarily raise the debt ceiling if the debt ceiling has been exceeded, or will be exceeded after minting the debt surpluses. This ensures that `yin` can be minted, and there will not be a mismatch between debt and `yin` so that all debt can possibly be repaid.

## Distribution of income

Another important function that the Equalizer performs is the distribution of income to allocated recipients. When debt surpluses are minted, the `yin` is minted to the Equalizer's address. Anyone can then call `allocate` to distribute the `yin` in the Equalizer to the allocated recipients, which are provided by the Allocator module. The implementation of `allocate` is also flexible enough to let any address transfer `yin` to the Equalizer for distribution.

The current Allocator module dynamically allocates protocol income between the Absorber and the Stabilizer according to the protocol solvency i.e. LTV. The rationale for doing so is to allow the allocation of protocol incentives to respond dynamically to the solvency conditions of the protocol. If the LTV rises above a predefined threshold, priority shifts towards ensuring protocol solvency by increasing the % distributed to the Absorber, so as to incentivize more CASH to be deposited to the Absorber for potential liquidations. Otherwise, the default is to prioritize LP staking for deeper liquidity. Shifting liquidity from LP staking to the Absorber when the protocol's LTV increases can additionally be justified on the basis that secondary market liquidity is less important if searcher liquidations are not occuring, for whatever reason, and therefore primary market liquidity in the Absorber is more useful.

The lower and upper thresholds at which this dynamic adjustment occurs are currently set to 60% and 80% of the protocol's threshold, the latter corresponding to the recovery mode target factor.

The proposed thresholds are as follows (expressed in terms of LTV), with allocation in the order of Absorber then LP staking:

* If protocol's LTV <= 60% of protocol's threshold, then allocation is always 25%-75%.
* If 60% < protocol's LTV <= 80% of protocol's threshold, then allocation is adjusted linearly in favour of the Absorber as LTV increases.
* If 80% < protocol's LTV, then allocation is always 75%-25%.

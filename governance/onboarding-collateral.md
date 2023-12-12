# Onboarding collateral

Opus can support many different assets as collateral. Internally, each collateral asset is referred to as a `yang` .

For each new `yang`, the following should be addressed at the point of onboarding:

* a risk analysis of the collateral asset;
* a technical assessment of the smart contract for the collateral;
* its availability as a price feed on the oracles currently onboarded.

## Risk analysis

The risk analysis should take into account the following when determining the base rate, threshold and asset cap:

* Decentralization: Is the protocol centralized or decentralized? How does governance operate and what powers does governance have?
* Token distribution: How many addresses possess the tokens? Is a significant percentage (>25%) controlled by a small number of addresses?
* Team: Who are the contributors to the token's protocol? What is their involvement? Are there any red flags?
* Historical liquidity: What is the amount of available liquidity historically? Has there been any issues?
* Historical supply-demand checks: What has the supply and demand of the token been? How did it perform during periods of volatile market activity?
* Valuation and tokenomics: How does the asset derive its value?

In particular, this is a list of non-negotiable requirements:

* The maximum cap for an asset cannot exceed 50% of its circulating supply.
* The threshold should not be higher than 97% to ensure absorption is profitable for providers to the Absorber.

## Technical Assessment

The technical assessment should take into account the following:

* Security: Have the contracts been reviewed? Was the audit report satisfactory?
* Communication: Are the developers contactable? Is there a security mailing list for critical announcements?
* Precision: What is the number of decimals of the token? Can it be easily integrated? Tokens with more than 18 decimals must be rejected.
* Total supply: Does the total supply exceed `u128`? If so, it must be rejected.
* Owner privileges: Is there a whitelist or blacklist? Is the token pausable? Who has the ability to mint new tokens? Is the contract upgradeable?&#x20;
* Deviation from ERC-20 standard: Is there any non-standard ERC-20 code in the token contract? Are there callbacks that may pose reentrancy issues?

In particular, this is a list of non-negotiable requirements:

* A `transfer` of zero amount is valid.
* A successful `transfer` returns `true`.

## Price oracles

The asset must have an available price feed on the oracles currently used by Opus.

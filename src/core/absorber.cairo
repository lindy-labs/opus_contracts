#[contract]
mod Absorber {
    use starknet::get_block_timestamp;
    use starknet::get_caller_address;

    use aura::utils::WadRay;
    use aura::utils::WadRay::Ray;
    use aura::utils::WadRay::Wad;
    //
    // Constants
    // 

    // If the amount of yin Wad per share drops below this threshold, the epoch is incremented
    // to reset the yin per share ratio to 1 : 1 parity for accounting. Otherwise, there will
    // eventually be an overflow when converting yin to shares (and vice versa)
    // as yin per share approaches 0.
    const YIN_PER_SHARE_THRESHOLD: u128 = 1000000000000000; // 10**15 = 0.001 (Wad)

    // Shares to be minted without a provider to avoid first provider front-running
    const INITIAL_SHARES: u128 = 1000; // 10 ** 3 (Wad);

    // Lower bound of the Shrine's LTV to threshold that can be set for restricting removals
    const MIN_LIMIT: u128 = 500000000000000000000000000; // 50 * WadRay::RAY_PERCENT = 0.5

    // Amount of time, in seconds, that needs to elapse after request is submitted before removal
    const REQUEST_BASE_TIMELOCK: u64 = 60;

    // Upper bound of time, in seconds, that needs to elapse after request is submitted before removal
    // 7 days * 24 hours per day * 60 minutes per hour * 60 seconds per minute
    const REQUEST_MAX_TIMELOCK: u64 = 604800; // 7 * 24 * 60 * 60

    // Multiplier for each request's timelock from the last value if a new request is submitted
    // before the cooldown of the previous request has elapsed
    const REQUEST_TIMELOCK_MULTIPLIER: u64 = 5;

    // Amount of time, in seconds, for which a request is valid, starting from expiry of the timelock
    // 60 minutes * 60 seconds per minute
    const REQUEST_VALIDITY_PERIOD: u64 = 3600; // 60 * 60

    // Amount of time that needs to elapse after a request is submitted before the timelock
    // for the next request is reset to the base value.
    // 7 days * 24 hours per day * 60 minutes per hour * 60 seconds per minute
    const REQUEST_COOLDOWN: u64 = 604800; // 7 * 24 * 60 * 60

    // Helper constant to set the starting index for iterating over the Rewards
    // in the order they were added
    const REWARDS_LOOP_START: u32 = 1;

    struct Storage {
        // mapping between a provider address and the purger contract address
        purger: ContractAddress,
        // mapping between a provider address and the sentinel contract address
        sentinel: ContractAddress,
        // mapping between a provider address and the shrine contract address
        shrine: ContractAddress,
        // boolean flag indicating whether the absorber is live or not
        live: bool,
        // epoch starts from 0
        // both shares and absorptions are tied to an epoch
        // the epoch is incremented when the amount of yin per share drops below the threshold.
        // this includes when the absorber's yin balance is completely depleted.
        current_epoch: ufelt,
        // absorptions start from 1.
        absorptions_count: ufelt,
        // mapping from a provider to the last absorption ID accounted for
        provider_last_absorption: LegacyMap::<ContractAddress, ufelt>,
        // mapping of address to a packed struct of
        // 1. epoch in which the provider's shares are issued
        // 2. number of shares for the provider in the above epoch
        provision: LegacyMap::<ContractAddress, packed>,
        // mapping from an absorption to its epoch
        absorption_epoch: LegacyMap::<ufelt, ufelt>,
        // total number of shares for current epoch
        total_shares: Wad,
        // mapping of a tuple of absorption ID and asset to a packed struct of
        // 1. the amount of that asset in its decimal precision absorbed per share Wad for an absorption
        // 2. the rounding error from calculating (1) that is to be added to the next absorption
        asset_absorption: LegacyMap::<(ufelt, ContractAddress), packed>,
        // conversion rate of an epoch's shares to the next
        // if an update causes the yin per share to drop below the threshold,
        // the epoch is incremented and yin per share is reset to one Ray.
        // a provider with shares in that epoch will receive new shares in the next epoch
        // based on this conversion rate.
        // if the absorber's yin balance is wiped out, the conversion rate will be 0.
        epoch_share_conversion_rate: LegacyMap::<ufelt, Ray>,
        // total number of reward tokens, starting from 1
        // a reward token cannot be removed once added.
        rewards_count: ufelt,
        // mapping from a reward token address to its id for iteration
        reward_id: LegacyMap::<ContractAddress, ufelt>,
        // mapping from a reward token ID to its Reward struct:
        // 1. the ERC-20 token address
        // 2. the address of the vesting contract (blesser) implementing `IBlesser` for the ERC-20 token
        // 3. a boolean indicating if the blesser should be called
        rewards: LegacyMap::<ufelt, Reward>,
        // mapping from a reward token address and epoch to a packed struct of
        // 1. the cumulative amount of that reward asset in its decimal precision per share Wad in that epoch
        // 2. the rounding error from calculating (1) that is to be added to the next reward distribution
        reward_by_epoch: LegacyMap::<(ContractAddress, ufelt), packed>,
        // mapping from a provider and reward token address to its last cumulative amount of that reward
        // per share Wad in the epoch of the provider's Provision struct
        provider_last_reward_cumulative: LegacyMap::<(ContractAddress, ContractAddress), ufelt>,
        // Removals are temporarily suspended if the shrine's LTV to threshold exceeds this limit
        removal_limit: Ray,
        // Mapping from a provider to its latest request for removal
        provider_request: LegacyMap::<(ContractAddress, Request)>
    }
}

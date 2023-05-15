#[abi]
trait IAbsorber {
    // view
    fn get_purger() -> ContractAddress;
    fn get_rewards_count() -> u32;
    fn get_rewards() -> (u32, Array<Reward>);
    fn get_current_epoch() -> u32;
    fn get_absorptions_count() -> u32;
    fn get_absorption_epoch(absorption_id: u32) -> u32;
    fn get_total_shares_for_current_epoch() -> u128;
    fn get_provider_info(provider: ContractAddress) -> Provision;
    fn get_provider_last_absorption(provider: ContractAddress) -> u32;
    fn get_provider_request(provider: ContractAddress) -> Request;
    fn get_asset_absorption_info(asset: ContractAddress, absorption_id: u32) -> AssetApportion;
    fn get_asset_reward_info(asset: ContractAddress, epoch: u32) -> AssetApportion;
    fn get_provider_last_reward_cumulative(
        provider: ContractAddress, asset: ContractAddress
    ) -> u128;
    fn get_removal_limit() -> u128;
    fn get_live() -> bool;
    fn preview_remove(provider: ContractAddress) -> u128;
    fn preview_reap(
        provider: ContractAddress
    ) -> (Array<ContractAddress>, Array<u128>, Array<ContractAddress>, Array<u128>);
    // external
    fn set_purger(purger: ContractAddress);
    fn set_reward(asset: ContractAddress, blesser: ContractAddress, is_active: bool);
    fn set_removal_limit(limit: u128);
    fn provide(amount: u128);
    fn request();
    fn remove(amount: u128);
    fn reap();
    fn update(assets: Array<ContractAddress>, asset_amts: Array<u128>);
    fn kill();
    fn compensate(
        recipient: ContractAddress, assets: Array<ContractAddress>, asset_amts: Array<u128>
    );
}

#[abi]
trait IBlesser {
    // If no reward tokens are to be distributed to the absorber, `preview_bless` and `bless`
    // should return 0 instead of reverting.
    fn bless() -> u128;
    fn preview_bless() -> u128;
}

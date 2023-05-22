use starknet::ContractAddress;

use aura::utils::serde;
use aura::utils::types::{DistributionInfo, Provision, Request, Reward};
use aura::utils::wadray::Wad;

#[abi]
trait IAbsorber {
    // view
    fn get_rewards_count() -> u8;
    fn get_rewards() -> Span<Reward>;
    fn get_current_epoch() -> u32;
    fn get_absorptions_count() -> u32;
    fn get_absorption_epoch(absorption_id: u32) -> u32;
    fn get_total_shares_for_current_epoch() -> Wad;
    fn get_provision(provider: ContractAddress) -> Provision;
    fn get_provider_last_absorption(provider: ContractAddress) -> u32;
    fn get_provider_request(provider: ContractAddress) -> Request;
    fn get_asset_absorption(asset: ContractAddress, absorption_id: u32) -> DistributionInfo;
    fn get_cumulative_reward_amt_by_epoch(asset: ContractAddress, epoch: u32) -> DistributionInfo;
    fn get_provider_last_reward_cumulative(
        provider: ContractAddress, asset: ContractAddress
    ) -> u128;
    fn get_removal_limit() -> u128;
    fn get_live() -> bool;
    fn preview_remove(provider: ContractAddress) -> Wad;
    fn preview_reap(
        provider: ContractAddress
    ) -> (Span<ContractAddress>, Span<u128>, Span<ContractAddress>, Span<u128>);
    // external
    fn set_reward(asset: ContractAddress, blesser: ContractAddress, is_active: bool);
    fn set_removal_limit(limit: u128);
    fn provide(amount: Wad);
    fn request();
    fn remove(amount: Wad);
    fn reap();
    fn update(assets: Span<ContractAddress>, asset_amts: Span<u128>);
    fn kill();
    fn compensate(
        recipient: ContractAddress, assets: Span<ContractAddress>, asset_amts: Span<u128>
    );
}

#[abi]
trait IBlesser {
    // If no reward tokens are to be distributed to the absorber, `preview_bless` and `bless`
    // should return 0 instead of reverting.
    fn bless() -> u128;
    fn preview_bless() -> u128;
}

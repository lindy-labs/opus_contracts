use starknet::ContractAddress;

use aura::utils::serde;
use aura::utils::types::{DistributionInfo, Provision, Request, Reward};
use aura::utils::wadray::{Ray, Wad};

#[starknet::interface]
trait IAbsorber<TStorage> {
    // view
    fn get_rewards_count(self: @TStorage) -> u8;
    fn get_rewards(self: @TStorage) -> Span<Reward>;
    fn get_current_epoch(self: @TStorage) -> u32;
    fn get_absorptions_count(self: @TStorage) -> u32;
    fn get_absorption_epoch(self: @TStorage, absorption_id: u32) -> u32;
    fn get_total_shares_for_current_epoch(self: @TStorage) -> Wad;
    fn get_provision(self: @TStorage, provider: ContractAddress) -> Provision;
    fn get_provider_last_absorption(self: @TStorage, provider: ContractAddress) -> u32;
    fn get_provider_request(self: @TStorage, provider: ContractAddress) -> Request;
    fn get_asset_absorption(
        self: @TStorage, asset: ContractAddress, absorption_id: u32
    ) -> DistributionInfo;
    fn get_cumulative_reward_amt_by_epoch(
        self: @TStorage, asset: ContractAddress, epoch: u32
    ) -> DistributionInfo;
    fn get_provider_last_reward_cumulative(
        self: @TStorage, provider: ContractAddress, asset: ContractAddress
    ) -> u128;
    fn get_removal_limit(self: @TStorage) -> Ray;
    fn get_live(self: @TStorage) -> bool;
    fn preview_remove(self: @TStorage, provider: ContractAddress) -> Wad;
    fn preview_reap(
        self: @TStorage, provider: ContractAddress
    ) -> (Span<ContractAddress>, Span<u128>, Span<ContractAddress>, Span<u128>);
    // external
    fn set_reward(
        ref self: TStorage, asset: ContractAddress, blesser: ContractAddress, is_active: bool
    );
    fn set_removal_limit(ref self: TStorage, limit: Ray);
    fn provide(ref self: TStorage, amount: Wad);
    fn request(ref self: TStorage);
    fn remove(ref self: TStorage, amount: Wad);
    fn reap(ref self: TStorage, );
    fn update(ref self: TStorage, assets: Span<ContractAddress>, asset_amts: Span<u128>);
    fn kill(ref self: TStorage);
}

#[starknet::interface]
trait IBlesser<TStorage> {
    // If no reward tokens are to be distributed to the absorber, `preview_bless` and `bless`
    // should return 0 instead of reverting.
    fn bless(ref self: TStorage) -> u128;
    fn preview_bless(self: @TStorage) -> u128;
}

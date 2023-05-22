#[cfg(test)]
mod TestShrineCompound3 {
    use array::{ArrayTrait, SpanTrait};
    use debug::PrintTrait;
    use option::OptionTrait;
    use traits::{Into, TryInto};
    use starknet::{
        contract_address_const, deploy_syscall, ClassHash, class_hash_try_from_felt252,
        ContractAddress, contract_address_to_felt252, get_block_timestamp, SyscallResultTrait
    };
    use starknet::contract_address::ContractAddressZeroable;
    use starknet::testing::{set_block_timestamp, set_contract_address};

    use aura::core::shrine::Shrine;
    use aura::core::roles::ShrineRoles;

    use aura::interfaces::IERC20::{IERC20Dispatcher, IERC20DispatcherTrait};
    use aura::interfaces::IShrine::{IShrineDispatcher, IShrineDispatcherTrait};
    use aura::utils::access_control::{IAccessControlDispatcher, IAccessControlDispatcherTrait};
    use aura::utils::exp::exp;
    use aura::utils::serde;
    use aura::utils::u256_conversions;
    use aura::utils::wadray;
    use aura::utils::wadray::{Ray, RayZeroable, RAY_ONE, RAY_SCALE, Wad, WadZeroable, WAD_DECIMALS};

    use aura::tests::test_shrine::TestShrine::{admin, advance_interval, advance_prices_and_set_multiplier, compound_wrapper_for_yang, current_interval, FEED_LEN, deployment_interval, get_avg_multiplier, get_avg_yang_price, get_interval, shrine_setup_with_feed, TROVE_1, trove1_deposit, trove1_forge, TROVE1_FORGE_AMT, trove1_owner_addr, TROVE1_YANG1_DEPOSIT, yang1_addr, yang2_addr, YANG1_BASE_RATE, YANG1_START_PRICE, YANG2_START_PRICE};

    //
    // Tests - Trove estimate and charge
    // 

    fn setup_charge_scenario_4() -> (IShrineDispatcher, Wad) {
        let shrine: IShrineDispatcher = shrine_setup_with_feed();

        trove1_deposit(shrine, TROVE1_YANG1_DEPOSIT.into());
        let forge_amt: Wad = TROVE1_FORGE_AMT.into();
        trove1_forge(shrine, forge_amt);

        let yang1_addr = yang1_addr();

        let (_, _, _, debt) = shrine.get_trove_info(TROVE_1);
        let start_interval: u64 = current_interval();

        // Advance one interval to avoid overwriting the last price
        advance_interval();

        // Advance timestamp by given intervals and set last updated price - `T+LAST_UPDATED`
        let intervals_to_skip: u64 = 5;
        advance_prices_and_set_multiplier(
            shrine, intervals_to_skip, YANG1_START_PRICE.into(), YANG2_START_PRICE.into()
        );
        // Offset by 1 because of a single call to `advance_prices_and_set_multiplier`
        let last_updated_interval: u64 = start_interval + intervals_to_skip - 1;

        // Advance timestamp to `T+END`, to mock lack of price updates since `T+LAST_UPDATED`.
        // Trigger charge to update the trove's debt to `T+END`.
        let intervals_after_last_update: u64 = 15;
        let time_to_skip: u64 = intervals_after_last_update * Shrine::TIME_INTERVAL;
        let end_timestamp: u64 = get_block_timestamp() + time_to_skip;

        let end_interval: u64 = start_interval + intervals_to_skip + intervals_after_last_update;
        set_block_timestamp(end_timestamp);

        shrine.withdraw(yang1_addr, TROVE_1, WadZeroable::zero());

        // Manually calculate the average since end interval does not have a cumulative value
        let (_, start_cumulative_price) = shrine.get_yang_price(yang1_addr, start_interval);
        let (last_updated_price, last_updated_cumulative_price) = shrine
            .get_yang_price(yang1_addr, last_updated_interval);
        let intervals_after_last_update_temp: u128 = intervals_after_last_update.into();
        let cumulative_diff: Wad = (last_updated_cumulative_price - start_cumulative_price)
            + (intervals_after_last_update_temp * last_updated_price.val).into();
        let expected_avg_price: Wad = (cumulative_diff.val / (end_interval - start_interval).into())
            .into();

        let expected_avg_multiplier: Ray = RAY_SCALE.into();

        let expected_debt: Wad = compound_wrapper_for_yang(
            YANG1_BASE_RATE.into(),
            deployment_interval(),
            TROVE1_YANG1_DEPOSIT.into(),
            expected_avg_price,
            expected_avg_multiplier,
            start_interval,
            end_interval,
            debt,
        );

        (shrine, expected_debt)
    }

    #[test]
    #[available_gas(20000000000)]
    fn test_charge_scenario_4() {
        let (shrine, expected_debt) = setup_charge_scenario_4();

        shrine.forge(trove1_owner_addr(), TROVE_1, WadZeroable::zero());

        let (_, _, _, debt) = shrine.get_trove_info(TROVE_1);
        assert(expected_debt == debt, 'wrong compounded debt');

        assert(shrine.get_total_debt() == expected_debt, 'debt not updated');
    }
}

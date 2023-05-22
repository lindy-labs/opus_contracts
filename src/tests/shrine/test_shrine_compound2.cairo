#[cfg(test)]
mod TestShrineCompound2 {
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

    use aura::tests::shrine::shrine_utils::ShrineUtils;

    //
    // Tests - Trove estimate and charge
    // 

    // Wrapper to get around gas issue
    // Test for `charge` with "missed" price and multiplier updates from `intervals_after_last_update`
    // intervals after start interval onwards.
    // Start interval does not have a price or multiplier update.
    // End interval does not have a price or multiplier update.
    //
    // T+LAST_UPDATED_BEFORE_START       T+START----T+LAST_UPDATED_AFTER_START---------T+END
    #[test]
    #[available_gas(20000000000)]
    fn test_charge_scenario_5() {
        let shrine: IShrineDispatcher = ShrineUtils::shrine_setup_with_feed();
        let yang1_addr = ShrineUtils::yang1_addr();

        // Advance one interval to avoid overwriting the last price
        ShrineUtils::advance_interval();

        // Advance timestamp by given intervals and set last updated price - `T+LAST_UPDATED_BEFORE_START`
        let intervals_to_skip: u64 = 5;
        ShrineUtils::advance_prices_and_set_multiplier(
            shrine, intervals_to_skip, ShrineUtils::YANG1_START_PRICE.into(), ShrineUtils::YANG2_START_PRICE.into()
        );
        let last_updated_interval_before_start: u64 = ShrineUtils::current_interval();

        // Advance timestamp to `T+START`.
        let intervals_without_update_before_start: u64 = 10;
        let time_to_skip: u64 = intervals_without_update_before_start * Shrine::TIME_INTERVAL;
        let timestamp: u64 = get_block_timestamp() + time_to_skip;
        set_block_timestamp(timestamp);
        let start_interval: u64 = ShrineUtils::current_interval();

        ShrineUtils::trove1_deposit(shrine, ShrineUtils::TROVE1_YANG1_DEPOSIT.into());
        let forge_amt: Wad = ShrineUtils::TROVE1_FORGE_AMT.into();
        ShrineUtils::trove1_forge(shrine, forge_amt);

        let (_, _, _, debt) = shrine.get_trove_info(ShrineUtils::TROVE_1);

        // Advance timestamp to `T+LAST_UPDATED_AFTER_START` and set the price
        let intervals_to_last_update_after_start: u64 = 5;
        let time_to_skip: u64 = intervals_to_last_update_after_start * Shrine::TIME_INTERVAL;
        let timestamp: u64 = get_block_timestamp() + time_to_skip;
        set_block_timestamp(timestamp);
        let last_updated_interval_after_start: u64 = ShrineUtils::current_interval();

        let start_price: Wad = 2222000000000000000000_u128.into(); // 2_222 (Wad)
        let start_multiplier: Ray = RAY_SCALE.into();
        set_contract_address(ShrineUtils::admin());
        shrine.advance(yang1_addr, start_price);
        shrine.set_multiplier(start_multiplier);

        // Advance timestamp to `T+END`.
        let intervals_from_last_update_to_end: u64 = 10;
        let time_to_skip: u64 = intervals_from_last_update_to_end * Shrine::TIME_INTERVAL;
        let end_timestamp: u64 = get_block_timestamp() + time_to_skip;
        set_block_timestamp(end_timestamp);
        let end_interval: u64 = ShrineUtils::current_interval();

        shrine.withdraw(yang1_addr, ShrineUtils::TROVE_1, WadZeroable::zero());

        // Manually calculate the average since end interval does not have a cumulative value
        let (_, start_cumulative_price) = shrine.get_yang_price(yang1_addr, start_interval);

        // First, we get the cumulative price values available to us 
        // `T+LAST_UPDATED_AFTER_START` - `T+LAST_UPDATED_BEFORE_START`
        let (last_updated_price_before_start, last_updated_cumulative_price_before_start) = shrine
            .get_yang_price(yang1_addr, last_updated_interval_before_start);
        let (last_updated_price_after_start, last_updated_cumulative_price_after_start) = shrine
            .get_yang_price(yang1_addr, last_updated_interval_after_start);

        let mut cumulative_diff: Wad = last_updated_cumulative_price_after_start
            - last_updated_cumulative_price_before_start;

        // Next, we deduct the cumulative price from `T+LAST_UPDATED_BEFORE_START` to `T+START`

        cumulative_diff -=
            ((start_interval - last_updated_interval_before_start).into()
                * last_updated_price_before_start.val)
            .into();

        // Finally, we add the cumulative price from `T+LAST_UPDATED_AFTER_START` to `T+END`.
        cumulative_diff +=
            ((end_interval - last_updated_interval_after_start).into()
                * last_updated_price_after_start.val)
            .into();

        let expected_avg_price: Wad = (cumulative_diff.val / (end_interval - start_interval).into())
            .into();

        let expected_avg_multiplier: Ray = RAY_SCALE.into();

        let expected_debt: Wad = ShrineUtils::compound_wrapper_for_yang(
            ShrineUtils::YANG1_BASE_RATE.into(),
            ShrineUtils::deployment_interval(),
            ShrineUtils::TROVE1_YANG1_DEPOSIT.into(),
            expected_avg_price,
            expected_avg_multiplier,
            start_interval,
            end_interval,
            debt,
        );

        shrine.forge(ShrineUtils::trove1_owner_addr(), ShrineUtils::TROVE_1, WadZeroable::zero());

        assert(shrine.get_total_debt() == expected_debt, 'debt not updated');

        let (_, _, _, debt) = shrine.get_trove_info(ShrineUtils::TROVE_1);

        assert(expected_debt == debt, 'wrong compounded debt');
    }

    // Wrapper to get around gas issue
    // Test for `charge` with "missed" price and multiplier update at the start interval.
    // Start interval does not have a price or multiplier update.
    // End interval has both price and multiplier update.
    // 
    // T+LAST_UPDATED_BEFORE_START       T+START-------------T+END (with price update)
    //
    #[test]
    #[available_gas(20000000000)]
    fn setup_charge_scenario_6() {
        let shrine: IShrineDispatcher = ShrineUtils::shrine_setup_with_feed();
        let yang1_addr = ShrineUtils::yang1_addr();

        // Advance timestamp by given intervals and set last updated price - `T+LAST_UPDATED`
        let intervals_to_skip: u64 = 5;
        let time_to_skip: u64 = intervals_to_skip * Shrine::TIME_INTERVAL;
        let timestamp: u64 = get_block_timestamp() + time_to_skip;
        set_block_timestamp(timestamp);
        let last_updated_interval: u64 = ShrineUtils::current_interval();

        let start_price: Wad = 2222000000000000000000_u128.into(); // 2_222 (Wad)
        let start_multiplier: Ray = RAY_SCALE.into();
        set_contract_address(ShrineUtils::admin());
        shrine.advance(yang1_addr, start_price);
        shrine.set_multiplier(start_multiplier);

        // Advance timestamp by given intervals to `T+START` to mock missed updates.
        let intervals_after_last_update_to_start: u64 = 5;
        let time_to_skip: u64 = intervals_after_last_update_to_start * Shrine::TIME_INTERVAL;
        let timestamp: u64 = get_block_timestamp() + time_to_skip;
        set_block_timestamp(timestamp);
        let start_interval: u64 = ShrineUtils::current_interval();

        ShrineUtils::trove1_deposit(shrine, ShrineUtils::TROVE1_YANG1_DEPOSIT.into());
        let forge_amt: Wad = ShrineUtils::TROVE1_FORGE_AMT.into();
        ShrineUtils::trove1_forge(shrine, forge_amt);

        let (_, _, _, debt) = shrine.get_trove_info(ShrineUtils::TROVE_1);

        // Advance timestamp by given intervals to `T+END`, to mock missed updates.
        let intervals_from_start_to_end: u64 = 13;
        let time_to_skip: u64 = intervals_from_start_to_end * Shrine::TIME_INTERVAL;
        let timestamp: u64 = get_block_timestamp() + time_to_skip;
        set_block_timestamp(timestamp);
        let end_interval: u64 = ShrineUtils::current_interval();

        let end_price: Wad = 2333000000000000000000_u128.into(); // 2_333 (Wad)
        let start_multiplier: Ray = RAY_SCALE.into();
        shrine.advance(yang1_addr, start_price);
        shrine.set_multiplier(start_multiplier);

        shrine.withdraw(yang1_addr, ShrineUtils::TROVE_1, WadZeroable::zero());

        // Manually calculate the average since start interval does not have a cumulative value
        let (_, end_cumulative_price) = shrine.get_yang_price(yang1_addr, end_interval);
        let (last_updated_price, last_updated_cumulative_price) = shrine
            .get_yang_price(yang1_addr, last_updated_interval);

        let mut cumulative_diff: Wad = end_cumulative_price - last_updated_cumulative_price;

        // Deduct the cumulative price from `T+LAST_UPDATED_BEFORE_START` to `T+START`
        cumulative_diff -=
            ((start_interval - last_updated_interval).into() * last_updated_price.val)
            .into();

        let expected_avg_price: Wad = (cumulative_diff.val / (end_interval - start_interval).into())
            .into();
        let expected_avg_multiplier: Ray = RAY_SCALE.into();

        let expected_debt: Wad = ShrineUtils::compound_wrapper_for_yang(
            ShrineUtils::YANG1_BASE_RATE.into(),
            ShrineUtils::deployment_interval(),
            ShrineUtils::TROVE1_YANG1_DEPOSIT.into(),
            expected_avg_price,
            expected_avg_multiplier,
            start_interval,
            end_interval,
            debt,
        );

        shrine.melt(ShrineUtils::trove1_owner_addr(), ShrineUtils::TROVE_1, WadZeroable::zero());
        assert(shrine.get_total_debt() == expected_debt, 'debt not updated');

        let (_, _, _, debt) = shrine.get_trove_info(ShrineUtils::TROVE_1);
        assert(expected_debt == debt, 'wrong compounded debt');
    }
}

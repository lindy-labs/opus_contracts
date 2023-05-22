#[cfg(test)]
mod TestShrineCompound5 {
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
        let shrine: IShrineDispatcher = shrine_setup_with_feed();
        let yang1_addr = yang1_addr();
        set_contract_address(admin());

        // Advance timestamp by given intervals and set last updated price - `T+LAST_UPDATED`
        let intervals_to_skip: u64 = 5;
        let time_to_skip: u64 = intervals_to_skip * Shrine::TIME_INTERVAL;
        let timestamp: u64 = get_block_timestamp() + time_to_skip;
        set_block_timestamp(timestamp);
        let last_updated_interval: u64 = current_interval();

        let start_price: Wad = 2222000000000000000000_u128.into(); // 2_222 (Wad)
        let start_multiplier: Ray = RAY_SCALE.into();
        shrine.advance(yang1_addr, start_price);
        shrine.set_multiplier(start_multiplier);

        // Advance timestamp by given intervals to `T+START` to mock missed updates.
        let intervals_after_last_update_to_start: u64 = 5;
        let time_to_skip: u64 = intervals_after_last_update_to_start * Shrine::TIME_INTERVAL;
        let timestamp: u64 = get_block_timestamp() + time_to_skip;
        set_block_timestamp(timestamp);
        let start_interval: u64 = current_interval();

        trove1_deposit(shrine, TROVE1_YANG1_DEPOSIT.into());
        let forge_amt: Wad = TROVE1_FORGE_AMT.into();
        trove1_forge(shrine, forge_amt);

        let (_, _, _, debt) = shrine.get_trove_info(TROVE_1);

        // Advance timestamp by given intervals to `T+END`, to mock missed updates.
        let intervals_from_start_to_end: u64 = 13;
        let time_to_skip: u64 = intervals_from_start_to_end * Shrine::TIME_INTERVAL;
        let timestamp: u64 = get_block_timestamp() + time_to_skip;
        set_block_timestamp(timestamp);
        let end_interval: u64 = current_interval();

        let end_price: Wad = 2333000000000000000000_u128.into(); // 2_333 (Wad)
        let start_multiplier: Ray = RAY_SCALE.into();
        shrine.advance(yang1_addr, start_price);
        shrine.set_multiplier(start_multiplier);

        shrine.withdraw(yang1_addr, TROVE_1, WadZeroable::zero());

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

        shrine.melt(trove1_owner_addr(), TROVE_1, WadZeroable::zero());
        assert(shrine.get_total_debt() == expected_debt, 'debt not updated');

        let (_, _, _, debt) = shrine.get_trove_info(TROVE_1);
        assert(expected_debt == debt, 'wrong compounded debt');
    }
}

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

    use aura::tests::test_shrine::TestShrine::{admin, advance_interval, advance_prices_and_set_multiplier, compound_wrapper_for_yang, current_interval, FEED_LEN, deployment_interval, get_avg_multiplier, get_avg_yang_price, get_interval, shrine_setup_with_feed, TROVE_1, trove1_deposit, trove1_forge, TROVE1_FORGE_AMT, trove1_owner_addr, TROVE1_YANG1_DEPOSIT, yang1_addr, yang2_addr, YANG1_BASE_RATE, YANG1_START_PRICE, YANG2_START_PRICE};

    //
    // Tests - Trove estimate and charge
    // 

    // Wrapper to get around gas issue
    // Test for `charge` with "missed" price and multiplier updates after the start interval,
    // Start interval has a price and multiplier update.
    // End interval does not have a price or multiplier update.
    // 
    // T+START/LAST_UPDATED-------------T+END
    fn setup_charge_scenario_3() -> (IShrineDispatcher, Wad) {
        let shrine: IShrineDispatcher = shrine_setup_with_feed();

        // Advance one interval to avoid overwriting the last price
        advance_interval();

        trove1_deposit(shrine, TROVE1_YANG1_DEPOSIT.into());
        let forge_amt: Wad = TROVE1_FORGE_AMT.into();
        trove1_forge(shrine, forge_amt);

        let yang1_addr = yang1_addr();

        // Advance timestamp by 2 intervals and set price for interval - `T+LAST_UPDATED`
        let time_to_skip: u64 = 2 * Shrine::TIME_INTERVAL;
        let start_timestamp: u64 = get_block_timestamp() + time_to_skip;
        let start_interval: u64 = get_interval(start_timestamp);
        set_block_timestamp(start_timestamp);
        let start_price: Wad = 2222000000000000000000_u128.into(); // 2_222 (Wad)
        let start_multiplier: Ray = RAY_SCALE.into();
        set_contract_address(admin());
        shrine.advance(yang1_addr, start_price);
        shrine.set_multiplier(start_multiplier);

        shrine.deposit(yang1_addr, TROVE_1, WadZeroable::zero());

        // sanity check that some interest has accrued
        let (_, _, _, debt) = shrine.get_trove_info(TROVE_1);
        assert(debt > forge_amt, '!(starting debt > forged)');

        // Advance timestamp to `T+END`, to mock lack of price updates since `T+START/LAST_UPDATED`.
        // Trigger charge to update the trove's debt to `T+END`.
        let intervals_after_last_update: u64 = 17;
        let time_to_skip: u64 = intervals_after_last_update * Shrine::TIME_INTERVAL;
        let end_timestamp: u64 = start_timestamp + time_to_skip;

        // No need for offset here because we are incrementing the intervals directly
        // instead of via `advance_prices_and_set_multiplier`
        let end_interval: u64 = start_interval + intervals_after_last_update;
        set_block_timestamp(end_timestamp);

        shrine.withdraw(yang1_addr, TROVE_1, WadZeroable::zero());

        // As the price and multiplier have not been updated since `T+START/LAST_UPDATED`, we expect the 
        // average values to be that at `T+START/LAST_UPDATED`.
        let expected_debt: Wad = compound_wrapper_for_yang(
            YANG1_BASE_RATE.into(),
            deployment_interval(),
            TROVE1_YANG1_DEPOSIT.into(),
            start_price,
            start_multiplier,
            start_interval,
            end_interval,
            debt,
        );

        (shrine, expected_debt)
    }

    // Wrapper to get around gas issue
    // Test for `charge` with "missed" price and multiplier updates from `intervals_after_last_update` intervals
    // after start interval.
    // Start interval has a price and multiplier update.
    // End interval does not have a price or multiplier update.
    // 
    // T+START-------T+LAST_UPDATED------T+END
    #[test]
    #[available_gas(20000000000)]
    fn test_charge_scenario_3() {
        let (shrine, expected_debt) = setup_charge_scenario_3();

        shrine.melt(trove1_owner_addr(), TROVE_1, WadZeroable::zero());

        let (_, _, _, debt) = shrine.get_trove_info(TROVE_1);
        assert(expected_debt == debt, 'wrong compounded debt');

        assert(shrine.get_total_debt() == expected_debt, 'debt not updated');
    }

    
}

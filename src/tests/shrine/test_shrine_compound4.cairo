#[cfg(test)]
mod TestShrineCompound2 {
    use array::{ArrayTrait, SpanTrait};
    use option::OptionTrait;
    use traits::{Into, TryInto};
    use starknet::{ContractAddress, get_block_timestamp};
    use starknet::contract_address::ContractAddressZeroable;
    use starknet::testing::{set_block_timestamp, set_contract_address};

    use aura::core::shrine::Shrine;

    use aura::interfaces::IShrine::{IShrineDispatcher, IShrineDispatcherTrait};
    use aura::utils::exp::exp;
    use aura::utils::serde;
    use aura::utils::u256_conversions;
    use aura::utils::wadray;
    use aura::utils::wadray::{Ray, RayZeroable, RAY_SCALE, Wad, WadZeroable};

    use aura::tests::shrine::shrine_utils::ShrineUtils;

    //
    // Tests - Trove estimate and charge
    // 

    // Tests for `charge` with three base rate updates and 
    // two yangs deposited into the trove
    #[test]
    #[available_gas(20000000000)]
    fn test_charge_scenario_7() {
        let shrine: IShrineDispatcher = ShrineUtils::shrine_setup_with_feed();
        ShrineUtils::advance_prices_and_set_multiplier(
            shrine,
            ShrineUtils::FEED_LEN,
            ShrineUtils::YANG1_START_PRICE.into(),
            ShrineUtils::YANG2_START_PRICE.into()
        );

        let trove1_owner: ContractAddress = ShrineUtils::trove1_owner_addr();
        let yang1_addr: ContractAddress = ShrineUtils::yang1_addr();
        let yang2_addr: ContractAddress = ShrineUtils::yang2_addr();

        let mut yang_addrs: Array<ContractAddress> = ArrayTrait::new();
        yang_addrs.append(yang1_addr);
        yang_addrs.append(yang2_addr);

        // Setup base rates for calling `Shrine.update_rates`.
        // The base rates are set in the following format:
        //
        // O X O
        // X O X
        //
        // where X is the constant `USE_PREV_BASE_RATE` value that sets the base rate to the previous value.
        //
        // Note that the arrays are created as a list of yang base rate updates

        // `yang_base_rates_history_to_update` is used to perform the rate updates, while 
        // `yang_base_rates_history_to_compound` is used to perform calculation of the compounded interest
        // The main difference between the two arrays are:
        // (1) When setting a base rate to its previous value, the value to update in Shrine is `USE_PREV_BASE_RATE`
        //     which is equivalent to `RAY_SCALE + 1`, whereas the actual value that is used to calculate
        //     compound interest is the previous base rate.
        // (2) `yang_base_rates_history_to_compound` has an extra item for the initial base rates at the time
        //     the trove was last charged, in order to calculate the compound interest from this interval until
        //     the first rate update interval.
        let mut yang_base_rates_history_to_update: Array<Span<Ray>> = ArrayTrait::new();
        let mut yang_base_rates_history_to_compound: Array<Span<Ray>> = ArrayTrait::new();

        // Add initial base rates for rates history to calculate compound interest
        let mut initial_rate_history_to_compound: Array<Ray> = ArrayTrait::new();
        initial_rate_history_to_compound.append(ShrineUtils::YANG1_BASE_RATE.into());
        initial_rate_history_to_compound.append(ShrineUtils::YANG2_BASE_RATE.into());
        yang_base_rates_history_to_compound.append(initial_rate_history_to_compound.span());

        let mut first_rate_history_to_update: Array<Ray> = ArrayTrait::new();
        let mut first_rate_history_to_compound: Array<Ray> = ArrayTrait::new();

        // For first rate update, yang 1 is updated and yang 2 uses previous base rate
        let yang1_first_rate_update: Ray = 25000000000000000000000000_u128.into(); // 2.5% (Ray)
        first_rate_history_to_update.append(yang1_first_rate_update);
        first_rate_history_to_compound.append(yang1_first_rate_update);

        first_rate_history_to_update.append((RAY_SCALE + 1).into());
        first_rate_history_to_compound.append(ShrineUtils::YANG2_BASE_RATE.into());

        yang_base_rates_history_to_update.append(first_rate_history_to_update.span());
        yang_base_rates_history_to_compound.append(first_rate_history_to_compound.span());

        // For second rate update, yang 1 uses previous base rate and yang 2 is updated
        let mut second_rate_history_to_update: Array<Ray> = ArrayTrait::new();
        let mut second_rate_history_to_compound: Array<Ray> = ArrayTrait::new();

        second_rate_history_to_update.append((RAY_SCALE + 1).into());
        second_rate_history_to_compound.append(yang1_first_rate_update);

        let yang2_second_rate_update: Ray = 43500000000000000000000000_u128.into(); // 4.35% (Ray)
        second_rate_history_to_update.append(yang2_second_rate_update);
        second_rate_history_to_compound.append(yang2_second_rate_update);

        yang_base_rates_history_to_update.append(second_rate_history_to_update.span());
        yang_base_rates_history_to_compound.append(second_rate_history_to_compound.span());

        // For third rate update, yang 1 is updated and yang 2 uses previous base rate
        let mut third_rate_history_to_update: Array<Ray> = ArrayTrait::new();
        let mut third_rate_history_to_compound: Array<Ray> = ArrayTrait::new();

        let yang1_third_rate_update: Ray = 27500000000000000000000000_u128.into(); // 2.75% (Ray)
        third_rate_history_to_update.append(yang1_third_rate_update);
        third_rate_history_to_compound.append(yang1_third_rate_update);

        third_rate_history_to_update.append((RAY_SCALE + 1).into());
        third_rate_history_to_compound.append(yang2_second_rate_update);

        yang_base_rates_history_to_update.append(third_rate_history_to_update.span());
        yang_base_rates_history_to_compound.append(third_rate_history_to_compound.span());

        // The number of base rate updates
        let num_base_rate_updates: u64 = 3;

        // The number of intervals actually between two base rate updates will be this number minus one
        let BASE_RATE_UPDATE_SPACING: u64 = 5;

        // The number of time periods where the base rates remain constant.
        // We add one because there is also the time period between
        // the base rates set in `add_yang` and the first base rate update
        let num_eras: u64 = num_base_rate_updates + 1;
        let current_timestamp: u64 = get_block_timestamp();
        let start_interval: u64 = ShrineUtils::current_interval();
        let end_interval: u64 = start_interval + BASE_RATE_UPDATE_SPACING * num_eras;
        let charging_period: u64 = end_interval - start_interval;

        // Generating the list of intervals at which the base rates will be updated (needed for `compound`)
        // Adding zero as the first interval since that's when the base rates were first added in `add_yang`
        let mut rate_update_intervals: Array<u64> = ArrayTrait::new();
        rate_update_intervals.append(0);
        let mut i = 0;
        loop {
            if i == num_base_rate_updates {
                break ();
            }
            let rate_update_interval: u64 = start_interval + (i + 1) * BASE_RATE_UPDATE_SPACING;
            rate_update_intervals.append(rate_update_interval);
            i += 1;
        };

        let mut avg_multipliers: Array<Ray> = ArrayTrait::new();

        let mut avg_yang_prices_by_era: Array<Span<Wad>> = ArrayTrait::new();

        // Deposit yangs into trove and forge debt
        set_contract_address(ShrineUtils::admin());
        let yang1_deposit_amt: Wad = ShrineUtils::TROVE1_YANG1_DEPOSIT.into();
        shrine.deposit(yang1_addr, ShrineUtils::TROVE_1, yang1_deposit_amt);
        let yang2_deposit_amt: Wad = ShrineUtils::TROVE1_YANG2_DEPOSIT.into();
        shrine.deposit(yang2_addr, ShrineUtils::TROVE_1, yang2_deposit_amt);
        let forge_amt: Wad = ShrineUtils::TROVE1_FORGE_AMT.into();
        shrine.forge(trove1_owner, ShrineUtils::TROVE_1, forge_amt);

        let mut yangs_deposited: Array<Wad> = ArrayTrait::new();
        yangs_deposited.append(yang1_deposit_amt);
        yangs_deposited.append(yang2_deposit_amt);

        let mut yang_base_rates_history_copy: Span<Span<Ray>> = yang_base_rates_history_to_update
            .span();
        let mut yang_base_rates_history_to_compound_copy: Span<Span<Ray>> =
            yang_base_rates_history_to_compound
            .span();

        let mut i = 0;
        let mut era_start_interval: u64 = start_interval;
        loop {
            // We perform an extra iteration here to test the last rate era by advancing the prices.
            // Otherwise, if the last interval is also the start of a new rate era, we would not be able to test it.
            if i == num_base_rate_updates + 1 {
                break ();
            }

            // Fetch the latest yang prices
            let (yang1_price, _, _) = shrine.get_current_yang_price(yang1_addr);
            let (yang2_price, _, _) = shrine.get_current_yang_price(yang2_addr);

            // First, we advance an interval so the last price is not overwritten.
            // Next, Advance the prices by the number of intervals between each base rate update
            ShrineUtils::advance_interval();
            ShrineUtils::advance_prices_and_set_multiplier(
                shrine, BASE_RATE_UPDATE_SPACING, yang1_price, yang2_price
            );

            let era_end_interval: u64 = era_start_interval + BASE_RATE_UPDATE_SPACING;

            // Calculate average price of yangs over the era for calculating the compounded interest
            let mut avg_yang_prices_for_era: Array<Wad> = ArrayTrait::new();
            let yang1_avg_price: Wad = ShrineUtils::get_avg_yang_price(
                shrine, yang1_addr, era_start_interval, era_end_interval
            );
            avg_yang_prices_for_era.append(yang1_avg_price);

            let yang2_avg_price: Wad = ShrineUtils::get_avg_yang_price(
                shrine, yang2_addr, era_start_interval, era_end_interval
            );
            avg_yang_prices_for_era.append(yang2_avg_price);

            avg_yang_prices_by_era.append(avg_yang_prices_for_era.span());

            // Append multiplier
            avg_multipliers.append(RAY_SCALE.into());

            if i < num_base_rate_updates {
                // Update base rates
                let mut yang_base_rates_to_update: Span<Ray> = yang_base_rates_history_to_update
                    .pop_front()
                    .unwrap();
                shrine.update_rates(yang_addrs.span(), yang_base_rates_to_update);

                // Check that base rates are updated correctly
                let mut yang_addrs_copy: Span<ContractAddress> = yang_addrs.span();
                // Offset by 1 to discount the initial 
                let era: u32 = i.try_into().unwrap() + 1;
                let mut expected_base_rates: Span<Ray> = *yang_base_rates_history_to_compound_copy
                    .at(era);
                loop {
                    match yang_addrs_copy.pop_front() {
                        Option::Some(yang_addr) => {
                            let era: u64 = i + 1;
                            let rate: Ray = shrine.get_yang_rate(*yang_addr, era);
                            let expected_rate: Ray = *expected_base_rates.pop_front().unwrap();
                            assert(rate == expected_rate, 'wrong base rate');
                        },
                        Option::None(_) => {
                            break ();
                        },
                    };
                };
            }

            // Increment counter
            i += 1;

            // Update start interval for next era
            era_start_interval = era_end_interval;
        };

        let (_, _, _, debt) = shrine.get_trove_info(ShrineUtils::TROVE_1);

        let expected_debt: Wad = ShrineUtils::compound(
            yang_base_rates_history_to_compound.span(),
            rate_update_intervals.span(),
            yangs_deposited.span(),
            avg_yang_prices_by_era.span(),
            avg_multipliers.span(),
            start_interval,
            end_interval,
            forge_amt,
        );

        assert(debt == expected_debt, 'wrong compounded debt');

        shrine.withdraw(yang1_addr, ShrineUtils::TROVE_1, WadZeroable::zero());
        assert(shrine.get_total_debt() == expected_debt, 'debt not updated');
    }
}

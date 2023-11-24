mod test_flash_mint {
    use debug::PrintTrait;
    use opus::core::flash_mint::flash_mint as flash_mint_contract;
    use opus::core::shrine::shrine as shrine_contract;
    use opus::interfaces::IERC20::{IERC20Dispatcher, IERC20DispatcherTrait};
    use opus::interfaces::IEqualizer::{IEqualizerDispatcher, IEqualizerDispatcherTrait};
    use opus::interfaces::IFlashBorrower::{IFlashBorrowerDispatcher, IFlashBorrowerDispatcherTrait};
    use opus::interfaces::IFlashMint::{IFlashMintDispatcher, IFlashMintDispatcherTrait};
    use opus::interfaces::IShrine::{IShrineDispatcher, IShrineDispatcherTrait};
    use opus::tests::common;
    use opus::tests::equalizer::utils::equalizer_utils;
    use opus::tests::flash_mint::flash_borrower::flash_borrower as flash_borrower_contract;
    use opus::tests::flash_mint::utils::flash_mint_utils;
    use opus::tests::shrine::utils::shrine_utils;
    use opus::utils::wadray::{Wad, WadZeroable, WAD_ONE};
    use opus::utils::wadray;
    use starknet::ContractAddress;
    use starknet::testing::set_contract_address;

    //
    // Tests
    //

    #[test]
    #[available_gas(20000000000)]
    fn test_flashmint_max_loan() {
        let (shrine, flashmint) = flash_mint_utils::flashmint_setup();

        // Check that max loan is correct
        let max_loan: u256 = flashmint.max_flash_loan(shrine);
        let expected_max_loan: u256 = (flash_mint_utils::YIN_TOTAL_SUPPLY.into()
            * shrine_utils::shrine(shrine).get_max_flash_mint_pct())
            .into();
        assert(max_loan == expected_max_loan, 'Incorrect max flash loan');
    }

    #[test]
    #[available_gas(20000000000)]
    fn test_flashmint_debt_ceiling_exceeded_max_loan() {
        let (shrine, equalizer, allocator) = equalizer_utils::equalizer_deploy();
        let flashmint = flash_mint_utils::flashmint_deploy(shrine.contract_address);

        let debt_ceiling: Wad = shrine.get_debt_ceiling();

        // deposit 1000 ETH and forge the debt ceiling
        shrine_utils::trove1_deposit(shrine, (1000 * WAD_ONE).into());
        shrine_utils::trove1_forge(shrine, debt_ceiling);
        let eth: ContractAddress = shrine_utils::yang1_addr();
        let (eth_price, _, _) = shrine.get_current_yang_price(eth);

        // accrue interest to exceed the debt ceiling
        common::advance_intervals(1000);

        // update price to speed up calculation
        set_contract_address(shrine_utils::admin());
        shrine.advance(eth, eth_price);

        shrine_utils::trove1_deposit(shrine, WadZeroable::zero());

        let surplus: Wad = equalizer.equalize();
        assert(surplus.is_non_zero(), 'no surplus');
        let total_yin: Wad = shrine.get_total_yin();
        assert(total_yin > debt_ceiling, 'below debt ceiling');

        // Check that max loan is correct
        let max_loan: u256 = flashmint.max_flash_loan(shrine.contract_address);
        let expected_max_loan: u256 = (total_yin * shrine.get_max_flash_mint_pct()).into();
        assert(max_loan == expected_max_loan, 'Incorrect max flash loan');
    }

    #[test]
    #[available_gas(20000000000)]
    fn test_flash_fee() {
        let shrine: ContractAddress = shrine_utils::shrine_deploy(Option::None);
        let flashmint: IFlashMintDispatcher = flash_mint_utils::flashmint_deploy(shrine);

        // Check that flash fee is correct
        assert(flashmint.flash_fee(shrine, 0xdeadbeefdead_u256).is_zero(), 'Incorrect flash fee');
    }

    #[test]
    #[available_gas(20000000000)]
    fn test_flashmint_pass() {
        let (shrine, flashmint, borrower) = flash_mint_utils::flash_borrower_setup();
        let yin = shrine_utils::yin(shrine);

        let mut calldata: Span<felt252> = flash_mint_utils::build_calldata(
            true, flash_borrower_contract::VALID_USAGE
        );

        // `borrower` contains a check that ensures that `flashmint` actually transferred
        // the full flash_loan amount
        let flash_mint_caller: ContractAddress = common::non_zero_address();
        set_contract_address(flash_mint_caller);

        let first_loan_amt: u256 = 1;
        flashmint.flash_loan(borrower, shrine, first_loan_amt, calldata);
        assert(yin.balance_of(borrower).is_zero(), 'Wrong yin bal after flashmint 1');

        set_contract_address(flash_mint_caller);
        let second_loan_amt: u256 = flash_mint_utils::DEFAULT_MINT_AMOUNT;
        flashmint.flash_loan(borrower, shrine, second_loan_amt, calldata);
        assert(yin.balance_of(borrower).is_zero(), 'Wrong yin bal after flashmint 2');

        set_contract_address(flash_mint_caller);
        let third_loan_amt: u256 = (1000 * WAD_ONE).into();
        flashmint.flash_loan(borrower, shrine, third_loan_amt, calldata);
        assert(yin.balance_of(borrower).is_zero(), 'Wrong yin bal after flashmint 3');

        // check that flash loan still functions normally when yin supply is at debt ceiling
        set_contract_address(shrine_utils::admin());
        let debt_ceiling: Wad = shrine_utils::shrine(shrine).get_debt_ceiling();
        let debt_to_ceiling: Wad = debt_ceiling - shrine_utils::shrine(shrine).get_total_yin();
        shrine_utils::shrine(shrine).inject(common::non_zero_address(), debt_to_ceiling);

        set_contract_address(flash_mint_caller);
        let fourth_loan_amt: u256 = (debt_ceiling
            * shrine_contract::INITIAL_MAX_FLASH_MINT_AMOUNT_PCT.into())
            .into();
        flashmint.flash_loan(borrower, shrine, third_loan_amt, calldata);
        assert(yin.balance_of(borrower).is_zero(), 'Wrong yin bal after flashmint 4');

        let mut expected_events: Span<flash_mint_contract::Event> = array![
            flash_mint_contract::Event::FlashMint(
                flash_mint_contract::FlashMint {
                    initiator: flash_mint_caller,
                    receiver: borrower,
                    token: shrine,
                    amount: first_loan_amt
                }
            ),
            flash_mint_contract::Event::FlashMint(
                flash_mint_contract::FlashMint {
                    initiator: flash_mint_caller,
                    receiver: borrower,
                    token: shrine,
                    amount: second_loan_amt
                }
            ),
            flash_mint_contract::Event::FlashMint(
                flash_mint_contract::FlashMint {
                    initiator: flash_mint_caller,
                    receiver: borrower,
                    token: shrine,
                    amount: third_loan_amt
                }
            ),
            flash_mint_contract::Event::FlashMint(
                flash_mint_contract::FlashMint {
                    initiator: flash_mint_caller,
                    receiver: borrower,
                    token: shrine,
                    amount: fourth_loan_amt
                }
            ),
        ]
            .span();
        common::assert_events_emitted(flashmint.contract_address, expected_events, Option::None);

        let mut expected_events: Span<flash_borrower_contract::Event> = array![
            flash_borrower_contract::Event::FlashLoancall_dataReceived(
                flash_borrower_contract::FlashLoancall_dataReceived {
                    initiator: flash_mint_caller,
                    token: shrine,
                    amount: first_loan_amt,
                    fee: 0,
                    call_data: calldata,
                }
            ),
            flash_borrower_contract::Event::FlashLoancall_dataReceived(
                flash_borrower_contract::FlashLoancall_dataReceived {
                    initiator: flash_mint_caller,
                    token: shrine,
                    amount: second_loan_amt,
                    fee: 0,
                    call_data: calldata,
                }
            ),
            flash_borrower_contract::Event::FlashLoancall_dataReceived(
                flash_borrower_contract::FlashLoancall_dataReceived {
                    initiator: flash_mint_caller,
                    token: shrine,
                    amount: third_loan_amt,
                    fee: 0,
                    call_data: calldata,
                }
            ),
            flash_borrower_contract::Event::FlashLoancall_dataReceived(
                flash_borrower_contract::FlashLoancall_dataReceived {
                    initiator: flash_mint_caller,
                    token: shrine,
                    amount: fourth_loan_amt,
                    fee: 0,
                    call_data: calldata,
                }
            ),
        ]
            .span();
        common::assert_events_emitted(borrower, expected_events, Option::None);
    }

    #[test]
    #[available_gas(20000000000)]
    #[should_panic(expected: ('FM: amount exceeds maximum', 'ENTRYPOINT_FAILED'))]
    fn test_flashmint_excess_minting() {
        let (shrine, flashmint, borrower) = flash_mint_utils::flash_borrower_setup();
        flashmint
            .flash_loan(
                borrower,
                shrine,
                1000000000000000000001_u256,
                flash_mint_utils::build_calldata(true, flash_borrower_contract::VALID_USAGE)
            );
    }

    #[test]
    #[available_gas(20000000000)]
    #[should_panic(expected: ('FM: on_flash_loan failed', 'ENTRYPOINT_FAILED'))]
    fn test_flashmint_incorrect_return() {
        let (shrine, flashmint, borrower) = flash_mint_utils::flash_borrower_setup();
        flashmint
            .flash_loan(
                borrower,
                shrine,
                flash_mint_utils::DEFAULT_MINT_AMOUNT,
                flash_mint_utils::build_calldata(false, flash_borrower_contract::VALID_USAGE)
            );
    }

    #[test]
    #[available_gas(20000000000)]
    #[should_panic(
        expected: ('SH: Insufficient yin balance', 'ENTRYPOINT_FAILED', 'ENTRYPOINT_FAILED')
    )]
    fn test_flashmint_steal() {
        let (shrine, flashmint, borrower) = flash_mint_utils::flash_borrower_setup();
        flashmint
            .flash_loan(
                borrower,
                shrine,
                flash_mint_utils::DEFAULT_MINT_AMOUNT,
                flash_mint_utils::build_calldata(true, flash_borrower_contract::ATTEMPT_TO_STEAL)
            );
    }

    #[test]
    #[available_gas(20000000000)]
    #[should_panic(
        expected: (
            'RG: reentrant call', 'ENTRYPOINT_FAILED', 'ENTRYPOINT_FAILED', 'ENTRYPOINT_FAILED'
        )
    )]
    fn test_flashmint_reenter() {
        let (shrine, flashmint, borrower) = flash_mint_utils::flash_borrower_setup();
        flashmint
            .flash_loan(
                borrower,
                shrine,
                flash_mint_utils::DEFAULT_MINT_AMOUNT,
                flash_mint_utils::build_calldata(true, flash_borrower_contract::ATTEMPT_TO_REENTER)
            );
    }
}

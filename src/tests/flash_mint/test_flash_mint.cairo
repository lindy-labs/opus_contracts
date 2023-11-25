mod test_flash_mint {
    use opus::core::flash_mint::flash_mint as flash_mint_contract;
    use opus::interfaces::IERC20::{IERC20Dispatcher, IERC20DispatcherTrait};
    use opus::interfaces::IFlashBorrower::{IFlashBorrowerDispatcher, IFlashBorrowerDispatcherTrait};
    use opus::interfaces::IFlashMint::{IFlashMintDispatcher, IFlashMintDispatcherTrait};
    use opus::interfaces::IShrine::{IShrineDispatcher, IShrineDispatcherTrait};
    use opus::tests::common;
    use opus::tests::flash_mint::flash_borrower::flash_borrower as flash_borrower_contract;
    use opus::tests::flash_mint::utils::flash_mint_utils;
    use opus::tests::shrine::utils::shrine_utils;
    use opus::utils::wadray::{Wad, WAD_ONE};
    use opus::utils::wadray;

    use snforge_std::{start_prank, CheatTarget};
    use starknet::ContractAddress;

    //
    // Tests
    //

    #[test]
    fn test_flashmint_max_loan() {
        let (shrine, flashmint) = flash_mint_utils::flashmint_setup();

        // Check that max loan is correct
        let max_loan: u256 = flashmint.max_flash_loan(shrine);
        let expected_max_loan: u256 = (Wad { val: flash_mint_utils::YIN_TOTAL_SUPPLY }
            * Wad { val: flash_mint_contract::FLASH_MINT_AMOUNT_PCT })
            .into();
        assert(max_loan == expected_max_loan, 'Incorrect max flash loan');
    }

    #[test]
    fn test_flash_fee() {
        let shrine: ContractAddress = shrine_utils::shrine_deploy(Option::None);
        let flashmint: IFlashMintDispatcher = flash_mint_utils::flashmint_deploy(shrine);

        // Check that flash fee is correct
        assert(flashmint.flash_fee(shrine, 0xdeadbeefdead_u256).is_zero(), 'Incorrect flash fee');
    }

    #[test]
    fn test_flashmint_pass() {
        let (shrine, flashmint, borrower) = flash_mint_utils::flash_borrower_setup();
        let yin = shrine_utils::yin(shrine);

        let mut calldata: Span<felt252> = flash_mint_utils::build_calldata(
            true, flash_borrower_contract::VALID_USAGE
        );

        // `borrower` contains a check that ensures that `flashmint` actually transferred
        // the full flash_loan amount
        let flash_mint_caller: ContractAddress = common::non_zero_address();
        start_prank(CheatTarget::All, flash_mint_caller);

        let first_loan_amt: u256 = 1;
        flashmint.flash_loan(borrower, shrine, first_loan_amt, calldata);
        assert(yin.balance_of(borrower).is_zero(), 'Wrong yin bal after flashmint 1');

        start_prank(CheatTarget::All, flash_mint_caller);
        let second_loan_amt: u256 = flash_mint_utils::DEFAULT_MINT_AMOUNT;
        flashmint.flash_loan(borrower, shrine, second_loan_amt, calldata);
        assert(yin.balance_of(borrower).is_zero(), 'Wrong yin bal after flashmint 2');

        start_prank(CheatTarget::All, flash_mint_caller);
        let third_loan_amt: u256 = (1000 * WAD_ONE).into();
        flashmint.flash_loan(borrower, shrine, third_loan_amt, calldata);
        assert(yin.balance_of(borrower).is_zero(), 'Wrong yin bal after flashmint 3');

        // check that flash loan still functions normally when yin supply is at debt ceiling
        start_prank(CheatTarget::All, shrine_utils::admin());
        let debt_ceiling: Wad = shrine_utils::shrine(shrine).get_debt_ceiling();
        let debt_to_ceiling: Wad = debt_ceiling - shrine_utils::shrine(shrine).get_total_yin();
        shrine_utils::shrine(shrine).inject(common::non_zero_address(), debt_to_ceiling);

        start_prank(CheatTarget::All, flash_mint_caller);
        let fourth_loan_amt: u256 = (debt_ceiling
            * flash_mint_contract::FLASH_MINT_AMOUNT_PCT.into())
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

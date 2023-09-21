mod TestFlashmint {
    use starknet::ContractAddress;

    use aura::core::flashmint::FlashMint;

    use aura::interfaces::IERC20::{IERC20Dispatcher, IERC20DispatcherTrait};
    use aura::interfaces::IFlashBorrower::{IFlashBorrowerDispatcher, IFlashBorrowerDispatcherTrait};
    use aura::interfaces::IFlashMint::{IFlashMintDispatcher, IFlashMintDispatcherTrait};
    use aura::interfaces::IShrine::{IShrineDispatcher, IShrineDispatcherTrait};
    use aura::utils::wadray;
    use aura::utils::wadray::{Wad, WAD_ONE};

    use aura::tests::flashmint::flash_borrower::FlashBorrower;
    use aura::tests::flashmint::utils::FlashmintUtils;
    use aura::tests::shrine::utils::ShrineUtils;

    //
    // Tests
    //

    #[test]
    #[available_gas(20000000000)]
    fn test_flashmint_max_loan() {
        let (shrine, flashmint) = FlashmintUtils::flashmint_setup();

        // Check that max loan is correct
        let max_loan: u256 = flashmint.max_flash_loan(shrine);
        let expected_max_loan: u256 = (Wad { val: FlashmintUtils::YIN_TOTAL_SUPPLY }
            * Wad { val: FlashMint::FLASH_MINT_AMOUNT_PCT })
            .into();
        assert(max_loan == expected_max_loan, 'Incorrect max flash loan');
    }

    #[test]
    #[available_gas(20000000000)]
    fn test_flash_fee() {
        let shrine: ContractAddress = ShrineUtils::shrine_deploy();
        let flashmint: IFlashMintDispatcher = FlashmintUtils::flashmint_deploy(shrine);

        // Check that flash fee is correct
        assert(flashmint.flash_fee(shrine, 0xdeadbeefdead_u256).is_zero(), 'Incorrect flash fee');
    }

    #[test]
    #[available_gas(20000000000)]
    fn test_flashmint_pass() {
        let (shrine, flashmint, borrower) = FlashmintUtils::flash_borrower_setup();
        let yin = ShrineUtils::yin(shrine);

        let mut calldata: Span<felt252> = FlashmintUtils::build_calldata(
            true, FlashBorrower::VALID_USAGE
        );

        // `borrower` contains a check that ensures that `flashmint` actually transferred
        // the full flash_loan amount
        flashmint.flash_loan(borrower, shrine, 1_u128.into(), calldata);
        assert(yin.balance_of(borrower).is_zero(), 'Wrong yin bal after flashmint 1');
        flashmint.flash_loan(borrower, shrine, FlashmintUtils::DEFAULT_MINT_AMOUNT, calldata);
        assert(yin.balance_of(borrower).is_zero(), 'Wrong yin bal after flashmint 2');
        flashmint.flash_loan(borrower, shrine, (1000 * WAD_ONE).into(), calldata);
        assert(yin.balance_of(borrower).is_zero(), 'Wrong yin bal after flashmint 3');
    // TODO: check event emissions for correct calldata
    }

    #[test]
    #[available_gas(20000000000)]
    #[should_panic(expected: ('FM: amount exceeds maximum', 'ENTRYPOINT_FAILED'))]
    fn test_flashmint_excess_minting() {
        let (shrine, flashmint, borrower) = FlashmintUtils::flash_borrower_setup();
        flashmint
            .flash_loan(
                borrower,
                shrine,
                1000000000000000000001_u256,
                FlashmintUtils::build_calldata(true, FlashBorrower::VALID_USAGE)
            );
    }

    #[test]
    #[available_gas(20000000000)]
    #[should_panic(expected: ('FM: on_flash_loan failed', 'ENTRYPOINT_FAILED'))]
    fn test_flashmint_incorrect_return() {
        let (shrine, flashmint, borrower) = FlashmintUtils::flash_borrower_setup();
        flashmint
            .flash_loan(
                borrower,
                shrine,
                FlashmintUtils::DEFAULT_MINT_AMOUNT,
                FlashmintUtils::build_calldata(false, FlashBorrower::VALID_USAGE)
            );
    }

    #[test]
    #[available_gas(20000000000)]
    #[should_panic(expected: ('u128_sub Overflow', 'ENTRYPOINT_FAILED', 'ENTRYPOINT_FAILED'))]
    fn test_flashmint_steal() {
        let (shrine, flashmint, borrower) = FlashmintUtils::flash_borrower_setup();
        flashmint
            .flash_loan(
                borrower,
                shrine,
                FlashmintUtils::DEFAULT_MINT_AMOUNT,
                FlashmintUtils::build_calldata(true, FlashBorrower::ATTEMPT_TO_STEAL)
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
        let (shrine, flashmint, borrower) = FlashmintUtils::flash_borrower_setup();
        flashmint
            .flash_loan(
                borrower,
                shrine,
                FlashmintUtils::DEFAULT_MINT_AMOUNT,
                FlashmintUtils::build_calldata(true, FlashBorrower::ATTEMPT_TO_REENTER)
            );
    }
}

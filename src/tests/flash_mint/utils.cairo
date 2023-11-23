mod flash_mint_utils {
    use opus::core::flash_mint::flash_mint as flash_mint_contract;
    use opus::core::roles::shrine_roles;
    use opus::interfaces::IFlashMint::{IFlashMintDispatcher, IFlashMintDispatcherTrait};
    use opus::interfaces::IShrine::{IShrineDispatcher, IShrineDispatcherTrait};
    use opus::tests::flash_mint::flash_borrower::flash_borrower as flash_borrower_contract;
    use opus::tests::shrine::utils::shrine_utils;
    use opus::utils::access_control::{IAccessControlDispatcher, IAccessControlDispatcherTrait};
    use opus::utils::wadray::{Wad, WAD_ONE};
    use opus::utils::wadray;
    use starknet::contract_address::ContractAddressZeroable;
    use starknet::testing::set_contract_address;
    use starknet::{
        deploy_syscall, ClassHash, class_hash_try_from_felt252, ContractAddress,
        contract_address_to_felt252, SyscallResultTrait
    };

    const YIN_TOTAL_SUPPLY: u128 = 20000000000000000000000; // 20000 * WAD_ONE
    const DEFAULT_MINT_AMOUNT: u256 = 500000000000000000000; // 500 * WAD_ONE

    // Helper function to build a calldata Span for `FlashMint.flash_loan`
    #[inline(always)]
    fn build_calldata(should_return_correct: bool, usage: felt252) -> Span<felt252> {
        array![should_return_correct.into(), usage].span()
    }

    fn flashmint_deploy(shrine: ContractAddress) -> IFlashMintDispatcher {
        let mut calldata = array![contract_address_to_felt252(shrine)];

        let flashmint_class_hash: ClassHash = class_hash_try_from_felt252(
            flash_mint_contract::TEST_CLASS_HASH
        )
            .unwrap();
        let (flashmint_addr, _) = deploy_syscall(flashmint_class_hash, 0, calldata.span(), false)
            .unwrap_syscall();
        let flashmint = IFlashMintDispatcher { contract_address: flashmint_addr };

        // Grant flashmint contract the FLASHMINT role
        set_contract_address(shrine_utils::admin());
        let shrine_accesscontrol = IAccessControlDispatcher { contract_address: shrine };
        shrine_accesscontrol.grant_role(shrine_roles::flash_mint(), flashmint_addr);

        flashmint
    }

    fn flashmint_setup() -> (ContractAddress, IFlashMintDispatcher) {
        let shrine: ContractAddress = shrine_utils::shrine_deploy(Option::None);
        let flashmint: IFlashMintDispatcher = flashmint_deploy(shrine);

        let shrine_dispatcher = IShrineDispatcher { contract_address: shrine };

        shrine_utils::shrine_setup(shrine);
        shrine_utils::advance_prices_and_set_multiplier(
            shrine_dispatcher,
            3,
            shrine_utils::three_yang_addrs(),
            array![(1000 * WAD_ONE).into(), (10000 * WAD_ONE).into(), (500 * WAD_ONE).into()]
                .span(),
        );

        // Mint some yin in shrine
        set_contract_address(shrine_utils::admin());
        shrine_dispatcher.inject(ContractAddressZeroable::zero(), YIN_TOTAL_SUPPLY.into());
        (shrine, flashmint)
    }

    fn flash_borrower_deploy(flashmint: ContractAddress) -> ContractAddress {
        let mut calldata = array![contract_address_to_felt252(flashmint)];

        let flash_borrower_class_hash: ClassHash = class_hash_try_from_felt252(
            flash_borrower_contract::TEST_CLASS_HASH
        )
            .unwrap();
        let (flash_borrower_addr, _) = deploy_syscall(
            flash_borrower_class_hash, 0, calldata.span(), false
        )
            .unwrap_syscall();
        flash_borrower_addr
    }

    fn flash_borrower_setup() -> (ContractAddress, IFlashMintDispatcher, ContractAddress) {
        let (shrine, flashmint) = flashmint_setup();
        (shrine, flashmint, flash_borrower_deploy(flashmint.contract_address))
    }
}

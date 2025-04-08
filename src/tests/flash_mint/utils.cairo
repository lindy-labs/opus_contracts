pub mod flash_mint_utils {
    use access_control::{IAccessControlDispatcher, IAccessControlDispatcherTrait};
    use core::num::traits::Zero;
    use opus::core::roles::shrine_roles;
    use opus::interfaces::IFlashMint::{IFlashMintDispatcher, IFlashMintDispatcherTrait};
    use opus::interfaces::IShrine::{IShrineDispatcher, IShrineDispatcherTrait};
    use opus::mock::flash_borrower::flash_borrower as flash_borrower_contract;
    use opus::tests::shrine::utils::shrine_utils;
    use snforge_std::{declare, ContractClassTrait, start_prank, stop_prank, CheatTarget};
    use starknet::{ContractAddress, SyscallResultTrait};
    use wadray::{Wad, WAD_ONE};

    pub const YIN_TOTAL_SUPPLY: u128 = 20000000000000000000000; // 20000 * WAD_ONE
    pub const DEFAULT_MINT_AMOUNT: u256 = 500000000000000000000; // 500 * WAD_ONE

    // Helper function to build a calldata Span for `FlashMint.flash_loan`
    #[inline(always)]
    pub fn build_calldata(should_return_correct: bool, usage: felt252) -> Span<felt252> {
        array![should_return_correct.into(), usage].span()
    }

    pub fn flashmint_deploy(shrine: ContractAddress) -> IFlashMintDispatcher {
        let flashmint_class = declare("flash_mint").unwrap().contract_class();
        let (flashmint_addr, _) = flashmint_class.deploy(@array![shrine.into()]).expect('flashmint deploy failed');

        let flashmint = IFlashMintDispatcher { contract_address: flashmint_addr };

        // Grant flashmint contract the FLASHMINT role
        start_prank(CheatTarget::One(shrine), shrine_utils::admin());
        let shrine_accesscontrol = IAccessControlDispatcher { contract_address: shrine };
        shrine_accesscontrol.grant_role(shrine_roles::flash_mint(), flashmint_addr);
        stop_prank(CheatTarget::One(shrine));
        flashmint
    }

    pub fn flashmint_setup() -> (ContractAddress, IFlashMintDispatcher) {
        let shrine: ContractAddress = shrine_utils::shrine_deploy(Option::None);
        let flashmint: IFlashMintDispatcher = flashmint_deploy(shrine);

        let shrine_dispatcher = IShrineDispatcher { contract_address: shrine };

        shrine_utils::shrine_setup(shrine);
        shrine_utils::advance_prices_and_set_multiplier(
            shrine_dispatcher,
            3,
            shrine_utils::three_yang_addrs(),
            array![(1000 * WAD_ONE).into(), (10000 * WAD_ONE).into(), (500 * WAD_ONE).into()].span(),
        );

        // Mint some yin in shrine
        start_prank(CheatTarget::All, shrine_utils::admin());
        shrine_dispatcher.inject(Zero::zero(), YIN_TOTAL_SUPPLY.into());
        (shrine, flashmint)
    }

    pub fn flash_borrower_deploy(flashmint: ContractAddress) -> ContractAddress {
        let flash_borrower_class = declare("flash_borrower").unwrap().contract_class();
        let (flash_borrower_addr, _) = flash_borrower_class
            .deploy(@array![flashmint.into()])
            .expect('flsh brrwr deploy failed');
        flash_borrower_addr
    }

    pub fn flash_borrower_setup() -> (ContractAddress, IFlashMintDispatcher, ContractAddress) {
        let (shrine, flashmint) = flashmint_setup();
        (shrine, flashmint, flash_borrower_deploy(flashmint.contract_address))
    }
}

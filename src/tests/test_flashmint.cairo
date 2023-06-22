mod TestFlashmint {
    use array::ArrayTrait;
    use option::OptionTrait;
    use starknet::{
        contract_address_const, deploy_syscall, ClassHash, class_hash_try_from_felt252,
        ContractAddress, contract_address_to_felt252, get_block_timestamp, SyscallResultTrait
    };
    use starknet::contract_address::ContractAddressZeroable;
    use starknet::testing::set_contract_address;
    use traits::{Default, Into};

    use aura::core::flashmint::FlashMint;
    use aura::core::roles::ShrineRoles;

    use aura::interfaces::IERC20::{IERC20Dispatcher, IERC20DispatcherTrait};
    use aura::interfaces::IFlashBorrower::{IFlashBorrowerDispatcher, IFlashBorrowerDispatcherTrait};
    use aura::interfaces::IFlashMint::{IFlashMintDispatcher, IFlashMintDispatcherTrait};
    use aura::interfaces::IShrine::{IShrineDispatcher, IShrineDispatcherTrait};
    use aura::utils::access_control::{IAccessControlDispatcher, IAccessControlDispatcherTrait};
    use aura::utils::misc;
    use aura::utils::u256_conversions;
    use aura::utils::wadray;
    use aura::utils::wadray::{Wad, WAD_ONE};

    use aura::tests::shrine::utils::ShrineUtils;

    use super::FlashBorrower;

    const YIN_TOTAL_SUPPLY: u128 = 20000000000000000000000; // 20000 * WAD_ONE
    const DEFAULT_MINT_AMOUNT: u256 = 500000000000000000000_u256; // 500 * WAD_ONE

    // Helper function to build a calldata Span for `FlashMint.flash_loan`
    #[inline(always)]
    fn build_calldata(should_return_correct: bool, usage: felt252) -> Span<felt252> {
        let mut calldata = Default::default();
        calldata.append(should_return_correct.into());
        calldata.append(usage);
        calldata.span()
    }

    fn flashmint_deploy(shrine: ContractAddress) -> IFlashMintDispatcher {
        let mut calldata = Default::default();
        calldata.append(contract_address_to_felt252(shrine));

        let flashmint_class_hash: ClassHash = class_hash_try_from_felt252(
            FlashMint::TEST_CLASS_HASH
        )
            .unwrap();
        let (flashmint_addr, _) = deploy_syscall(flashmint_class_hash, 0, calldata.span(), false)
            .unwrap_syscall();
        IFlashMintDispatcher { contract_address: flashmint_addr }
    }

    fn flashmint_setup() -> (ContractAddress, IFlashMintDispatcher) {
        let shrine: ContractAddress = ShrineUtils::shrine_deploy();
        let flashmint: IFlashMintDispatcher = flashmint_deploy(shrine);

        let shrine_dispatcher = IShrineDispatcher { contract_address: shrine };

        ShrineUtils::shrine_setup(shrine);
        ShrineUtils::advance_prices_and_set_multiplier(
            shrine_dispatcher, 3, (1000 * WAD_ONE).into(), (10000 * WAD_ONE).into()
        );

        // Grant flashmint contract the FLASHMINT role 
        set_contract_address(ShrineUtils::admin());
        let shrine_accesscontrol = IAccessControlDispatcher { contract_address: shrine };
        shrine_accesscontrol.grant_role(ShrineRoles::flash_mint(), flashmint.contract_address);

        // Mint some yin in shrine 
        shrine_dispatcher.inject(ContractAddressZeroable::zero(), YIN_TOTAL_SUPPLY.into());
        (shrine, flashmint)
    }

    fn flash_borrower_deploy(flashmint: ContractAddress) -> ContractAddress {
        let mut calldata = Default::default();
        calldata.append(contract_address_to_felt252(flashmint));

        let flash_borrower_class_hash: ClassHash = class_hash_try_from_felt252(
            FlashBorrower::TEST_CLASS_HASH
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

    #[test]
    #[available_gas(20000000000)]
    fn test_flashmint_max_loan() {
        let (shrine, flashmint) = flashmint_setup();

        // Check that max loan is correct
        let max_loan: u256 = flashmint.max_flash_loan(shrine);
        let expected_max_loan: u256 = (Wad {
            val: YIN_TOTAL_SUPPLY
            } * Wad {
            val: FlashMint::FLASH_MINT_AMOUNT_PCT
        })
            .into();
        assert(max_loan == expected_max_loan, 'Incorrect max flash loan');
    }

    #[test]
    #[available_gas(20000000000)]
    fn test_flash_fee() {
        let shrine: ContractAddress = ShrineUtils::shrine_deploy();
        let flashmint: IFlashMintDispatcher = flashmint_deploy(shrine);

        // Check that flash fee is correct
        assert(flashmint.flash_fee(shrine, 0xdeadbeefdead_u256) == 0_u256, 'Incorrect flash fee');
    }

    #[test]
    #[available_gas(20000000000)]
    fn test_flashmint_pass() {
        let (shrine, flashmint, borrower) = flash_borrower_setup();
        let yin = ShrineUtils::yin(shrine);

        let mut calldata: Span<felt252> = build_calldata(true, FlashBorrower::VALID_USAGE);

        // `borrower` contains a check that ensures that `flashmint` actually transferred 
        // the full flash_loan amount
        flashmint.flash_loan(borrower, shrine, 1_u128.into(), calldata);
        assert(yin.balance_of(borrower) == 0_u256, 'Wrong yin bal after flashmint 1');
        flashmint.flash_loan(borrower, shrine, DEFAULT_MINT_AMOUNT, calldata);
        assert(yin.balance_of(borrower) == 0_u256, 'Wrong yin bal after flashmint 2');
        flashmint.flash_loan(borrower, shrine, (1000 * WAD_ONE).into(), calldata);
        assert(yin.balance_of(borrower) == 0_u256, 'Wrong yin bal after flashmint 3');
    // TODO: check event emissions for correct calldata
    }

    #[test]
    #[available_gas(20000000000)]
    #[should_panic(expected: ('FM: amount exceeds maximum', 'ENTRYPOINT_FAILED'))]
    fn test_flashmint_excess_minting() {
        let (shrine, flashmint, borrower) = flash_borrower_setup();
        flashmint
            .flash_loan(
                borrower,
                shrine,
                1000000000000000000001_u256,
                build_calldata(true, FlashBorrower::VALID_USAGE)
            );
    }

    #[test]
    #[available_gas(20000000000)]
    #[should_panic(expected: ('FM: on_flash_loan failed', 'ENTRYPOINT_FAILED'))]
    fn test_flashmint_incorrect_return() {
        let (shrine, flashmint, borrower) = flash_borrower_setup();
        flashmint
            .flash_loan(
                borrower,
                shrine,
                DEFAULT_MINT_AMOUNT,
                build_calldata(false, FlashBorrower::VALID_USAGE)
            );
    }

    #[test]
    #[available_gas(20000000000)]
    #[should_panic(expected: ('u128_sub Overflow', 'ENTRYPOINT_FAILED', 'ENTRYPOINT_FAILED'))]
    fn test_flashmint_steal() {
        let (shrine, flashmint, borrower) = flash_borrower_setup();
        flashmint
            .flash_loan(
                borrower,
                shrine,
                DEFAULT_MINT_AMOUNT,
                build_calldata(true, FlashBorrower::ATTEMPT_TO_STEAL)
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
        let (shrine, flashmint, borrower) = flash_borrower_setup();
        flashmint
            .flash_loan(
                borrower,
                shrine,
                DEFAULT_MINT_AMOUNT,
                build_calldata(true, FlashBorrower::ATTEMPT_TO_REENTER)
            );
    }
}

#[contract]
mod FlashBorrower {
    use array::SpanTrait;
    use option::OptionTrait;
    use starknet::{contract_address_const, get_contract_address, ContractAddress};

    use aura::core::flashmint::FlashMint::ON_FLASH_MINT_SUCCESS;
    use aura::interfaces::IERC20::{IERC20Dispatcher, IERC20DispatcherTrait};
    use aura::interfaces::IFlashMint::{IFlashMintDispatcher, IFlashMintDispatcherTrait};
    use aura::utils::serde;

    const VALID_USAGE: felt252 = 0;
    const ATTEMPT_TO_STEAL: felt252 = 1;
    const ATTEMPT_TO_REENTER: felt252 = 2;

    struct Storage {
        flashmint: IFlashMintDispatcher, 
    }

    #[constructor]
    fn constructor(flashmint: ContractAddress) {
        flashmint::write(IFlashMintDispatcher { contract_address: flashmint });
    }

    #[event]
    fn FlashLoancall_dataReceived(
        initiator: ContractAddress,
        token: ContractAddress,
        amount: u256,
        fee: u256,
        call_data: Span<felt252>
    ) {}

    #[external]
    fn on_flash_loan(
        initiator: ContractAddress,
        token: ContractAddress,
        amount: u256,
        fee: u256,
        mut call_data: Span<felt252>
    ) -> u256 {
        let call_data_copy = call_data;

        let should_return_correct: bool = *call_data.pop_front().unwrap() != 0;
        let action: felt252 = *call_data.pop_front().unwrap();

        if action == VALID_USAGE {
            assert(
                IERC20Dispatcher {
                    contract_address: token
                }.balance_of(get_contract_address()) == amount,
                'FB: incorrect loan amount'
            );
        } else if action == ATTEMPT_TO_STEAL {
            IERC20Dispatcher {
                contract_address: token
            }.transfer(contract_address_const::<0xbeef>(), amount);
        } else if action == ATTEMPT_TO_REENTER {
            flashmint::read().flash_loan(initiator, token, amount, call_data_copy);
        }

        // Emit event so tests can check that the function arguments are correct 
        FlashLoancall_dataReceived(initiator, token, amount, fee, call_data_copy);

        if should_return_correct {
            ON_FLASH_MINT_SUCCESS
        } else {
            0xbadbeef_u256
        }
    }
}

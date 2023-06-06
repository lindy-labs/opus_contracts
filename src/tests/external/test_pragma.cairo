#[cfg(test)]
mod TestPragma {
    use array::{ArrayTrait, SpanTrait};
    use option::OptionTrait;
    use starknet::{
        deploy_syscall, ClassHash, class_hash_try_from_felt252, ContractAddress, contract_address_const,
        contract_address_to_felt252, SyscallResultTrait
    };
    use starknet::contract_address::ContractAddressZeroable;
    use starknet::testing::set_contract_address;
    use traits::{Default, Into};

    use aura::core::roles::ShrineRoles;
    use aura::external::pragma::Pragma;

    use aura::interfaces::IOracle::{IOracleDispatcher, IOracleDispatcherTrait};
    use aura::interfaces::IPragma::{IPragmaDispatcher, IPragmaDispatcherTrait};
    use aura::interfaces::ISentinel::{ISentinelDispatcher, ISentinelDispatcherTrait};
    use aura::interfaces::IShrine::{IShrineDispatcher, IShrineDispatcherTrait};
    use aura::utils::access_control::{IAccessControlDispatcher, IAccessControlDispatcherTrait};

    use aura::tests::external::mock_pragma::{IMockPragmaDispatcher, IMockPragmaDispatcherTrait, MockPragma};
    use aura::tests::shrine::utils::ShrineUtils;

    //
    // Constants
    //

    const FRESHNESS_THRESHOLD: u64 = 1800;  // 30 minutes * 60 seconds
    const SOURCES_THRESHOLD: u64 = 3;
    const UPDATE_FREQUENCY: u64 = 600;  // 10 minutes * 60 seconds

    //
    // Address constants
    //

    // TODO: delete once sentinel is up
    fn mock_sentinel() -> ContractAddress {
        contract_address_const::<0xeeee>()
    }

    //
    // Test setup helpers
    //

    fn mock_pragma_deploy() -> ContractAddress {
        let mut calldata = Default::default();
        let mock_pragma_class_hash: ClassHash = class_hash_try_from_felt252(
            MockPragma::TEST_CLASS_HASH
        )
            .unwrap();
        let (mock_pragma_addr, _) = deploy_syscall(
            mock_pragma_class_hash, 0, calldata.span(), false
        )
            .unwrap_syscall();

        mock_pragma_addr
    }

    fn pragma_deploy() -> (IShrineDispatcher, IPragmaDispatcher, ISentinelDispatcher, IMockPragmaDispatcher) {
        let shrine: IShrineDispatcher = ShrineUtils::shrine_setup_with_feed();
        let oracle: ContractAddress = mock_pragma_deploy();

        let admin: ContractAddress = ShrineUtils::admin();
        let sentinel: ContractAddress = mock_sentinel();

        let mut calldata = Default::default();
        calldata.append(contract_address_to_felt252(admin));
        calldata.append(contract_address_to_felt252(shrine.contract_address));
        calldata.append(contract_address_to_felt252(oracle));
        calldata.append(contract_address_to_felt252(sentinel));
        calldata.append(UPDATE_FREQUENCY.into());
        calldata.append(FRESHNESS_THRESHOLD.into());
        calldata.append(SOURCES_THRESHOLD.into());

        let pragma_class_hash: ClassHash = class_hash_try_from_felt252(
            Pragma::TEST_CLASS_HASH
        )
            .unwrap();
        let (pragma_addr, _) = deploy_syscall(
            pragma_class_hash, 0, calldata.span(), false
        )
            .unwrap_syscall();

        // Grant access control
        let shrine_ac = IAccessControlDispatcher { contract_address: shrine.contract_address };
        set_contract_address(admin);
        shrine_ac.grant_role(ShrineRoles::ADVANCE, pragma_addr);
        set_contract_address(ContractAddressZeroable::zero());

        let sentinel = ISentinelDispatcher { contract_address: sentinel };
        let pragma = IPragmaDispatcher { contract_address: pragma_addr };
        let oracle = IMockPragmaDispatcher { contract_address: oracle };

        (shrine, pragma, sentinel, oracle)
    }

    #[test]
    #[available_gas(20000000000)]
    fn test_setup() {
        let (shrine, oracle, sentinel, mock_pragma) = pragma_deploy();


    }
}

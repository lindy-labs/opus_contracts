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

    use aura::core::roles::{PragmaRoles, ShrineRoles};
    use aura::external::pragma::Pragma;

    use aura::interfaces::IOracle::{IOracleDispatcher, IOracleDispatcherTrait};
    use aura::interfaces::IPragma::{IPragmaDispatcher, IPragmaDispatcherTrait};
    use aura::interfaces::ISentinel::{ISentinelDispatcher, ISentinelDispatcherTrait};
    use aura::interfaces::IShrine::{IShrineDispatcher, IShrineDispatcherTrait};
    use aura::utils::access_control::{IAccessControlDispatcher, IAccessControlDispatcherTrait};

    use aura::tests::external::mock_pragma::{IMockPragmaDispatcher, IMockPragmaDispatcherTrait, MockPragma};
    use aura::tests::shrine::utils::ShrineUtils;

    use debug::PrintTrait;

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

        // Check permissions
        let oracle_ac = IAccessControlDispatcher { contract_address: oracle.contract_address };
        let admin: ContractAddress = ShrineUtils::admin();

        assert(oracle_ac.get_admin() == admin, 'wrong admin');
        assert(oracle_ac.get_roles(admin) == PragmaRoles::default_admin_role(), 'wrong admin role');
        assert(oracle_ac.has_role(PragmaRoles::default_admin_role(), admin), 'wrong admin role');
    }

    #[test]
    #[available_gas(20000000000)]
    fn test_set_price_validity_thresholds() {
        let (shrine, oracle, sentinel, mock_pragma) = pragma_deploy();
        
        let new_freshness: u64 = 300;  // 5 minutes * 60 seconds
        let new_sources: u64 = 8;

        let admin: ContractAddress = ShrineUtils::admin();
        set_contract_address(admin);
        oracle.set_price_validity_thresholds(new_freshness, new_sources);
    }

    #[test]
    #[available_gas(20000000000)]
    #[should_panic(expected: ('PGM: Freshness out of bounds', 'ENTRYPOINT_FAILED'))]
    fn test_set_price_validity_threshold_freshness_too_low_fail() {
        let (shrine, oracle, sentinel, mock_pragma) = pragma_deploy();
        
        let invalid_freshness: u64 = Pragma::LOWER_FRESHNESS_BOUND - 1;
        let valid_sources: u64 = SOURCES_THRESHOLD;

        let admin: ContractAddress = ShrineUtils::admin();
        set_contract_address(admin);
        oracle.set_price_validity_thresholds(invalid_freshness, valid_sources);
    }

    #[test]
    #[available_gas(20000000000)]
    #[should_panic(expected: ('PGM: Freshness out of bounds', 'ENTRYPOINT_FAILED'))]
    fn test_set_price_validity_threshold_freshness_too_high_fail() {
        let (shrine, oracle, sentinel, mock_pragma) = pragma_deploy();
        
        let invalid_freshness: u64 = Pragma::UPPER_FRESHNESS_BOUND + 1;
        let valid_sources: u64 = SOURCES_THRESHOLD;

        let admin: ContractAddress = ShrineUtils::admin();
        set_contract_address(admin);
        oracle.set_price_validity_thresholds(invalid_freshness, valid_sources);
    }

    #[test]
    #[available_gas(20000000000)]
    #[should_panic(expected: ('PGM: Sources out of bounds', 'ENTRYPOINT_FAILED'))]
    fn test_set_price_validity_threshold_sources_too_low_fail() {
        let (shrine, oracle, sentinel, mock_pragma) = pragma_deploy();

        let valid_freshness: u64 = FRESHNESS_THRESHOLD;
        let invalid_sources: u64 = Pragma::LOWER_SOURCES_BOUND - 1;

        let admin: ContractAddress = ShrineUtils::admin();
        set_contract_address(admin);
        oracle.set_price_validity_thresholds(valid_freshness, invalid_sources);
    }

    #[test]
    #[available_gas(20000000000)]
    #[should_panic(expected: ('PGM: Sources out of bounds', 'ENTRYPOINT_FAILED'))]
    fn test_set_price_validity_threshold_sources_too_high_fail() {
        let (shrine, oracle, sentinel, mock_pragma) = pragma_deploy();

        let valid_freshness: u64 = FRESHNESS_THRESHOLD;
        let invalid_sources: u64 = Pragma::UPPER_SOURCES_BOUND + 1;

        let admin: ContractAddress = ShrineUtils::admin();
        set_contract_address(admin);
        oracle.set_price_validity_thresholds(valid_freshness, invalid_sources);
    }
}

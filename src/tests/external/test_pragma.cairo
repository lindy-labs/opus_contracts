#[cfg(test)]
mod TestPragma {
    use array::{ArrayTrait, SpanTrait};
    use option::OptionTrait;
    use starknet::{
        deploy_syscall, ClassHash, class_hash_try_from_felt252, ContractAddress,
        contract_address_to_felt252, SyscallResultTrait
    };
    use traits::Default;

    use aura::interfaces::IOracle::{IOracleDispatcher, IOracleDispatcherTrait};
    use aura::interfaces::IPragma::{IPragmaDispatcher, IPragmaDispatcherTrait};
    use aura::interfaces::IShrine::{IShrineDispatcher, IShrineDispatcherTrait};
    use aura::utils::access_control::{IAccessControlDispatcher, IAccessControlDispatcherTrait};

    use aura::tests::external::mock_pragma::MockPragma;
    use aura::tests::shrine::utils::ShrineUtils;

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

    fn pragma_deploy() {
        let shrine: IShrineDispatcher = ShrineUtils::shrine_setup_with_feed();
    // TODO: deploy pragma
    }

    #[test]
    #[available_gas(20000000000)]
    fn test_mock_pragma_deploy() {
        mock_pragma_deploy();
    }
}

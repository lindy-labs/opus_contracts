mod transmuter_utils {
    use opus::core::roles::{transmuter_roles, transmuter_registry_roles};
    use opus::core::transmuter::transmuter as transmuter_contract;
    use opus::core::transmuter_registry::transmuter_registry as transmuter_registry_contract;
    use opus::interfaces::IERC20::{IERC20Dispatcher, IERC20DispatcherTrait};
    use opus::interfaces::IShrine::{IShrineDispatcher, IShrineDispatcherTrait};
    use opus::interfaces::ITransmuter::{ITransmuterDispatcher, ITransmuterDispatcherTrait};
    use opus::tests::common;
    use opus::tests::shrine::utils::shrine_utils;
    //use opus::utils::access_control::{IAccessControlDispatcher, IAccessControlDispatcherTrait};
    //use opus::utils::wadray::Ray;
    //use starknet::contract_address::ContractAddressZeroable;
    use starknet::testing::set_contract_address;
    use starknet::{
        deploy_syscall, ClassHash, class_hash_try_from_felt252, ContractAddress,
        contract_address_to_felt252, contract_address_try_from_felt252, SyscallResultTrait
    };

    // Constants

    // 1_000_000 (Wad)
    const INITIAL_CEILING: u128 = 1000000000000000000000000;

    // 2_000_000 (Wad)
    const MOCK_USD_TOTAL: u128 = 2000000000000000000000000;

    fn receiver() -> ContractAddress {
        contract_address_try_from_felt252('receiver').unwrap()
    }

    fn mock_usd_hoarder() -> ContractAddress {
        contract_address_try_from_felt252('mock_usd hoarder').unwrap()
    }


    //
    // Test setup helpers
    //

    fn transmuter_deploy(
        shrine: ContractAddress, asset: ContractAddress, receiver: ContractAddress,
    ) -> ITransmuterDispatcher {
        let mut calldata: Array<felt252> = array![
            contract_address_to_felt252(shrine_utils::admin()),
            contract_address_to_felt252(shrine),
            contract_address_to_felt252(asset),
            contract_address_to_felt252(receiver),
            INITIAL_CEILING.into()
        ];

        let transmuter_class_hash: ClassHash = class_hash_try_from_felt252(
            transmuter_contract::TEST_CLASS_HASH
        )
            .unwrap();
        let (transmuter_addr, _) = deploy_syscall(transmuter_class_hash, 0, calldata.span(), false)
            .unwrap_syscall();

        ITransmuterDispatcher { contract_address: transmuter_addr }
    }

    fn mock_usd_stable_deploy() -> IERC20Dispatcher {
        IERC20Dispatcher {
            contract_address: common::deploy_token(
                'Mock USD', 'mUSD', 18, MOCK_USD_TOTAL.into(), mock_usd_hoarder()
            )
        }
    }

    fn shrine_with_mock_usd_stable_transmuter() -> (
        IShrineDispatcher, ITransmuterDispatcher, IERC20Dispatcher
    ) {
        let shrine: IShrineDispatcher = shrine_utils::shrine_setup_with_feed(Option::None);
        let mock_usd_stable: IERC20Dispatcher = mock_usd_stable_deploy();

        let transmuter: ITransmuterDispatcher = transmuter_deploy(
            shrine.contract_address, mock_usd_stable.contract_address, receiver(),
        );

        (shrine, transmuter, mock_usd_stable)
    }
}

mod transmuter_utils {
    use integer::BoundedInt;
    use opus::core::roles::shrine_roles;
    use opus::core::transmuter::transmuter as transmuter_contract;
    use opus::core::transmuter_registry::transmuter_registry as transmuter_registry_contract;
    use opus::interfaces::IERC20::{IERC20Dispatcher, IERC20DispatcherTrait};
    use opus::interfaces::IShrine::{IShrineDispatcher, IShrineDispatcherTrait};
    use opus::interfaces::ITransmuter::{ITransmuterDispatcher, ITransmuterDispatcherTrait};
    use opus::tests::common;
    use opus::tests::shrine::utils::shrine_utils;
    use opus::utils::access_control::{IAccessControlDispatcher, IAccessControlDispatcherTrait};
    use opus::utils::wadray::Wad;
    use starknet::testing::set_contract_address;
    use starknet::{
        deploy_syscall, ClassHash, class_hash_try_from_felt252, ContractAddress,
        contract_address_to_felt252, contract_address_try_from_felt252, SyscallResultTrait
    };

    // Constants

    // 1_000_000 (Wad)
    const INITIAL_CEILING: u128 = 1000000000000000000000000;

    // 20_000_000 (Wad)
    const START_TOTAL_YIN: u128 = 20000000000000000000000000;

    // 2_000_000 (Wad)
    const MOCK_WAD_USD_TOTAL: u128 = 2000000000000000000000000;

    // 2_000_000 (6 decimals)
    const MOCK_NONWAD_USD_TOTAL: u128 = 2000000000000;

    fn receiver() -> ContractAddress {
        contract_address_try_from_felt252('receiver').unwrap()
    }

    fn user() -> ContractAddress {
        contract_address_try_from_felt252('transmuter user').unwrap()
    }


    //
    // Test setup helpers
    //

    fn transmuter_deploy(
        shrine: ContractAddress,
        asset: ContractAddress,
        receiver: ContractAddress,
        salt: Option<felt252>
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
        let (transmuter_addr, _) = deploy_syscall(
            transmuter_class_hash, salt.unwrap_or(0), calldata.span(), false
        )
            .unwrap_syscall();

        set_contract_address(shrine_utils::admin());
        let shrine_ac: IAccessControlDispatcher = IAccessControlDispatcher {
            contract_address: shrine
        };
        shrine_ac.grant_role(shrine_roles::transmuter(), transmuter_addr);

        ITransmuterDispatcher { contract_address: transmuter_addr }
    }

    // mock stable with 18 decimals
    fn mock_wad_usd_stable_deploy() -> IERC20Dispatcher {
        IERC20Dispatcher {
            contract_address: common::deploy_token(
                'Mock USD #1', 'mUSD1', 18, MOCK_WAD_USD_TOTAL.into(), user()
            )
        }
    }

    // mock stable with 6 decimals
    fn mock_nonwad_usd_stable_deploy() -> IERC20Dispatcher {
        IERC20Dispatcher {
            contract_address: common::deploy_token(
                'Mock USD #2', 'mUSD2', 6, MOCK_NONWAD_USD_TOTAL.into(), user()
            )
        }
    }

    fn setup_shrine_with_transmuter(
        shrine: IShrineDispatcher,
        transmuter: ITransmuterDispatcher,
        shrine_ceiling: Wad,
        shrine_start_yin: Wad,
        start_yin_recipient: ContractAddress,
        user: ContractAddress
    ) {
        // set debt ceiling to 30m
        set_contract_address(shrine_utils::admin());
        shrine.set_debt_ceiling(shrine_ceiling);
        shrine.inject(start_yin_recipient, shrine_start_yin);

        // approve transmuter to deal with user's tokens
        set_contract_address(user);
        IERC20Dispatcher { contract_address: transmuter.get_asset() }
            .approve(transmuter.contract_address, BoundedInt::max());
    }

    fn shrine_with_mock_wad_usd_stable_transmuter() -> (
        IShrineDispatcher, ITransmuterDispatcher, IERC20Dispatcher
    ) {
        let shrine: IShrineDispatcher = shrine_utils::shrine_setup_with_feed(Option::None);
        let mock_usd_stable: IERC20Dispatcher = mock_wad_usd_stable_deploy();

        let transmuter: ITransmuterDispatcher = transmuter_deploy(
            shrine.contract_address, mock_usd_stable.contract_address, receiver(), Option::None
        );

        let debt_ceiling: Wad = 30000000000000000000000000_u128.into();
        let seed_amt: Wad = START_TOTAL_YIN.into();
        setup_shrine_with_transmuter(
            shrine, transmuter, debt_ceiling, seed_amt, receiver(), user(),
        );

        (shrine, transmuter, mock_usd_stable)
    }
}

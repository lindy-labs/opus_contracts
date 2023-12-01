mod seer_utils {
    use debug::PrintTrait;
    use opus::core::roles::shrine_roles;
    use opus::core::seer::seer as seer_contract;
    use opus::interfaces::IOracle::{IOracleDispatcher, IOracleDispatcherTrait};
    use opus::interfaces::IPragma::{IPragmaDispatcher, IPragmaDispatcherTrait};
    use opus::interfaces::ISeer::{ISeerDispatcher, ISeerDispatcherTrait};
    use opus::interfaces::ISentinel::ISentinelDispatcher;
    use opus::interfaces::IShrine::IShrineDispatcher;
    use opus::tests::external::mock_pragma::{IMockPragmaDispatcher, IMockPragmaDispatcherTrait};
    use opus::tests::external::utils::pragma_utils;
    use opus::tests::sentinel::utils::sentinel_utils;
    use opus::tests::shrine::utils::shrine_utils;
    use opus::utils::access_control::{IAccessControlDispatcher, IAccessControlDispatcherTrait};
    use opus::utils::wadray::Wad;
    use starknet::contract_address::ContractAddressZeroable;
    use starknet::testing::set_contract_address;
    use starknet::{
        class_hash_try_from_felt252, contract_address_to_felt252, contract_address_try_from_felt252, deploy_syscall,
        get_block_timestamp, ClassHash, ContractAddress, SyscallResultTrait
    };

    //
    // Constants
    //

    const ETH_INIT_PRICE: u128 = 1888000000000000000000; // Wad scale
    const WBTC_INIT_PRICE: u128 = 20000000000000000000000; // Wad scale

    const UPDATE_FREQUENCY: u64 = consteval_int!(30 * 60); // 30 minutes

    //
    // Address constants
    //

    fn admin() -> ContractAddress {
        contract_address_try_from_felt252('seer owner').unwrap()
    }

    fn dummy_eth() -> ContractAddress {
        contract_address_try_from_felt252('eth token').unwrap()
    }

    fn dummy_wbtc() -> ContractAddress {
        contract_address_try_from_felt252('wbtc token').unwrap()
    }

    fn deploy_seer() -> (ISeerDispatcher, ISentinelDispatcher, IShrineDispatcher) {
        let (sentinel_dispatcher, shrine) = sentinel_utils::deploy_sentinel(Option::None);
        let mut calldata: Array<felt252> = array![
            contract_address_to_felt252(admin()),
            contract_address_to_felt252(shrine),
            contract_address_to_felt252(sentinel_dispatcher.contract_address),
            UPDATE_FREQUENCY.into()
        ];

        let seer_class_hash: ClassHash = class_hash_try_from_felt252(seer_contract::TEST_CLASS_HASH).unwrap();

        let (seer_addr, _) = deploy_syscall(seer_class_hash, 0, calldata.span(), false).unwrap_syscall();

        // Allow Seer to advance Shrine
        let shrine_ac = IAccessControlDispatcher { contract_address: shrine };
        set_contract_address(shrine_utils::admin());
        shrine_ac.grant_role(shrine_roles::seer(), seer_addr);

        (
            ISeerDispatcher { contract_address: seer_addr },
            sentinel_dispatcher,
            IShrineDispatcher { contract_address: shrine }
        )
    }

    fn deploy_seer_using(shrine: ContractAddress, sentinel: ContractAddress) -> ISeerDispatcher {
        let mut calldata: Array<felt252> = array![
            contract_address_to_felt252(admin()),
            contract_address_to_felt252(shrine),
            contract_address_to_felt252(sentinel),
            UPDATE_FREQUENCY.into()
        ];

        let seer_class_hash: ClassHash = class_hash_try_from_felt252(seer_contract::TEST_CLASS_HASH).unwrap();

        let (seer_addr, _) = deploy_syscall(seer_class_hash, 0, calldata.span(), false).unwrap_syscall();

        // Allow Seer to advance Shrine
        let shrine_ac = IAccessControlDispatcher { contract_address: shrine };
        set_contract_address(shrine_utils::admin());
        shrine_ac.grant_role(shrine_roles::seer(), seer_addr);

        ISeerDispatcher { contract_address: seer_addr }
    }

    fn add_oracles(seer: ISeerDispatcher) -> Span<ContractAddress> {
        let mut oracles: Array<ContractAddress> = ArrayTrait::new();

        let (pragma, _) = pragma_utils::pragma_deploy();
        oracles.append(pragma.contract_address);
        let pragma_ac = IAccessControlDispatcher { contract_address: pragma.contract_address };
        set_contract_address(pragma_utils::admin());

        set_contract_address(admin());
        seer.set_oracles(oracles.span());
        set_contract_address(ContractAddressZeroable::zero());

        oracles.span()
    }

    fn add_yangs(seer: ISeerDispatcher, yangs: Span<ContractAddress>) {
        let oracles: Span<ContractAddress> = seer.get_oracles();
        // assuming first oracle is Pragma
        let pragma = IPragmaDispatcher { contract_address: *oracles.at(0) };
        pragma_utils::add_yangs_to_pragma(pragma, yangs);
    }

    fn mock_valid_price_update(seer: ISeerDispatcher, yang: ContractAddress, price: Wad) {
        let current_ts: u64 = get_block_timestamp();
        let oracles: Span<ContractAddress> = seer.get_oracles();

        // assuming first oracle is Pragma
        let pragma = IOracleDispatcher { contract_address: *oracles.at(0) };
        let mock_pragma = IMockPragmaDispatcher { contract_address: pragma.get_oracle() };
        pragma_utils::mock_valid_price_update(mock_pragma, yang, price, current_ts);
    }
}

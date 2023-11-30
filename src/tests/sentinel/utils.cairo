mod sentinel_utils {
    use debug::PrintTrait;
    use integer::BoundedU256;
    use opus::core::roles::{sentinel_roles, shrine_roles};
    use opus::core::sentinel::sentinel as sentinel_contract;
    use opus::interfaces::IERC20::{IERC20Dispatcher, IERC20DispatcherTrait};
    use opus::interfaces::IGate::{IGateDispatcher, IGateDispatcherTrait};
    use opus::interfaces::ISentinel::{ISentinelDispatcher, ISentinelDispatcherTrait};
    use opus::interfaces::IShrine::{IShrineDispatcher, IShrineDispatcherTrait};
    use opus::tests::common;
    use opus::tests::gate::utils::gate_utils;
    use opus::tests::shrine::utils::shrine_utils;
    use opus::utils::access_control::{IAccessControlDispatcher, IAccessControlDispatcherTrait};
    use opus::utils::wadray::{Wad, Ray};
    use opus::utils::wadray;
    use starknet::contract_address::ContractAddressZeroable;
    use starknet::testing::set_contract_address;
    use starknet::{
        ClassHash, class_hash_try_from_felt252, ContractAddress, contract_address_to_felt252,
        contract_address_try_from_felt252, deploy_syscall, get_caller_address, SyscallResultTrait
    };

    const ETH_ASSET_MAX: u128 = 1000000000000000000000; // 1000 (wad)
    const WBTC_ASSET_MAX: u128 = 100000000000; // 1000 * 10**8

    #[inline(always)]
    fn admin() -> ContractAddress {
        contract_address_try_from_felt252('sentinel admin').unwrap()
    }

    #[inline(always)]
    fn mock_abbot() -> ContractAddress {
        contract_address_try_from_felt252('mock abbot').unwrap()
    }

    #[inline(always)]
    fn dummy_yang_addr() -> ContractAddress {
        contract_address_try_from_felt252('dummy yang').unwrap()
    }

    #[inline(always)]
    fn dummy_yang_gate_addr() -> ContractAddress {
        contract_address_try_from_felt252('dummy yang token').unwrap()
    }

    //
    // Test setup
    //

    fn deploy_sentinel(salt: Option<felt252>) -> (ISentinelDispatcher, ContractAddress) {
        let shrine_addr: ContractAddress = shrine_utils::shrine_deploy(salt);

        let mut calldata: Array<felt252> = array![
            contract_address_to_felt252(admin()), contract_address_to_felt252(shrine_addr)
        ];

        let sentinel_class_hash: ClassHash = class_hash_try_from_felt252(
            sentinel_contract::TEST_CLASS_HASH
        )
            .unwrap();

        let (sentinel_addr, _) = deploy_syscall(sentinel_class_hash, 0, calldata.span(), false)
            .unwrap_syscall();

        // Grant `abbot` role to `mock_abbot`
        set_contract_address(admin());
        IAccessControlDispatcher { contract_address: sentinel_addr }
            .grant_role(sentinel_roles::abbot(), mock_abbot());

        let shrine_ac = IAccessControlDispatcher { contract_address: shrine_addr };
        set_contract_address(shrine_utils::admin());

        shrine_ac.grant_role(shrine_roles::sentinel(), sentinel_addr);
        shrine_ac.grant_role(shrine_roles::abbot(), mock_abbot());

        set_contract_address(ContractAddressZeroable::zero());

        (ISentinelDispatcher { contract_address: sentinel_addr }, shrine_addr)
    }

    fn deploy_sentinel_with_gates(
        salt: Option<felt252>
    ) -> (ISentinelDispatcher, IShrineDispatcher, Span<ContractAddress>, Span<IGateDispatcher>) {
        let (sentinel, shrine_addr) = deploy_sentinel(salt);

        let (eth, eth_gate) = add_eth_yang(sentinel, shrine_addr);
        let (wbtc, wbtc_gate) = add_wbtc_yang(sentinel, shrine_addr);

        let mut assets: Array<ContractAddress> = array![eth, wbtc];
        let mut gates: Array<IGateDispatcher> = array![eth_gate, wbtc_gate];

        (sentinel, IShrineDispatcher { contract_address: shrine_addr }, assets.span(), gates.span())
    }

    fn deploy_sentinel_with_eth_gate() -> (
        ISentinelDispatcher, IShrineDispatcher, ContractAddress, IGateDispatcher
    ) {
        let (sentinel, shrine_addr) = deploy_sentinel(Option::None);
        let (eth, eth_gate) = add_eth_yang(sentinel, shrine_addr);

        (sentinel, IShrineDispatcher { contract_address: shrine_addr }, eth, eth_gate)
    }

    fn add_eth_yang(
        sentinel: ISentinelDispatcher, shrine_addr: ContractAddress
    ) -> (ContractAddress, IGateDispatcher) {
        let eth: ContractAddress = common::eth_token_deploy();
        let eth_gate: ContractAddress = gate_utils::gate_deploy(
            eth, shrine_addr, sentinel.contract_address
        );

        let eth_erc20 = IERC20Dispatcher { contract_address: eth };

        // Transferring the initial deposit amounts to `admin()`
        set_contract_address(common::eth_hoarder());
        eth_erc20.transfer(admin(), sentinel_contract::INITIAL_DEPOSIT_AMT.into());

        set_contract_address(admin());
        eth_erc20.approve(sentinel.contract_address, sentinel_contract::INITIAL_DEPOSIT_AMT.into());
        sentinel
            .add_yang(
                eth,
                ETH_ASSET_MAX,
                shrine_utils::YANG1_THRESHOLD.into(),
                shrine_utils::YANG1_START_PRICE.into(),
                shrine_utils::YANG1_BASE_RATE.into(),
                eth_gate
            );
        set_contract_address(ContractAddressZeroable::zero());

        (eth, IGateDispatcher { contract_address: eth_gate })
    }

    fn add_wbtc_yang(
        sentinel: ISentinelDispatcher, shrine_addr: ContractAddress
    ) -> (ContractAddress, IGateDispatcher) {
        let wbtc: ContractAddress = common::wbtc_token_deploy();
        let wbtc_gate: ContractAddress = gate_utils::gate_deploy(
            wbtc, shrine_addr, sentinel.contract_address
        );

        let wbtc_erc20 = IERC20Dispatcher { contract_address: wbtc };

        // Transferring the initial deposit amounts to `admin()`
        set_contract_address(common::wbtc_hoarder());
        wbtc_erc20.transfer(admin(), sentinel_contract::INITIAL_DEPOSIT_AMT.into());

        set_contract_address(admin());
        wbtc_erc20
            .approve(sentinel.contract_address, sentinel_contract::INITIAL_DEPOSIT_AMT.into());
        sentinel
            .add_yang(
                wbtc,
                WBTC_ASSET_MAX,
                shrine_utils::YANG2_THRESHOLD.into(),
                shrine_utils::YANG2_START_PRICE.into(),
                shrine_utils::YANG2_BASE_RATE.into(),
                wbtc_gate
            );
        set_contract_address(ContractAddressZeroable::zero());

        (wbtc, IGateDispatcher { contract_address: wbtc_gate })
    }

    fn approve_max(gate: IGateDispatcher, token: ContractAddress, user: ContractAddress) {
        let token_erc20 = IERC20Dispatcher { contract_address: token };
        let prev_address: ContractAddress = get_caller_address();
        set_contract_address(user);
        token_erc20.approve(gate.contract_address, BoundedU256::max());
        set_contract_address(prev_address);
    }
}

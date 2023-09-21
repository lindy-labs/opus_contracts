mod SentinelUtils {
    use debug::PrintTrait;
    use integer::BoundedU256;
    use starknet::{
        ClassHash, class_hash_try_from_felt252, ContractAddress, contract_address_to_felt252,
        contract_address_try_from_felt252, deploy_syscall, get_caller_address, SyscallResultTrait
    };
    use starknet::contract_address::ContractAddressZeroable;
    use starknet::testing::set_contract_address;

    use aura::core::roles::{SentinelRoles, ShrineRoles};
    use aura::core::sentinel::Sentinel;

    use aura::interfaces::IERC20::{IERC20Dispatcher, IERC20DispatcherTrait};
    use aura::interfaces::IGate::{IGateDispatcher, IGateDispatcherTrait};
    use aura::interfaces::ISentinel::{ISentinelDispatcher, ISentinelDispatcherTrait};
    use aura::interfaces::IShrine::{IShrineDispatcher, IShrineDispatcherTrait};
    use aura::utils::access_control::{IAccessControlDispatcher, IAccessControlDispatcherTrait};
    use aura::utils::wadray;
    use aura::utils::wadray::{Wad, Ray};

    use aura::tests::gate::utils::GateUtils;
    use aura::tests::shrine::utils::ShrineUtils;

    const ETH_ASSET_MAX: u128 = 200000000000000000000; // 200 (wad)
    const WBTC_ASSET_MAX: u128 = 20000000000; // 200 * 10**8

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

    fn deploy_sentinel() -> (ISentinelDispatcher, ContractAddress) {
        let shrine_addr: ContractAddress = ShrineUtils::shrine_deploy();

        let mut calldata: Array<felt252> = array![
            contract_address_to_felt252(admin()), contract_address_to_felt252(shrine_addr)
        ];

        let sentinel_class_hash: ClassHash = class_hash_try_from_felt252(Sentinel::TEST_CLASS_HASH)
            .unwrap();

        let (sentinel_addr, _) = deploy_syscall(sentinel_class_hash, 0, calldata.span(), false)
            .unwrap_syscall();

        // Grant `abbot` role to `mock_abbot`
        set_contract_address(admin());
        IAccessControlDispatcher { contract_address: sentinel_addr }
            .grant_role(SentinelRoles::abbot(), mock_abbot());

        let shrine_ac = IAccessControlDispatcher { contract_address: shrine_addr };
        set_contract_address(ShrineUtils::admin());

        shrine_ac.grant_role(ShrineRoles::sentinel(), sentinel_addr);
        shrine_ac.grant_role(ShrineRoles::abbot(), mock_abbot());

        set_contract_address(ContractAddressZeroable::zero());

        (ISentinelDispatcher { contract_address: sentinel_addr }, shrine_addr)
    }

    fn deploy_sentinel_with_gates() -> (
        ISentinelDispatcher, IShrineDispatcher, Span<ContractAddress>, Span<IGateDispatcher>
    ) {
        let (sentinel, shrine_addr) = deploy_sentinel();

        let (eth, eth_gate) = add_eth_yang(sentinel, shrine_addr);
        let (wbtc, wbtc_gate) = add_wbtc_yang(sentinel, shrine_addr);

        let mut assets: Array<ContractAddress> = array![eth, wbtc];
        let mut gates: Array<IGateDispatcher> = array![eth_gate, wbtc_gate];

        (sentinel, IShrineDispatcher { contract_address: shrine_addr }, assets.span(), gates.span())
    }

    fn deploy_sentinel_with_eth_gate() -> (
        ISentinelDispatcher, IShrineDispatcher, ContractAddress, IGateDispatcher
    ) {
        let (sentinel, shrine_addr) = deploy_sentinel();
        let (eth, eth_gate) = add_eth_yang(sentinel, shrine_addr);

        (sentinel, IShrineDispatcher { contract_address: shrine_addr }, eth, eth_gate)
    }

    fn add_eth_yang(
        sentinel: ISentinelDispatcher, shrine_addr: ContractAddress
    ) -> (ContractAddress, IGateDispatcher) {
        let eth: ContractAddress = GateUtils::eth_token_deploy();
        let eth_gate: ContractAddress = GateUtils::gate_deploy(
            eth, shrine_addr, sentinel.contract_address
        );

        let eth_erc20 = IERC20Dispatcher { contract_address: eth };

        // Transferring the initial deposit amounts to `admin()`
        set_contract_address(GateUtils::eth_hoarder());
        eth_erc20.transfer(admin(), Sentinel::INITIAL_DEPOSIT_AMT.into());

        set_contract_address(admin());
        eth_erc20.approve(sentinel.contract_address, Sentinel::INITIAL_DEPOSIT_AMT.into());
        sentinel
            .add_yang(
                eth,
                ETH_ASSET_MAX,
                ShrineUtils::YANG1_THRESHOLD.into(),
                ShrineUtils::YANG1_START_PRICE.into(),
                ShrineUtils::YANG1_BASE_RATE.into(),
                eth_gate
            );
        set_contract_address(ContractAddressZeroable::zero());

        (eth, IGateDispatcher { contract_address: eth_gate })
    }

    fn add_wbtc_yang(
        sentinel: ISentinelDispatcher, shrine_addr: ContractAddress
    ) -> (ContractAddress, IGateDispatcher) {
        let wbtc: ContractAddress = GateUtils::wbtc_token_deploy();
        let wbtc_gate: ContractAddress = GateUtils::gate_deploy(
            wbtc, shrine_addr, sentinel.contract_address
        );

        let wbtc_erc20 = IERC20Dispatcher { contract_address: wbtc };

        // Transferring the initial deposit amounts to `admin()`
        set_contract_address(GateUtils::wbtc_hoarder());
        wbtc_erc20.transfer(admin(), Sentinel::INITIAL_DEPOSIT_AMT.into());

        set_contract_address(admin());
        wbtc_erc20.approve(sentinel.contract_address, Sentinel::INITIAL_DEPOSIT_AMT.into());
        sentinel
            .add_yang(
                wbtc,
                WBTC_ASSET_MAX,
                ShrineUtils::YANG2_THRESHOLD.into(),
                ShrineUtils::YANG2_START_PRICE.into(),
                ShrineUtils::YANG2_BASE_RATE.into(),
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

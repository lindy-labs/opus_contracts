mod SentinelUtils {
    use array::{ArrayTrait, SpanTrait};
    use debug::PrintTrait;
    use option::OptionTrait;
    use starknet::{ClassHash, class_hash_try_from_felt252, ContractAddress, contract_address_const, contract_address_to_felt252, deploy_syscall, SyscallResultTrait};
    use starknet::testing::set_contract_address;
    use traits::{Default, Into};

    use aura::core::roles::{SentinelRoles, ShrineRoles};
    use aura::core::sentinel::Sentinel;

    use aura::interfaces::IERC20::{IERC20Dispatcher, IERC20DispatcherTrait};
    use aura::interfaces::IGate::{IGateDispatcher, IGateDispatcherTrait};
    use aura::interfaces::ISentinel::{ISentinelDispatcher, ISentinelDispatcherTrait};
    use aura::interfaces::IShrine::{IShrineDispatcher, IShrineDispatcherTrait};
    use aura::tests::gate::utils::GateUtils;
    use aura::tests::shrine::utils::ShrineUtils;
    use aura::utils::access_control::{IAccessControlDispatcher, IAccessControlDispatcherTrait};
    use aura::utils::wadray;
    use aura::utils::wadray::{Wad, Ray}; 
    
    const ETH_ASSET_MAX: u128 = 100000000000000000000; // 100 (wad)
    const WBTC_ASSET_MAX: u128 = 10000000000; // 100 * 10**8

    #[inline(always)]
    fn admin() -> ContractAddress {
        contract_address_const::<0x1337>()
    }

    #[inline(always)]
    fn mock_abbot() -> ContractAddress {
        contract_address_const::<0xABB07>()
    }

    //
    // Test setup 
    // 

    fn deploy_sentinel() -> (ISentinelDispatcher, ContractAddress) {
        let shrine: ContractAddress = ShrineUtils::shrine_deploy();

        let mut calldata = Default::default();
        calldata.append(contract_address_to_felt252(admin()));
        calldata.append(contract_address_to_felt252(shrine));

        let sentinel_class_hash: ClassHash = class_hash_try_from_felt252(
            Sentinel::TEST_CLASS_HASH
        ).unwrap();

        let (sentinel_addr, _) = deploy_syscall(sentinel_class_hash, 0, calldata.span(), false)
            .unwrap_syscall();

        (ISentinelDispatcher{ contract_address: sentinel_addr }, shrine)
    }

    fn deploy_sentinel_with_gates() -> (ISentinelDispatcher, IShrineDispatcher, Span<ContractAddress>, Span<IGateDispatcher>) {
        let (sentinel, shrine) = deploy_sentinel();

        let (eth, eth_gate) = GateUtils::eth_gate_deploy_internal(shrine, sentinel.contract_address);
        let (wbtc, wbtc_gate) = GateUtils::wbtc_gate_deploy_internal(shrine, sentinel.contract_address);

        let eth_erc20 = IERC20Dispatcher{contract_address: eth};
        let wbtc_erc20 = IERC20Dispatcher{contract_address: wbtc};
        
        // Tranasferring the initial deposit amounts to `admin()`
        set_contract_address(GateUtils::eth_hoarder());
        eth_erc20.transfer(admin(), Sentinel::INITIAL_DEPOSIT_AMT.into());

        set_contract_address(GateUtils::wbtc_hoarder());
        wbtc_erc20.transfer(admin(), Sentinel::INITIAL_DEPOSIT_AMT.into());

        // Approving sentinel for `add_yang`
        let shrine_ac = IAccessControlDispatcher{contract_address: shrine};
        set_contract_address(ShrineUtils::admin());
        shrine_ac.grant_role(ShrineRoles::ADD_YANG + ShrineRoles::SET_THRESHOLD, sentinel.contract_address);

        set_contract_address(admin());

        eth_erc20.approve(sentinel.contract_address, Sentinel::INITIAL_DEPOSIT_AMT.into());
        wbtc_erc20.approve(sentinel.contract_address, Sentinel::INITIAL_DEPOSIT_AMT.into());

        sentinel.add_yang(eth, ETH_ASSET_MAX, ShrineUtils::YANG1_THRESHOLD.into(), ShrineUtils::YANG1_START_PRICE.into(), ShrineUtils::YANG1_BASE_RATE.into(), eth_gate);
        sentinel.add_yang(wbtc, WBTC_ASSET_MAX, ShrineUtils::YANG2_THRESHOLD.into(), ShrineUtils::YANG2_START_PRICE.into(), ShrineUtils::YANG2_BASE_RATE.into(), wbtc_gate);

        set_contract_address(contract_address_const::<0>());
    
        let mut assets: Array<ContractAddress> = Default::default();
        assets.append(eth);
        assets.append(wbtc);

        let mut gates: Array<IGateDispatcher> = Default::default();
        gates.append(IGateDispatcher{contract_address: eth_gate});
        gates.append(IGateDispatcher{contract_address: wbtc_gate});

        (sentinel, IShrineDispatcher{contract_address: shrine}, assets.span(), gates.span())
    }

}

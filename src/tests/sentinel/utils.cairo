pub mod sentinel_utils {
    use access_control::{IAccessControlDispatcher, IAccessControlDispatcherTrait};
    use core::integer::BoundedInt;
    use core::num::traits::Zero;
    use opus::core::roles::{sentinel_roles, shrine_roles};
    use opus::core::sentinel::sentinel as sentinel_contract;
    use opus::interfaces::IERC20::{IERC20Dispatcher, IERC20DispatcherTrait};
    use opus::interfaces::IGate::{IGateDispatcher, IGateDispatcherTrait};
    use opus::interfaces::ISentinel::{ISentinelDispatcher, ISentinelDispatcherTrait};
    use opus::interfaces::IShrine::{IShrineDispatcher, IShrineDispatcherTrait};
    use opus::tests::common;
    use opus::tests::gate::utils::gate_utils;
    use opus::tests::shrine::utils::shrine_utils;
    use opus::utils::math::pow;
    use snforge_std::{declare, ContractClass, ContractClassTrait, start_prank, stop_prank, CheatTarget};
    use starknet::{ContractAddress, get_caller_address};
    use wadray::{Wad, Ray};

    pub const ETH_ASSET_MAX: u128 = 1000000000000000000000; // 1000 (wad)
    pub const WBTC_ASSET_MAX: u128 = 100000000000; // 1000 * 10**8

    #[inline(always)]
    pub fn admin() -> ContractAddress {
        'sentinel admin'.try_into().unwrap()
    }

    #[inline(always)]
    pub fn mock_abbot() -> ContractAddress {
        'mock abbot'.try_into().unwrap()
    }

    #[inline(always)]
    pub fn dummy_yang_addr() -> ContractAddress {
        'dummy yang'.try_into().unwrap()
    }

    #[inline(always)]
    pub fn dummy_yang_gate_addr() -> ContractAddress {
        'dummy yang token'.try_into().unwrap()
    }

    //
    // Test setup
    //

    pub fn deploy_sentinel(
        sentinel_class: Option<ContractClass>, shrine_class: Option<ContractClass>,
    ) -> (ISentinelDispatcher, ContractAddress) {
        let shrine_addr: ContractAddress = shrine_utils::shrine_deploy(shrine_class);

        let calldata: Array<felt252> = array![admin().into(), shrine_addr.into()];

        let sentinel_class = match sentinel_class {
            Option::Some(class) => class,
            Option::None => declare("sentinel").unwrap()
        };

        let (sentinel_addr, _) = sentinel_class.deploy(@calldata).expect('sentinel deploy failed');

        // Grant `abbot` role to `mock_abbot`
        start_prank(CheatTarget::One(sentinel_addr), admin());
        IAccessControlDispatcher { contract_address: sentinel_addr }.grant_role(sentinel_roles::abbot(), mock_abbot());

        let shrine_ac = IAccessControlDispatcher { contract_address: shrine_addr };
        start_prank(CheatTarget::One(shrine_addr), shrine_utils::admin());

        shrine_ac.grant_role(shrine_roles::sentinel(), sentinel_addr);
        shrine_ac.grant_role(shrine_roles::abbot(), mock_abbot());

        stop_prank(CheatTarget::Multiple(array![shrine_addr, sentinel_addr]));

        (ISentinelDispatcher { contract_address: sentinel_addr }, shrine_addr)
    }

    pub fn deploy_sentinel_with_gates(
        sentinel_class: Option<ContractClass>,
        token_class: Option<ContractClass>,
        vault_class: Option<ContractClass>,
        gate_class: Option<ContractClass>,
        shrine_class: Option<ContractClass>,
    ) -> (ISentinelDispatcher, IShrineDispatcher, Span<ContractAddress>, Span<IGateDispatcher>) {
        let (sentinel, shrine_addr) = deploy_sentinel(sentinel_class, shrine_class);

        let token_class = Option::Some(
            match token_class {
                Option::Some(class) => class,
                Option::None => declare("erc20_mintable").unwrap()
            }
        );
        let vault_class = Option::Some(
            match vault_class {
                Option::Some(class) => class,
                Option::None => declare("erc4626_mintable").unwrap()
            }
        );

        let gate_class = Option::Some(
            match gate_class {
                Option::Some(class) => class,
                Option::None => declare("gate").unwrap()
            }
        );

        let (eth, eth_gate) = add_eth_yang(sentinel, shrine_addr, token_class, gate_class);
        let (wbtc, wbtc_gate) = add_wbtc_yang(sentinel, shrine_addr, token_class, gate_class);
        let (eth_lst, eth_lst_gate) = add_eth_lst_yang(sentinel, shrine_addr, vault_class, gate_class, eth);
        let (wbtc_lst, wbtc_lst_gate) = add_wbtc_lst_yang(sentinel, shrine_addr, vault_class, gate_class, wbtc);

        let mut assets: Array<ContractAddress> = array![eth, wbtc, eth_lst, wbtc_lst];
        let mut gates: Array<IGateDispatcher> = array![eth_gate, wbtc_gate, eth_lst_gate, wbtc_lst_gate];

        (sentinel, IShrineDispatcher { contract_address: shrine_addr }, assets.span(), gates.span())
    }

    pub fn deploy_sentinel_with_eth_gate(
        token_class: Option<ContractClass>
    ) -> (ISentinelDispatcher, IShrineDispatcher, ContractAddress, IGateDispatcher) {
        let (sentinel, shrine_addr) = deploy_sentinel(Option::None, Option::None);
        let (eth, eth_gate) = add_eth_yang(sentinel, shrine_addr, token_class, Option::None);

        (sentinel, IShrineDispatcher { contract_address: shrine_addr }, eth, eth_gate)
    }

    pub fn add_eth_yang(
        sentinel: ISentinelDispatcher,
        shrine_addr: ContractAddress,
        token_class: Option<ContractClass>,
        gate_class: Option<ContractClass>,
    ) -> (ContractAddress, IGateDispatcher) {
        let eth: ContractAddress = common::eth_token_deploy(token_class);

        let eth_gate: ContractAddress = gate_utils::gate_deploy(
            eth, shrine_addr, sentinel.contract_address, gate_class
        );

        let eth_erc20 = IERC20Dispatcher { contract_address: eth };
        let initial_deposit_amt: u128 = get_initial_asset_amt(eth);

        // Transferring the initial deposit amounts to `admin()`
        start_prank(CheatTarget::One(eth), common::eth_hoarder());
        eth_erc20.transfer(admin(), initial_deposit_amt.into());
        start_prank(CheatTarget::One(eth), admin());
        eth_erc20.approve(sentinel.contract_address, initial_deposit_amt.into());
        stop_prank(CheatTarget::One(eth));

        start_prank(CheatTarget::One(sentinel.contract_address), admin());

        sentinel
            .add_yang(
                eth,
                ETH_ASSET_MAX,
                shrine_utils::YANG1_THRESHOLD.into(),
                shrine_utils::YANG1_START_PRICE.into(),
                shrine_utils::YANG1_BASE_RATE.into(),
                eth_gate
            );

        stop_prank(CheatTarget::One(sentinel.contract_address));

        (eth, IGateDispatcher { contract_address: eth_gate })
    }

    pub fn add_wbtc_yang(
        sentinel: ISentinelDispatcher,
        shrine_addr: ContractAddress,
        token_class: Option<ContractClass>,
        gate_class: Option<ContractClass>,
    ) -> (ContractAddress, IGateDispatcher) {
        let wbtc: ContractAddress = common::wbtc_token_deploy(token_class);
        let wbtc_gate: ContractAddress = gate_utils::gate_deploy(
            wbtc, shrine_addr, sentinel.contract_address, gate_class
        );

        let wbtc_erc20 = IERC20Dispatcher { contract_address: wbtc };
        let initial_deposit_amt: u128 = get_initial_asset_amt(wbtc);

        // Transferring the initial deposit amounts to `admin()`
        start_prank(CheatTarget::One(wbtc), common::wbtc_hoarder());
        wbtc_erc20.transfer(admin(), initial_deposit_amt.into());
        start_prank(CheatTarget::One(wbtc), admin());
        wbtc_erc20.approve(sentinel.contract_address, initial_deposit_amt.into());
        stop_prank(CheatTarget::One(wbtc));

        start_prank(CheatTarget::One(sentinel.contract_address), admin());
        sentinel
            .add_yang(
                wbtc,
                WBTC_ASSET_MAX,
                shrine_utils::YANG2_THRESHOLD.into(),
                shrine_utils::YANG2_START_PRICE.into(),
                shrine_utils::YANG2_BASE_RATE.into(),
                wbtc_gate
            );
        stop_prank(CheatTarget::Multiple(array![sentinel.contract_address, wbtc]));

        (wbtc, IGateDispatcher { contract_address: wbtc_gate })
    }

    pub fn add_eth_lst_yang(
        sentinel: ISentinelDispatcher,
        shrine_addr: ContractAddress,
        vault_class: Option<ContractClass>,
        gate_class: Option<ContractClass>,
        eth: ContractAddress,
    ) -> (ContractAddress, IGateDispatcher) {
        let eth_lst: ContractAddress = common::eth_lst_deploy(vault_class, eth);

        let eth_lst_gate: ContractAddress = gate_utils::gate_deploy(
            eth_lst, shrine_addr, sentinel.contract_address, gate_class
        );

        let eth_lst_erc20 = IERC20Dispatcher { contract_address: eth_lst };
        let initial_deposit_amt: u128 = get_initial_asset_amt(eth_lst);

        // Transferring the initial deposit amounts to `admin()`
        start_prank(CheatTarget::One(eth_lst), common::eth_hoarder());
        eth_lst_erc20.transfer(admin(), initial_deposit_amt.into());
        start_prank(CheatTarget::One(eth_lst), admin());
        eth_lst_erc20.approve(sentinel.contract_address, initial_deposit_amt.into());
        stop_prank(CheatTarget::One(eth_lst));
        start_prank(CheatTarget::One(sentinel.contract_address), admin());

        sentinel
            .add_yang(
                eth_lst,
                // Re-use ETH parameters
                ETH_ASSET_MAX,
                shrine_utils::YANG1_THRESHOLD.into(),
                shrine_utils::YANG1_START_PRICE.into(),
                shrine_utils::YANG1_BASE_RATE.into(),
                eth_lst_gate
            );

        stop_prank(CheatTarget::One(sentinel.contract_address));

        (eth_lst, IGateDispatcher { contract_address: eth_lst_gate })
    }

    pub fn add_wbtc_lst_yang(
        sentinel: ISentinelDispatcher,
        shrine_addr: ContractAddress,
        vault_class: Option<ContractClass>,
        gate_class: Option<ContractClass>,
        wbtc: ContractAddress,
    ) -> (ContractAddress, IGateDispatcher) {
        let wbtc_lst: ContractAddress = common::wbtc_lst_deploy(vault_class, wbtc);
        let wbtc_lst_gate: ContractAddress = gate_utils::gate_deploy(
            wbtc_lst, shrine_addr, sentinel.contract_address, gate_class
        );

        let wbtc_lst_erc20 = IERC20Dispatcher { contract_address: wbtc_lst };
        let initial_deposit_amt: u128 = get_initial_asset_amt(wbtc_lst);

        // Transferring the initial deposit amounts to `admin()`
        start_prank(CheatTarget::One(wbtc_lst), common::wbtc_hoarder());
        wbtc_lst_erc20.transfer(admin(), initial_deposit_amt.into());
        start_prank(CheatTarget::One(wbtc_lst), admin());
        wbtc_lst_erc20.approve(sentinel.contract_address, initial_deposit_amt.into());
        stop_prank(CheatTarget::One(wbtc_lst));

        start_prank(CheatTarget::One(sentinel.contract_address), admin());
        sentinel
            .add_yang(
                wbtc_lst,
                // Re-use WBTC parameters
                WBTC_ASSET_MAX,
                shrine_utils::YANG2_THRESHOLD.into(),
                shrine_utils::YANG2_START_PRICE.into(),
                shrine_utils::YANG2_BASE_RATE.into(),
                wbtc_lst_gate
            );
        stop_prank(CheatTarget::Multiple(array![sentinel.contract_address, wbtc_lst]));

        (wbtc_lst, IGateDispatcher { contract_address: wbtc_lst_gate })
    }

    pub fn approve_max(gate: IGateDispatcher, token: ContractAddress, user: ContractAddress) {
        let token_erc20 = IERC20Dispatcher { contract_address: token };
        start_prank(CheatTarget::One(token), user);
        token_erc20.approve(gate.contract_address, BoundedInt::max());
        stop_prank(CheatTarget::One(token));
    }

    pub fn get_initial_asset_amt(asset_addr: ContractAddress) -> u128 {
        pow(10_u128, IERC20Dispatcher { contract_address: asset_addr }.decimals() / 2)
    }
}

pub mod sentinel_utils {
    use access_control::{IAccessControlDispatcher, IAccessControlDispatcherTrait};
    use core::num::traits::Bounded;
    use opus::core::roles::{sentinel_roles, shrine_roles};
    use opus::interfaces::IERC20::{IERC20Dispatcher, IERC20DispatcherTrait};
    use opus::interfaces::IGate::IGateDispatcher;
    use opus::interfaces::ISentinel::{ISentinelDispatcher, ISentinelDispatcherTrait};
    use opus::interfaces::IShrine::IShrineDispatcher;
    use opus::tests::common;
    use opus::tests::gate::utils::gate_utils;
    use opus::tests::shrine::utils::shrine_utils;
    use opus::utils::math::pow;
    use snforge_std::{
        ContractClass, ContractClassTrait, DeclareResultTrait, declare, start_cheat_caller_address,
        stop_cheat_caller_address,
    };
    use starknet::ContractAddress;
    use wadray::WAD_ONE;

    // Struct to group together all contract classes
    // needed for abbot tests
    #[derive(Copy, Drop)]
    pub struct SentinelTestClasses {
        pub sentinel: Option<ContractClass>,
        pub token: Option<ContractClass>,
        pub gate: Option<ContractClass>,
        pub shrine: Option<ContractClass>,
    }

    #[derive(Copy, Drop)]
    pub struct SentinelTestConfig {
        pub shrine: IShrineDispatcher,
        pub sentinel: ISentinelDispatcher,
        pub yangs: Span<ContractAddress>,
        pub gates: Span<IGateDispatcher>,
    }

    //
    // Constants
    //

    pub const ETH_ASSET_MAX: u128 = 1000 * WAD_ONE; // 1000 (wad)
    pub const WBTC_ASSET_MAX: u128 = 100000000000; // 1000 * 10**8

    pub const ADMIN: ContractAddress = 'sentinel admin'.try_into().unwrap();
    pub const MOCK_ABBOT: ContractAddress = 'mock abbot'.try_into().unwrap();
    pub const DUMMY_YANG_ADDR: ContractAddress = 'dummy yang'.try_into().unwrap();
    pub const DUMMY_YANG_GATE_ADDR: ContractAddress = 'dummy yang token'.try_into().unwrap();

    //
    // Test setup
    //

    pub fn declare_contracts() -> SentinelTestClasses {
        SentinelTestClasses {
            sentinel: Option::Some(*declare("sentinel").unwrap().contract_class()),
            token: Option::Some(common::declare_token()),
            gate: Option::Some(*declare("gate").unwrap().contract_class()),
            shrine: Option::Some(*declare("shrine").unwrap().contract_class()),
        }
    }

    pub fn deploy_sentinel(classes: Option<SentinelTestClasses>) -> (ISentinelDispatcher, ContractAddress) {
        let classes = match classes {
            Option::Some(classes) => classes,
            Option::None => declare_contracts(),
        };

        let shrine_addr: ContractAddress = shrine_utils::shrine_deploy(classes.shrine);

        let calldata: Array<felt252> = array![ADMIN.into(), shrine_addr.into()];

        let (sentinel_addr, _) = classes.sentinel.unwrap().deploy(@calldata).expect('sentinel deploy failed');

        // Grant `abbot` role to `mock_abbot`
        start_cheat_caller_address(sentinel_addr, ADMIN);
        IAccessControlDispatcher { contract_address: sentinel_addr }.grant_role(sentinel_roles::abbot(), MOCK_ABBOT);
        stop_cheat_caller_address(sentinel_addr);

        let shrine_ac = IAccessControlDispatcher { contract_address: shrine_addr };
        start_cheat_caller_address(shrine_addr, shrine_utils::ADMIN);

        shrine_ac.grant_role(shrine_roles::sentinel(), sentinel_addr);
        shrine_ac.grant_role(shrine_roles::abbot(), MOCK_ABBOT);

        stop_cheat_caller_address(shrine_addr);

        (ISentinelDispatcher { contract_address: sentinel_addr }, shrine_addr)
    }

    pub fn deploy_sentinel_with_gates(classes: Option<SentinelTestClasses>) -> SentinelTestConfig {
        let classes = match classes {
            Option::Some(classes) => classes,
            Option::None => declare_contracts(),
        };
        let (sentinel, shrine_addr) = deploy_sentinel(Option::Some(classes));

        let (eth, eth_gate) = add_eth_yang(sentinel, shrine_addr, classes.token, classes.gate);
        let (wbtc, wbtc_gate) = add_wbtc_yang(sentinel, shrine_addr, classes.token, classes.gate);

        let mut yangs: Span<ContractAddress> = array![eth, wbtc].span();
        let mut gates: Span<IGateDispatcher> = array![eth_gate, wbtc_gate].span();

        SentinelTestConfig { sentinel, shrine: IShrineDispatcher { contract_address: shrine_addr }, yangs, gates }
    }

    pub fn add_eth_vault_yang(
        sentinel: ISentinelDispatcher,
        shrine_addr: ContractAddress,
        vault_class: Option<ContractClass>,
        gate_class: ContractClass,
        eth: ContractAddress,
    ) -> (ContractAddress, IGateDispatcher) {
        let eth_vault: ContractAddress = common::eth_vault_deploy(vault_class, eth);

        let eth_vault_gate: ContractAddress = gate_utils::gate_deploy(
            eth_vault, shrine_addr, sentinel.contract_address, Option::Some(gate_class),
        );

        let eth_vault_erc20 = IERC20Dispatcher { contract_address: eth_vault };
        let initial_deposit_amt: u128 = get_initial_asset_amt(eth_vault);

        // Transferring the initial deposit amounts to `ADMIN`
        start_cheat_caller_address(eth_vault, common::ETH_HOARDER);
        eth_vault_erc20.transfer(ADMIN, initial_deposit_amt.into());
        start_cheat_caller_address(eth_vault, ADMIN);
        eth_vault_erc20.approve(sentinel.contract_address, initial_deposit_amt.into());
        stop_cheat_caller_address(eth_vault);
        start_cheat_caller_address(sentinel.contract_address, ADMIN);

        sentinel
            .add_yang(
                eth_vault,
                // Re-use ETH parameters
                ETH_ASSET_MAX,
                shrine_utils::YANG1_THRESHOLD.into(),
                shrine_utils::YANG1_START_PRICE.into(),
                shrine_utils::YANG1_BASE_RATE.into(),
                eth_vault_gate,
            );

        stop_cheat_caller_address(sentinel.contract_address);

        (eth_vault, IGateDispatcher { contract_address: eth_vault_gate })
    }

    pub fn add_wbtc_vault_yang(
        sentinel: ISentinelDispatcher,
        shrine_addr: ContractAddress,
        vault_class: Option<ContractClass>,
        gate_class: ContractClass,
        wbtc: ContractAddress,
    ) -> (ContractAddress, IGateDispatcher) {
        let wbtc_vault: ContractAddress = common::wbtc_vault_deploy(vault_class, wbtc);
        let wbtc_vault_gate: ContractAddress = gate_utils::gate_deploy(
            wbtc_vault, shrine_addr, sentinel.contract_address, Option::Some(gate_class),
        );

        let wbtc_vault_erc20 = IERC20Dispatcher { contract_address: wbtc_vault };
        let initial_deposit_amt: u128 = get_initial_asset_amt(wbtc_vault);

        // Transferring the initial deposit amounts to `ADMIN`
        start_cheat_caller_address(wbtc_vault, common::WBTC_HOARDER);
        wbtc_vault_erc20.transfer(ADMIN, initial_deposit_amt.into());
        start_cheat_caller_address(wbtc_vault, ADMIN);
        wbtc_vault_erc20.approve(sentinel.contract_address, initial_deposit_amt.into());
        stop_cheat_caller_address(wbtc_vault);

        start_cheat_caller_address(sentinel.contract_address, ADMIN);
        sentinel
            .add_yang(
                wbtc_vault,
                // Re-use WBTC parameters
                WBTC_ASSET_MAX,
                shrine_utils::YANG2_THRESHOLD.into(),
                shrine_utils::YANG2_START_PRICE.into(),
                shrine_utils::YANG2_BASE_RATE.into(),
                wbtc_vault_gate,
            );
        stop_cheat_caller_address(sentinel.contract_address);

        (wbtc_vault, IGateDispatcher { contract_address: wbtc_vault_gate })
    }

    pub fn add_vaults_to_sentinel(
        shrine: IShrineDispatcher,
        sentinel: ISentinelDispatcher,
        gate_class: ContractClass,
        vault_class: Option<ContractClass>,
        eth: ContractAddress,
        wbtc: ContractAddress,
    ) -> (Span<ContractAddress>, Span<IGateDispatcher>) {
        let vault_class = Option::Some(
            match vault_class {
                Option::Some(class) => class,
                Option::None => *declare("erc4626_mintable").unwrap().contract_class(),
            },
        );

        let (eth_vault, eth_vault_gate) = add_eth_vault_yang(
            sentinel, shrine.contract_address, vault_class, gate_class, eth,
        );
        let (wbtc_vault, wbtc_vault_gate) = add_wbtc_vault_yang(
            sentinel, shrine.contract_address, vault_class, gate_class, wbtc,
        );

        let vaults: Span<ContractAddress> = array![eth_vault, wbtc_vault].span();
        let gates: Span<IGateDispatcher> = array![eth_vault_gate, wbtc_vault_gate].span();

        (vaults, gates)
    }

    pub fn deploy_sentinel_with_eth_gate(classes: Option<SentinelTestClasses>) -> SentinelTestConfig {
        let classes = match classes {
            Option::Some(classes) => classes,
            Option::None => declare_contracts(),
        };

        let (sentinel, shrine_addr) = deploy_sentinel(Option::Some(classes));
        let (eth, eth_gate) = add_eth_yang(sentinel, shrine_addr, classes.token, classes.gate);

        SentinelTestConfig {
            sentinel,
            shrine: IShrineDispatcher { contract_address: shrine_addr },
            yangs: array![eth].span(),
            gates: array![eth_gate].span(),
        }
    }

    pub fn add_eth_yang(
        sentinel: ISentinelDispatcher,
        shrine_addr: ContractAddress,
        token_class: Option<ContractClass>,
        gate_class: Option<ContractClass>,
    ) -> (ContractAddress, IGateDispatcher) {
        let eth: ContractAddress = common::eth_token_deploy(token_class);

        let eth_gate: ContractAddress = gate_utils::gate_deploy(
            eth, shrine_addr, sentinel.contract_address, gate_class,
        );

        let eth_erc20 = IERC20Dispatcher { contract_address: eth };
        let initial_deposit_amt: u128 = get_initial_asset_amt(eth);

        // Transferring the initial deposit amounts to `ADMIN`
        start_cheat_caller_address(eth, common::ETH_HOARDER);
        eth_erc20.transfer(ADMIN, initial_deposit_amt.into());
        start_cheat_caller_address(eth, ADMIN);
        eth_erc20.approve(sentinel.contract_address, initial_deposit_amt.into());
        stop_cheat_caller_address(eth);

        start_cheat_caller_address(sentinel.contract_address, ADMIN);

        sentinel
            .add_yang(
                eth,
                ETH_ASSET_MAX,
                shrine_utils::YANG1_THRESHOLD.into(),
                shrine_utils::YANG1_START_PRICE.into(),
                shrine_utils::YANG1_BASE_RATE.into(),
                eth_gate,
            );

        stop_cheat_caller_address(sentinel.contract_address);

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
            wbtc, shrine_addr, sentinel.contract_address, gate_class,
        );

        let wbtc_erc20 = IERC20Dispatcher { contract_address: wbtc };
        let initial_deposit_amt: u128 = get_initial_asset_amt(wbtc);

        // Transferring the initial deposit amounts to `ADMIN`
        start_cheat_caller_address(wbtc, common::WBTC_HOARDER);
        wbtc_erc20.transfer(ADMIN, initial_deposit_amt.into());
        start_cheat_caller_address(wbtc, ADMIN);
        wbtc_erc20.approve(sentinel.contract_address, initial_deposit_amt.into());
        stop_cheat_caller_address(wbtc);

        start_cheat_caller_address(sentinel.contract_address, ADMIN);
        sentinel
            .add_yang(
                wbtc,
                WBTC_ASSET_MAX,
                shrine_utils::YANG2_THRESHOLD.into(),
                shrine_utils::YANG2_START_PRICE.into(),
                shrine_utils::YANG2_BASE_RATE.into(),
                wbtc_gate,
            );
        stop_cheat_caller_address(sentinel.contract_address);

        (wbtc, IGateDispatcher { contract_address: wbtc_gate })
    }

    pub fn approve_max(gate: IGateDispatcher, token: ContractAddress, user: ContractAddress) {
        let token_erc20 = IERC20Dispatcher { contract_address: token };
        start_cheat_caller_address(token, user);
        token_erc20.approve(gate.contract_address, Bounded::MAX);
        stop_cheat_caller_address(token);
    }

    pub fn get_initial_asset_amt(asset_addr: ContractAddress) -> u128 {
        pow(10_u128, IERC20Dispatcher { contract_address: asset_addr }.decimals() / 2)
    }
}

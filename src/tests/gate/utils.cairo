pub mod gate_utils {
    use core::num::traits::{Bounded, Zero};
    use opus::core::gate::gate as gate_contract;
    use opus::interfaces::IERC20::{
        IERC20Dispatcher, IERC20DispatcherTrait, IMintableDispatcher, IMintableDispatcherTrait
    };
    use opus::interfaces::IShrine::{IShrineDispatcher, IShrineDispatcherTrait};
    use opus::tests::common;
    use opus::tests::shrine::utils::shrine_utils;
    use snforge_std::{declare, ContractClass, ContractClassTrait, start_prank, stop_prank, start_warp, CheatTarget};
    use starknet::ContractAddress;
    use wadray::{Ray, Wad};

    //
    // Address constants
    //

    pub fn mock_sentinel() -> ContractAddress {
        'mock sentinel'.try_into().unwrap()
    }

    //
    // Test setup helpers
    //

    pub fn gate_deploy(
        token: ContractAddress, shrine: ContractAddress, sentinel: ContractAddress, gate_class: Option<ContractClass>,
    ) -> ContractAddress {
        start_warp(CheatTarget::All, shrine_utils::DEPLOYMENT_TIMESTAMP);

        let calldata: Array<felt252> = array![shrine.into(), token.into(), sentinel.into()];

        let gate_class = match gate_class {
            Option::Some(class) => class,
            Option::None => declare("gate").unwrap(),
        };
        let (gate_addr, _) = gate_class.deploy(@calldata).expect('gate deploy failed');
        gate_addr
    }

    pub fn eth_gate_deploy(token_class: Option<ContractClass>) -> (ContractAddress, ContractAddress, ContractAddress) {
        let shrine = shrine_utils::shrine_deploy(Option::None);
        let eth: ContractAddress = common::eth_token_deploy(token_class);
        let gate: ContractAddress = gate_deploy(eth, shrine, mock_sentinel(), Option::None);
        (shrine, eth, gate)
    }

    pub fn wbtc_gate_deploy(token_class: Option<ContractClass>) -> (ContractAddress, ContractAddress, ContractAddress) {
        let shrine = shrine_utils::shrine_deploy(Option::None);
        let wbtc: ContractAddress = common::wbtc_token_deploy(token_class);
        let gate: ContractAddress = gate_deploy(wbtc, shrine, mock_sentinel(), Option::None);
        (shrine, wbtc, gate)
    }

    pub fn add_eth_as_yang(shrine: ContractAddress, eth: ContractAddress) {
        start_prank(CheatTarget::One(shrine), shrine_utils::admin());
        let shrine = IShrineDispatcher { contract_address: shrine };
        shrine
            .add_yang(
                eth,
                shrine_utils::YANG1_THRESHOLD.into(),
                shrine_utils::YANG1_START_PRICE.into(),
                shrine_utils::YANG1_BASE_RATE.into(),
                Zero::zero() // initial amount
            );
        shrine.set_debt_ceiling(shrine_utils::DEBT_CEILING.into());
        stop_prank(CheatTarget::One(shrine.contract_address));
    }

    pub fn add_wbtc_as_yang(shrine: ContractAddress, wbtc: ContractAddress) {
        start_prank(CheatTarget::One(shrine), shrine_utils::admin());
        let shrine = IShrineDispatcher { contract_address: shrine };
        shrine
            .add_yang(
                wbtc,
                shrine_utils::YANG2_THRESHOLD.into(),
                shrine_utils::YANG2_START_PRICE.into(),
                shrine_utils::YANG2_BASE_RATE.into(),
                Zero::zero() // initial amount
            );
        shrine.set_debt_ceiling(shrine_utils::DEBT_CEILING.into());
        stop_prank(CheatTarget::One(shrine.contract_address));
    }

    pub fn approve_gate_for_token(gate: ContractAddress, token: ContractAddress, user: ContractAddress) {
        // user no-limit approves gate to handle their share of token
        start_prank(CheatTarget::One(token), user);
        IERC20Dispatcher { contract_address: token }.approve(gate, Bounded::MAX());
        stop_prank(CheatTarget::One(token));
    }

    pub fn rebase(gate: ContractAddress, token: ContractAddress, amount: u128) {
        IMintableDispatcher { contract_address: token }.mint(gate, amount.into());
    }
}

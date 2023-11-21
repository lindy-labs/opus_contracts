mod fuzz {
    use opus::interfaces::IAbbot::{
        IAbbotDispatcher, IAbbotSafeDispatcher, IAbbotSafeDispatcherTrait
    };
    use opus::interfaces::IAbsorber::{
        IAbsorberDispatcher, IAbsorberSafeDispatcher, IAbsorberSafeDispatcherTrait
    };
    use opus::interfaces::IERC20::{
        IERC20Dispatcher, IERC20SafeDispatcher, IERC20SafeDispatcherTrait
    };
    use opus::interfaces::IGate::{IGateDispatcher, IGateSafeDispatcher, IGateSafeDispatcherTrait};
    use opus::interfaces::IPurger::{
        IPurgerDispatcher, IPurgerSafeDispatcher, IPurgerSafeDispatcherTrait
    };
    use opus::interfaces::ISentinel::{
        ISentinelDispatcher, ISentinelSafeDispatcher, ISentinelSafeDispatcherTrait
    };
    use opus::interfaces::IShrine::{
        IShrineDispatcher, IShrineSafeDispatcher, IShrineSafeDispatcherTrait
    };

    use opus::tests::abbot::utils::abbot_utils;
    use opus::tests::absorber::utils::absorber_utils;
    use opus::tests::common;
    use opus::tests::purger::utils::purger_utils;
    use opus::tests::shrine::utils::shrine_utils;

    use opus::utils::access_control::{
        IAccessControlDispatcher, IAccessControlSafeDispatcher, IAccessControlSafeDispatcherTrait
    };

    use starknet::ContractAddress;
    #[test]
    #[available_gas(20000000000)]
    fn fuzzing_campaign() {
        let (shrine, abbot, mock_pragma, absorber, purger, yangs, gates) =
            purger_utils::purger_deploy_with_searcher(
            purger_utils::SEARCHER_YIN.into(),
        );

        let shrine = IShrineSafeDispatcher { contract_address: shrine.contract_address };
        let abbot = IAbbotSafeDispatcher { contract_address: abbot.contract_address };
        let pragma = IAccessControlSafeDispatcher {
            contract_address: mock_pragma.contract_address
        };
        let absorber = IAbsorberSafeDispatcher { contract_address: absorber.contract_address };
        let purger = IPurgerSafeDispatcher { contract_address: purger.contract_address };

        let eth_gate: IGateDispatcher = *gates[0];
        let wbtc_gate: IGateDispatcher = *gates[1];

        let gates = array![
            IGateSafeDispatcher { contract_address: eth_gate.contract_address },
            IGateSafeDispatcher { contract_address: wbtc_gate.contract_address },
        ];

        let user1 = common::trove1_owner_addr();
        let user2 = common::trove2_owner_addr();

        common::fund_user(user1, yangs, purger_utils::target_trove_yang_asset_amts());
        common::fund_user(user2, yangs, purger_utils::target_trove_yang_asset_amts());

        assert_invariants(shrine, abbot, yangs);
    }

    fn assert_invariants(
        shrine: IShrineSafeDispatcher, abbot: IAbbotSafeDispatcher, yangs: Span<ContractAddress>,
    ) {
        shrine_utils::assert_shrine_invariants(
            IShrineDispatcher { contract_address: shrine.contract_address },
            yangs,
            abbot.get_troves_count().unwrap()
        );
    }
}

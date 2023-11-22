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
    use opus::types::AssetBalance;

    use opus::utils::access_control::{
        IAccessControlDispatcher, IAccessControlSafeDispatcher, IAccessControlSafeDispatcherTrait
    };
    use opus::utils::wadray::{Ray, Wad};

    use starknet::testing::{set_block_timestamp, set_contract_address};

    use starknet::{ContractAddress, get_block_timestamp};

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

        set_contract_address(user1);
        abbot.deposit(8, AssetBalance { address: *yangs[0], amount: 331955550813133627 });
        assert_invariants(shrine, abbot, yangs);

        set_block_timestamp(get_block_timestamp() + 3600);
        abbot
            .open_trove(
                array![
                    AssetBalance { address: *yangs[1], amount: 1044996653224483852 },
                    AssetBalance { address: *yangs[1], amount: 462648745412039086 }
                ]
                    .span(),
                Wad { val: 574550319480417391051767027448 },
                Wad { val: 717740852391894544 }
            );
        assert_invariants(shrine, abbot, yangs);

        set_block_timestamp(get_block_timestamp() + 3600);
        set_contract_address(user2);
        abbot
            .open_trove(
                array![
                    AssetBalance { address: *yangs[1], amount: 774294406890491273 },
                    AssetBalance { address: *yangs[0], amount: 1456973789062934600 }
                ]
                    .span(),
                Wad { val: 451731573798775852060757569013 },
                Wad { val: 287739722362938164 }
            );
        assert_invariants(shrine, abbot, yangs);

        set_block_timestamp(get_block_timestamp() + 3600);
        set_contract_address(user1);
        abbot.deposit(7, AssetBalance { address: *yangs[0], amount: 142608228747038148 });
        assert_invariants(shrine, abbot, yangs);

        set_block_timestamp(get_block_timestamp() + 3600);
        abbot.deposit(4, AssetBalance { address: *yangs[0], amount: 917238898427541743 });
        assert_invariants(shrine, abbot, yangs);

        set_block_timestamp(get_block_timestamp() + 3600);
        abbot.withdraw(9, AssetBalance { address: *yangs[0], amount: 779590449452831179 });
        assert_invariants(shrine, abbot, yangs);

        set_block_timestamp(get_block_timestamp() + 3600);
        abbot
            .forge(3, Wad { val: 865451114297147075575351591971 }, Wad { val: 501589541395096680 });
        assert_invariants(shrine, abbot, yangs);

        set_block_timestamp(get_block_timestamp() + 3600);
        abbot
            .open_trove(
                array![
                    AssetBalance { address: *yangs[0], amount: 1396992449521076539 },
                    AssetBalance { address: *yangs[0], amount: 764034552269721698 }
                ]
                    .span(),
                Wad { val: 817559736880364145841815956593 },
                Wad { val: 508390472343773353 }
            );
        assert_invariants(shrine, abbot, yangs);

        set_block_timestamp(get_block_timestamp() + 3600);
        abbot
            .open_trove(
                array![
                    AssetBalance { address: *yangs[1], amount: 1765429812522296057 },
                    AssetBalance { address: *yangs[0], amount: 1668741286731481643 }
                ]
                    .span(),
                Wad { val: 410205581059791580375992112845 },
                Wad { val: 45333889111493840 }
            );
        assert_invariants(shrine, abbot, yangs);

        set_block_timestamp(get_block_timestamp() + 3600);
        abbot
            .forge(4, Wad { val: 477233379604830295700109229421 }, Wad { val: 276367226643940054 });
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

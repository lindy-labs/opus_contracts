mod test_controller {
    use core::num::traits::Zero;
    use opus::core::controller::controller as controller_contract;
    use opus::interfaces::IController::IControllerDispatcherTrait;
    use opus::interfaces::IShrine::IShrineDispatcherTrait;
    use opus::tests::common;
    use opus::tests::controller::utils::controller_utils;
    use opus::tests::controller::utils::controller_utils::ControllerTestConfig;
    use snforge_std::{
        EventSpyAssertionsTrait, spy_events, start_cheat_block_timestamp_global, start_cheat_caller_address,
    };
    use starknet::get_block_timestamp;
    use wadray::{Ray, SignedRay, Wad};

    const YIN_PRICE1: u128 = 999942800000000000; // wad
    const YIN_PRICE2: u128 = 999879000000000000; // wad

    const ERROR_MARGIN: u128 = 1000000000000000; // 10^-12 (ray)

    #[test]
    fn test_deploy_controller() {
        let mut spy = spy_events();
        let ControllerTestConfig { controller, .. } = controller_utils::deploy_controller();

        let ((p_gain, i_gain), (alpha_p, beta_p, alpha_i, beta_i)) = controller.get_parameters();
        assert(p_gain == controller_utils::P_GAIN.into(), 'wrong p gain');
        assert(i_gain == controller_utils::I_GAIN.into(), 'wrong i gain');
        assert(alpha_p == controller_utils::ALPHA_P, 'wrong alpha_p');
        assert(alpha_i == controller_utils::ALPHA_I, 'wrong alpha_i');
        assert(beta_p == controller_utils::BETA_P, 'wrong beta_p');
        assert(beta_i == controller_utils::BETA_I, 'wrong beta_i');
        let expected_events = array![
            (
                controller.contract_address,
                controller_contract::Event::GainUpdated(
                    controller_contract::GainUpdated { name: 'p_gain', value: controller_utils::P_GAIN.into() },
                ),
            ),
            (
                controller.contract_address,
                controller_contract::Event::GainUpdated(
                    controller_contract::GainUpdated { name: 'i_gain', value: controller_utils::I_GAIN.into() },
                ),
            ),
            (
                controller.contract_address,
                controller_contract::Event::ParameterUpdated(
                    controller_contract::ParameterUpdated { name: 'alpha_p', value: controller_utils::ALPHA_P },
                ),
            ),
            (
                controller.contract_address,
                controller_contract::Event::ParameterUpdated(
                    controller_contract::ParameterUpdated { name: 'alpha_i', value: controller_utils::ALPHA_I },
                ),
            ),
            (
                controller.contract_address,
                controller_contract::Event::ParameterUpdated(
                    controller_contract::ParameterUpdated { name: 'beta_p', value: controller_utils::BETA_P },
                ),
            ),
            (
                controller.contract_address,
                controller_contract::Event::ParameterUpdated(
                    controller_contract::ParameterUpdated { name: 'beta_i', value: controller_utils::BETA_I },
                ),
            ),
        ];
        spy.assert_emitted(@expected_events);
    }

    #[test]
    fn test_setters() {
        let ControllerTestConfig { controller, .. } = controller_utils::deploy_controller();
        let mut spy = spy_events();

        start_cheat_caller_address(controller.contract_address, controller_utils::ADMIN);

        let new_p_gain: Ray = 1_u128.into();
        let new_i_gain: Ray = 2_u128.into();
        let new_alpha_p: u8 = 3;
        let new_alpha_i: u8 = 5;
        let new_beta_p: u8 = 8;
        let new_beta_i: u8 = 4;

        controller.set_p_gain(new_p_gain);
        controller.set_i_gain(new_i_gain);
        controller.set_alpha_p(new_alpha_p);
        controller.set_alpha_i(new_alpha_i);
        controller.set_beta_p(new_beta_p);
        controller.set_beta_i(new_beta_i);

        let ((p_gain, i_gain), (alpha_p, beta_p, alpha_i, beta_i)) = controller.get_parameters();
        assert(p_gain == new_p_gain.into(), 'wrong p gain');
        assert(i_gain == new_i_gain.into(), 'wrong i gain');
        assert(alpha_p == new_alpha_p, 'wrong alpha_p');
        assert(alpha_i == new_alpha_i, 'wrong alpha_i');
        assert(beta_p == new_beta_p, 'wrong beta_p');
        assert(beta_i == new_beta_i, 'wrong beta_i');
        let expected_events = array![
            (
                controller.contract_address,
                controller_contract::Event::GainUpdated(
                    controller_contract::GainUpdated { name: 'p_gain', value: new_p_gain },
                ),
            ),
            (
                controller.contract_address,
                controller_contract::Event::GainUpdated(
                    controller_contract::GainUpdated { name: 'i_gain', value: new_i_gain },
                ),
            ),
            (
                controller.contract_address,
                controller_contract::Event::ParameterUpdated(
                    controller_contract::ParameterUpdated { name: 'alpha_p', value: new_alpha_p },
                ),
            ),
            (
                controller.contract_address,
                controller_contract::Event::ParameterUpdated(
                    controller_contract::ParameterUpdated { name: 'alpha_i', value: new_alpha_i },
                ),
            ),
            (
                controller.contract_address,
                controller_contract::Event::ParameterUpdated(
                    controller_contract::ParameterUpdated { name: 'beta_p', value: new_beta_p },
                ),
            ),
            (
                controller.contract_address,
                controller_contract::Event::ParameterUpdated(
                    controller_contract::ParameterUpdated { name: 'beta_i', value: new_beta_i },
                ),
            ),
        ];
        spy.assert_emitted(@expected_events);
    }

    // Testing unauthorized calls of setters

    #[test]
    #[should_panic(expected: 'Caller missing role')]
    fn test_set_p_gain_unauthorized() {
        let ControllerTestConfig { controller, .. } = controller_utils::deploy_controller();
        start_cheat_caller_address(controller.contract_address, common::BAD_GUY);
        controller.set_p_gain(1_u128.into());
    }

    #[test]
    #[should_panic(expected: 'Caller missing role')]
    fn test_set_i_gain_unauthorized() {
        let ControllerTestConfig { controller, .. } = controller_utils::deploy_controller();
        start_cheat_caller_address(controller.contract_address, common::BAD_GUY);
        controller.set_i_gain(1_u128.into());
    }

    #[test]
    #[should_panic(expected: 'Caller missing role')]
    fn test_set_alpha_p_unauthorized() {
        let ControllerTestConfig { controller, .. } = controller_utils::deploy_controller();
        start_cheat_caller_address(controller.contract_address, common::BAD_GUY);
        controller.set_alpha_p(1);
    }

    #[test]
    #[should_panic(expected: 'Caller missing role')]
    fn test_set_alpha_i_unauthorized() {
        let ControllerTestConfig { controller, .. } = controller_utils::deploy_controller();
        start_cheat_caller_address(controller.contract_address, common::BAD_GUY);
        controller.set_alpha_i(1);
    }

    #[test]
    #[should_panic(expected: 'Caller missing role')]
    fn test_set_beta_p_unauthorized() {
        let ControllerTestConfig { controller, .. } = controller_utils::deploy_controller();
        start_cheat_caller_address(controller.contract_address, common::BAD_GUY);
        controller.set_beta_p(1);
    }

    #[test]
    #[should_panic(expected: 'Caller missing role')]
    fn test_set_beta_i_unauthorized() {
        let ControllerTestConfig { controller, .. } = controller_utils::deploy_controller();
        start_cheat_caller_address(controller.contract_address, common::BAD_GUY);
        controller.set_beta_i(1);
    }

    #[test]
    fn test_against_ground_truth1() {
        let ControllerTestConfig { controller, shrine } = controller_utils::deploy_controller();

        start_cheat_caller_address(controller.contract_address, controller_utils::ADMIN);

        // Updating `i_gain` to match the ground truth simulation
        controller.set_i_gain(100000000000000000000000_u128.into());

        assert(controller.get_p_term() == Zero::zero(), 'Wrong p term #1');
        assert(controller.get_i_term() == Zero::zero(), 'Wrong i term #1');

        controller_utils::fast_forward_1_hour();
        controller_utils::set_yin_spot_price(shrine, YIN_PRICE1.into());

        let expected_p_term: SignedRay = 18715000000000000_u128.into();
        common::assert_equalish(controller.get_p_term(), expected_p_term, ERROR_MARGIN.into(), 'Wrong p term #2');

        let expected_i_term = Zero::zero();
        common::assert_equalish(controller.get_i_term(), expected_i_term, ERROR_MARGIN.into(), 'Wrong i term #2');

        controller.update_multiplier();

        controller_utils::fast_forward_1_hour();
        controller_utils::set_yin_spot_price(shrine, YIN_PRICE2.into());

        let expected_p_term: SignedRay = 177156100000166000_u128.into();
        common::assert_equalish(controller.get_p_term(), expected_p_term, ERROR_MARGIN.into(), 'Wrong p term #3');
        let expected_i_term: SignedRay = 5719999990640490000_u128.into();
        common::assert_equalish(controller.get_i_term(), expected_i_term, ERROR_MARGIN.into(), 'Wrong i term #3');
    }

    #[test]
    fn test_against_ground_truth2() {
        let ControllerTestConfig { controller, shrine } = controller_utils::deploy_controller();

        start_cheat_caller_address(controller.contract_address, controller_utils::ADMIN);

        // Updating `i_gain` to match the ground truth simulation
        controller.set_i_gain(100000000000000000000000000_u128.into()); // 0.1 (ray)
        controller.set_p_gain((1000000_u128 * wadray::RAY_ONE).into()); // 1,000,000 (ray)

        // Loading our ground truth into arrays for comparison
        let mut prices: Array<Wad> = array![
            990099009900990000_u128.into(),
            990366354678218000_u128.into(),
            990633735544555000_u128.into(),
            991196767996938000_u128.into(),
            991739556883818000_u128.into(),
            992242243614704000_u128.into(),
            992706195040200000_u128.into(),
            993142884628952000_u128.into(),
            993559692099288000_u128.into(),
            993955814200459000_u128.into(),
            994335056474406000_u128.into(),
            994700440013533000_u128.into(),
            995054185977344000_u128.into(),
            995399740716883000_u128.into(),
            995734834696816000_u128.into(),
            996062810539847000_u128.into(),
            996387925979872000_u128.into(),
            996705233546627000_u128.into(),
            997020242930630000_u128.into(),
            997330674543210000_u128.into(),
            997643112355959000_u128.into(),
            997949115908752000_u128.into(),
            998251035541544000_u128.into(),
            998558656038350000_u128.into(),
            998864120192415000_u128.into(),
            999166007648390000_u128.into(),
            999469499623981000_u128.into(),
            999772517479079000_u128.into(),
            1000076906317690000_u128.into(),
            999783572518900000_u128.into(),
            1000082233643610000_u128.into(),
            999782291432283000_u128.into(),
            1000084418040440000_u128.into(),
            999774651681536000_u128.into(),
            1000076306582700000_u128.into(),
            999765562823952000_u128.into(),
            1000067478586280000_u128.into(),
            999773019374451000_u128.into(),
            1000075753295850000_u128.into(),
            999771699502100000_u128.into(),
            1000074531257950000_u128.into(),
            999772965087390000_u128.into(),
            1000072685712120000_u128.into(),
            999769822334539000_u128.into(),
            1000073416183750000_u128.into(),
            999773295592982000_u128.into(),
            1000074746794400000_u128.into(),
            999770911209658000_u128.into(),
            1000070231385980000_u128.into(),
            999765417689028000_u128.into(),
            1000069974303700000_u128.into(),
        ];

        let mut expected_p_terms_for_update: Array<SignedRay> = array![
            970590147927674000000000000_u128.into(),
            894070898474171000000000000_u128.into(),
            821673437507823000000000000_u128.into(),
            682223134755399000000000000_u128.into(),
            563650679126548000000000000_u128.into(),
            466883377897327000000000000_u128.into(),
            388027439175130000000000000_u128.into(),
            322421778770012000000000000_u128.into(),
            267128295084519000000000000_u128.into(),
            220807295545977000000000000_u128.into(),
            181797017511170000000000000_u128.into(),
            148839923137911000000000000_u128.into(),
            120979934404774000000000000_u128.into(),
            97352460220028900000000000_u128.into(),
            77590330680959900000000000_u128.into(),
            61032188256458100000000000_u128.into(),
            47127014107940200000000000_u128.into(),
            35766291049451300000000000_u128.into(),
            26457120564083400000000000_u128.into(),
            19019740391042100000000000_u128.into(),
            13092320818861100000000000_u128.into(),
            8626275988046590000000000_u128.into(),
            5349866590772710000000000_u128.into(),
            2994352321986510000000000_u128.into(),
            1465538181738630000000000_u128.into(),
            580077744495632000000000_u128.into(),
            149299065094574000000000_u128.into(),
            11771833128759300000000_u128.into(),
            -(454868699272035000000_u128.into()),
            10137648168311100000000_u128.into(),
            -(556094500630732000000_u128.into()),
            10318737437826600000000_u128.into(),
            -(601597192058065000000_u128.into()),
            11443607803861600000000_u128.into(),
            -(444309924236667000000_u128.into()),
            12884852286878500000000_u128.into(),
            -(307254269060489000000_u128.into()),
            11694088217369400000000_u128.into(),
            -(434714972222878000000_u128.into()),
            11899277040145300000000_u128.into(),
            -(414014311714013000000_u128.into()),
            11702480865749300000000_u128.into(),
            -(384014080753663000000_u128.into()),
            12195217294123800000000_u128.into(),
            -(395708534452025000000_u128.into()),
            11651447644382300000000_u128.into(),
            -(417616564708359000000_u128.into()),
            12022963179793800000000_u128.into(),
            -(346412629582555000000_u128.into()),
            12908797294632500000000_u128.into(),
            -(342622403036553000000_u128.into()),
        ];

        let mut expected_i_terms_for_update: Array<SignedRay> = array![
            0_u128.into(),
            990050483961308000000000_u128.into(),
            963319831744643000000000_u128.into(),
            936585364575532000000000_u128.into(),
            880289091131965000000000_u128.into(),
            826016130526438000000000_u128.into(),
            775752295414337000000000_u128.into(),
            729361095382119000000000_u128.into(),
            685695416584344000000000_u128.into(),
            644017434071918000000000_u128.into(),
            604407539891812000000000_u128.into(),
            566485262927299000000000_u128.into(),
            529948556807289000000000_u128.into(),
            494575353379855000000000_u128.into(),
            460021060765948000000000_u128.into(),
            426512650854796000000000_u128.into(),
            393715894441363000000000_u128.into(),
            361205045685150000000000_u128.into(),
            329474857037308000000000_u128.into(),
            297974384089785000000000_u128.into(),
            266931594697062000000000_u128.into(),
            235688109790782000000000_u128.into(),
            205087977812360000000000_u128.into(),
            174896178352891000000000_u128.into(),
            144134246447625000000000_u128.into(),
            113587907481662000000000_u128.into(),
            83399206157124800000000_u128.into(),
            53050030136946600000000_u128.into(),
            22748251503505800000000_u128.into(),
            -(7690631746253880000000_u128.into()),
            21642747603124400000000_u128.into(),
            -(8223364333188300000000_u128.into()),
            21770856255759900000000_u128.into(),
            -(8441804013921670000000_u128.into()),
            22534831274218800000000_u128.into(),
            -(7630658247792590000000_u128.into()),
            23443716960556000000000_u128.into(),
            -(6747858612635160000000_u128.into()),
            22698061970200100000000_u128.into(),
            -(7575329563260990000000_u128.into()),
            22830049195037500000000_u128.into(),
            -(7453125774297640000000_u128.into()),
            22703490675876200000000_u128.into(),
            -(7268571192803940000000_u128.into()),
            23017765936335400000000_u128.into(),
            -(7341618355226480000000_u128.into()),
            22670440119227300000000_u128.into(),
            -(7474679419119640000000_u128.into()),
            22908878433052100000000_u128.into(),
            -(7023138580674010000000_u128.into()),
            23458230451766600000000_u128.into(),
        ];

        let mut expected_multipliers: Array<Ray> = array![
            1970590147927670000000000000_u128.into(),
            1895060948958132000000000000_u128.into(),
            1823626807823529000000000000_u128.into(),
            1684123039951719000000000000_u128.into(),
            1565467553582256000000000000_u128.into(),
            1468589683118985000000000000_u128.into(),
            1389629207601071000000000000_u128.into(),
            1323926892160809000000000000_u128.into(),
            1268543351596485000000000000_u128.into(),
            1222137008396633000000000000_u128.into(),
            1183045442485134000000000000_u128.into(),
            1150010815940730000000000000_u128.into(),
            1122076368224509000000000000_u128.into(),
            1098376984130216100000000000_u128.into(),
            1078544927095105700000000000_u128.into(),
            1061918721968078900000000000_u128.into(),
            1047947242653236300000000000_u128.into(),
            1036521211989577800000000000_u128.into(),
            1027147800466805900000000000_u128.into(),
            1019647189632169200000000000_u128.into(),
            1013657226797647900000000000_u128.into(),
            1009128895692534440000000000_u128.into(),
            1005790642678375850000000000_u128.into(),
            1003374336478151760000000000_u128.into(),
            1001784568606539140000000000_u128.into(),
            1000837799898424919000000000_u128.into(),
            1000346286178733361000000000_u128.into(),
            1000148221069422831000000000_u128.into(),
            1000075343412941180400000000_u128.into(),
            1000025195267925563000000000_u128.into(),
            1000013396021356239800000000_u128.into(),
            1000023738120707762700000000_u128.into(),
            1000012945894730513600000000_u128.into(),
            1000024772660045699800000000_u128.into(),
            1000013648717336060500000000_u128.into(),
            1000027789025313304700000000_u128.into(),
            1000015505804443702900000000_u128.into(),
            1000028389946565290300000000_u128.into(),
            1000015515488385342100000000_u128.into(),
            1000027022009447084400000000_u128.into(),
            1000014840705320062500000000_u128.into(),
            1000027079404286489200000000_u128.into(),
            1000014866350820824900000000_u128.into(),
            1000027630136777196100000000_u128.into(),
            1000015353486209079400000000_u128.into(),
            1000027327595225491200000000_u128.into(),
            1000014911205199292500000000_u128.into(),
            1000027218723879901500000000_u128.into(),
            1000015087786384349900000000_u128.into(),
            1000028794537147010600000000_u128.into(),
            1000016092469468056100000000_u128.into(),
        ];

        for price in prices {
            controller_utils::fast_forward_1_hour();
            controller_utils::set_yin_spot_price(shrine, price);

            let i_term: SignedRay = controller.get_i_term();
            let expected_i_term_for_update: SignedRay = expected_i_terms_for_update.pop_front().unwrap();
            common::assert_equalish(i_term, expected_i_term_for_update, ERROR_MARGIN.into(), 'Wrong i term');

            let p_term: SignedRay = controller.get_p_term();
            let expected_p_term_for_update: SignedRay = expected_p_terms_for_update.pop_front().unwrap();
            common::assert_equalish(p_term, expected_p_term_for_update, ERROR_MARGIN.into(), 'Wrong p term');

            let multiplier: Ray = controller.get_current_multiplier();
            let expected_multiplier: Ray = expected_multipliers.pop_front().unwrap();
            common::assert_equalish(multiplier, expected_multiplier, ERROR_MARGIN.into(), 'Wrong multiplier');

            controller.update_multiplier();

            let (shrine_multiplier, _, _) = shrine.get_current_multiplier();
            assert_eq!(multiplier, shrine_multiplier, "wrong multiplier in shrine");
        };
    }

    // In previous simulations, the time between updates was consistently 1 hour.
    // This test is to ensure that the controller is still working as expected
    // when the time between updates is variable.
    #[test]
    fn test_against_ground_truth3() {
        let ControllerTestConfig { controller, shrine } = controller_utils::deploy_controller();

        start_cheat_caller_address(controller.contract_address, controller_utils::ADMIN);

        // Updating `i_gain` to match the ground truth simulation
        controller.set_i_gain(100000000000000000000000000_u128.into()); // 0.1 (ray)
        controller.set_p_gain((1000000_u128 * wadray::RAY_ONE).into()); // 1,000,000 (ray)

        // Loading our ground truth into arrays for comparison
        let mut prices: Array<Wad> = array![
            999000000000000000_u128.into(),
            998000000000000000_u128.into(),
            997000000000000000_u128.into(),
            996000000000000000_u128.into(),
            995000000000000000_u128.into(),
        ];
        let mut expected_p_terms_for_update: Array<SignedRay> = array![
            1000000000000000000000000_u128.into(),
            1000000000000000000000000_u128.into(),
            1000000000000000000000000_u128.into(),
            8000000000000020000000000_u128.into(),
            8000000000000000000000000_u128.into(),
            27000000000000100000000000_u128.into(),
            64000000000000200000000000_u128.into(),
            64000000000000200000000000_u128.into(),
            125000000000000000000000000_u128.into(),
            125000000000000000000000000_u128.into(),
        ];
        let mut expected_i_terms_for_update: Array<SignedRay> = array![
            0_u128.into(),
            99999950000037600000000_u128.into(),
            199999900000075000000000_u128.into(),
            299999850000113000000000_u128.into(),
            199999600001200000000000_u128.into(),
            399999200002400000000000_u128.into(),
            299998650009113000000000_u128.into(),
            399996800038400000000000_u128.into(),
            799993600076800000000000_u128.into(),
            499993750117186000000000_u128.into(),
        ];
        let mut expected_multipliers: Array<Ray> = array![
            1001000000000000000000000000_u128.into(),
            1001099999950000040000000000_u128.into(),
            1001199999900000080000000000_u128.into(),
            1008299999850000140000000000_u128.into(),
            1008499999450001340000000000_u128.into(),
            1027699999050002600000000000_u128.into(),
            1064699997850011700000000000_u128.into(),
            1064699995450047700000000000_u128.into(),
            1126099992250086000000000000_u128.into(),
            1126299987350194000000000000_u128.into(),
        ];
        let mut update_intervals: Array<u64> = array![1, 4, 6, 7, 9];

        let mut current_interval: u64 = 1;
        let end_interval: u64 = 10;

        let loop_end = end_interval + 1;
        while current_interval != loop_end {
            let mut multiplier: Ray = controller.get_current_multiplier();
            let mut i_term = controller.get_i_term();
            if update_intervals.len() > 0 {
                if current_interval == *update_intervals.at(0) {
                    let _ = update_intervals.pop_front();
                    let price: Wad = prices.pop_front().unwrap();
                    controller_utils::set_yin_spot_price(shrine, price);

                    i_term = controller.get_i_term();
                    multiplier = controller.get_current_multiplier();
                    controller.update_multiplier();
                }
            }

            let p_term: SignedRay = controller.get_p_term();
            let expected_p_term_for_update: SignedRay = expected_p_terms_for_update.pop_front().unwrap();
            common::assert_equalish(p_term, expected_p_term_for_update, ERROR_MARGIN.into(), 'Wrong p term');

            let expected_i_term_for_update = expected_i_terms_for_update.pop_front().unwrap();
            common::assert_equalish(i_term, expected_i_term_for_update, ERROR_MARGIN.into(), 'Wrong i term');

            let expected_multiplier = expected_multipliers.pop_front().unwrap();
            common::assert_equalish(multiplier, expected_multiplier, ERROR_MARGIN.into(), 'Wrong multiplier');

            controller_utils::fast_forward_1_hour();
            current_interval += 1;
        }
    }

    #[test]
    fn test_against_ground_truth4() {
        let ControllerTestConfig { controller, shrine } = controller_utils::deploy_controller();

        start_cheat_caller_address(controller.contract_address, controller_utils::ADMIN);

        // Updating `i_gain` to match the ground truth simulation
        controller.set_i_gain(100000000000000000000000000_u128.into()); // 0.1 (ray)
        controller.set_p_gain((1000000_u128 * wadray::RAY_ONE).into()); // 1,000,000 (ray)

        // Loading our ground truth into arrays for comparison
        let prices: Span<Wad> = array![
            1010000000000000000_u128.into(),
            1009070214084160000_u128.into(),
            1008140856336630000_u128.into(),
            1007913464870420000_u128.into(),
            1007501969998440000_u128.into(),
            1007052728821550000_u128.into(),
            1006534504840420000_u128.into(),
            1005954136457240000_u128.into(),
            1005313382507510000_u128.into(),
            1004610965226620000_u128.into(),
            1003853817920420000_u128.into(),
            1003050483282290000_u128.into(),
            1002211038229070000_u128.into(),
            1001347832590710000_u128.into(),
            1000467142052610000_u128.into(),
            999579268159293000_u128.into(),
            999876291246443000_u128.into(),
            1000170338496500000_u128.into(),
            999281991878406000_u128.into(),
            999576275080028000_u128.into(),
            999875348924666000_u128.into(),
        ]
            .span();

        let mut expected_p_terms_for_update: Array<SignedRay> = array![
            -(1000000000000000000000000000_u128.into()),
            -(746195479083163000000000000_u128.into()),
            -(539523383475842000000000000_u128.into()),
            -(495564327004783000000000000_u128.into()),
            -(422207524564506000000000000_u128.into()),
            -(350809670272374000000000000_u128.into()),
            -(279021745992382000000000000_u128.into()),
            -(211084503271561000000000000_u128.into()),
            -(150007593859528000000000000_u128.into()),
            -(98033733163741300000000000_u128.into()),
            -(57236566790689500000000000_u128.into()),
            -(28386114337710200000000000_u128.into()),
            -(10809080591526600000000000_u128.into()),
            -(2448543705060000000000000_u128.into()),
            -(101940531608629000000000_u128.into()),
            74475965338492500000000_u128.into(),
            1893220914080160000000_u128.into(),
            -(4942406121069110000000_u128.into()),
            370158792771876000000000_u128.into(),
            76076761868840400000000_u128.into(),
            1936814769458320000000_u128.into(),
        ];

        let mut expected_i_terms_for_update: Array<SignedRay> = array![
            0_u128.into(),
            -(999950003749689000000000_u128.into()),
            -(906984100943969000000000_u128.into()),
            -(814058658834616000000000_u128.into()),
            -(791321709989352000000000_u128.into()),
            -(750175890358791000000000_u128.into()),
            -(705255342325826000000000_u128.into()),
            -(653436533401461000000000_u128.into()),
            -(595403091779449000000000_u128.into()),
            -(531330750530118000000000_u128.into()),
            -(461091621053498000000000_u128.into()),
            -(385378930245532000000000_u128.into()),
            -(305046908933185000000000_u128.into()),
            -(221103282454939000000000_u128.into()),
            -(134783136643973000000000_u128.into()),
            -(46714200163985700000000_u128.into()),
            42073180346892300000000_u128.into(),
            12370875261032900000000_u128.into(),
            -(17033849402874100000000_u128.into()),
            71800793651462500000000_u128.into(),
            42372488193362600000000_u128.into(),
        ];

        let mut expected_multipliers: Array<Ray> = array![
            200000000000000000000000000_u128.into(),
            252804570913087000000000000_u128.into(),
            458569682419464000000000000_u128.into(),
            502714630235438000000000000_u128.into(),
            576187095066670000000000000_u128.into(),
            647648832127279000000000000_u128.into(),
            719522822774933000000000000_u128.into(),
            787556804852712000000000000_u128.into(),
            848743566515292000000000000_u128.into(),
            900839532993949000000000000_u128.into(),
            941771010837727000000000000_u128.into(),
            970767415110991000000000000_u128.into(),
            988500493569295000000000000_u128.into(),
            997025306103552000000000000_u128.into(),
            999542173049293000000000000_u128.into(),
            999892978628531000000000000_u128.into(),
            999997252201097000000000000_u128.into(),
            1000049501649490000000000000_u128.into(),
            1000365495818630000000000000_u128.into(),
            1000130843706120000000000000_u128.into(),
            1000116110096610000000000000_u128.into(),
        ];

        for price in prices {
            controller_utils::fast_forward_1_hour();
            controller_utils::set_yin_spot_price(shrine, *price);

            let p_term: SignedRay = controller.get_p_term();
            let expected_p_term_for_update: SignedRay = expected_p_terms_for_update.pop_front().unwrap();
            common::assert_equalish(p_term, expected_p_term_for_update, ERROR_MARGIN.into(), 'Wrong p term');

            let i_term: SignedRay = controller.get_i_term();
            let expected_i_term_for_update: SignedRay = expected_i_terms_for_update.pop_front().unwrap();
            common::assert_equalish(i_term, expected_i_term_for_update, ERROR_MARGIN.into(), 'Wrong i term');

            let multiplier: Ray = controller.get_current_multiplier();
            let expected_multiplier: Ray = expected_multipliers.pop_front().unwrap();
            common::assert_equalish(multiplier, expected_multiplier, ERROR_MARGIN.into(), 'Wrong multiplier');

            controller.update_multiplier();
        };
    }

    // Multiple updates in one interval
    #[test]
    fn test_against_ground_truth5() {
        let ControllerTestConfig { controller, shrine } = controller_utils::deploy_controller();

        start_cheat_caller_address(controller.contract_address, controller_utils::ADMIN);

        // Updating `i_gain` to match the ground truth simulation
        controller.set_i_gain(100000000000000000000000000_u128.into()); // 0.1 (ray)
        controller.set_p_gain((1000000_u128 * wadray::RAY_ONE).into()); // 1,000,000 (ray)

        let seconds_since_last_update_arr: Array<u64> = array![60, 138, 222, 300, 126, 78, 42, 420, 246];

        let mut prices: Array<Wad> = array![
            999000000000000000_u128.into(),
            999000000000000000_u128.into(),
            999000000000000000_u128.into(),
            998000000000000000_u128.into(),
            998000000000000000_u128.into(),
            997000000000000000_u128.into(),
            997000000000000000_u128.into(),
            998000000000000000_u128.into(),
            998000000000000000_u128.into(),
        ];

        let mut expected_p_terms_for_update: Array<SignedRay> = array![
            1000000000000000000000000_u128.into(),
            1000000000000000000000000_u128.into(),
            1000000000000000000000000_u128.into(),
            8000000000000020000000000_u128.into(),
            8000000000000020000000000_u128.into(),
            27000000000000100000000000_u128.into(),
            27000000000000100000000000_u128.into(),
            8000000000000020000000000_u128.into(),
            8000000000000020000000000_u128.into(),
        ];

        let mut expected_i_terms_for_update: Array<SignedRay> = array![
            1666665833333960000000_u128.into(),
            3833331416668110000000_u128.into(),
            6166663583335650000000_u128.into(),
            8333329166669800000000_u128.into(),
            6999986000042010000000_u128.into(),
            4333324666692670000000_u128.into(),
            3499984250106320000000_u128.into(),
            34999842501063200000000_u128.into(),
            13666639333415300000000_u128.into(),
        ];

        let mut expected_multipliers: Array<Ray> = array![
            1001001666665830000000000000_u128.into(),
            1001005499997250000000000000_u128.into(),
            1001009999995000000000000000_u128.into(),
            1008014499992750000000000000_u128.into(),
            1008015333315170000000000000_u128.into(),
            1027011333310670000000000000_u128.into(),
            1027007833308920000000000000_u128.into(),
            1008038499826750000000000000_u128.into(),
            1008048666481830000000000000_u128.into(),
        ];

        // Update for first hour after deployment
        controller_utils::fast_forward_1_hour();
        let price: Wad = 999000000000000000_u128.into();
        controller_utils::set_yin_spot_price(shrine, price);
        controller.update_multiplier();

        // Multiple updates in the second hour
        for seconds_since_last_update in seconds_since_last_update_arr {
            start_cheat_block_timestamp_global(get_block_timestamp() + seconds_since_last_update);

            let price: Wad = prices.pop_front().unwrap();
            controller_utils::set_yin_spot_price(shrine, price);

            let p_term: SignedRay = controller.get_p_term();
            let expected_p_term_for_update: SignedRay = expected_p_terms_for_update.pop_front().unwrap();
            common::assert_equalish(p_term, expected_p_term_for_update, ERROR_MARGIN.into(), 'Wrong p term');

            let i_term: SignedRay = controller.get_i_term();
            let expected_i_term_for_update: SignedRay = expected_i_terms_for_update.pop_front().unwrap();
            common::assert_equalish(i_term, expected_i_term_for_update, ERROR_MARGIN.into(), 'Wrong i term');

            let multiplier: Ray = controller.get_current_multiplier();
            let expected_multiplier: Ray = expected_multipliers.pop_front().unwrap();
            common::assert_equalish(multiplier, expected_multiplier, ERROR_MARGIN.into(), 'Wrong multiplier');

            controller.update_multiplier();
        };
    }

    #[test]
    fn test_frequent_updates() {
        let ControllerTestConfig { controller, shrine } = controller_utils::deploy_controller();
        start_cheat_caller_address(controller.contract_address, controller_utils::ADMIN);
        // Ensuring the integral gain is non-zero
        controller.set_i_gain(100000000000000000000000_u128.into()); // 0.0001

        controller_utils::set_yin_spot_price(shrine, YIN_PRICE1.into());
        controller.update_multiplier();

        // Standard flow, updating the multiplier every hour
        let prev_multiplier: Ray = controller.get_current_multiplier();
        controller_utils::fast_forward_1_hour();
        controller.update_multiplier();
        let current_multiplier: Ray = controller.get_current_multiplier();
        assert(current_multiplier > prev_multiplier, 'Multiplier should increase');

        // Suddenly the multiplier is updated multiple times within the same block.
        // The multiplier should not change.
        controller.update_multiplier();
        controller.update_multiplier();
        controller.update_multiplier();

        assert(current_multiplier == controller.get_current_multiplier(), 'Multiplier should not change');
    }
}

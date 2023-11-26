mod test_transmuter {
    use opus::core::transmuter::transmuter as transmuter_contract;
    use opus::interfaces::IShrine::{IShrineDispatcher, IShrineDispatcherTrait};
    use opus::interfaces::ITransmuter::{ITransmuterDispatcher, ITransmuterDispatcherTrait};
    use opus::tests::common;
    use opus::tests::shrine::utils::shrine_utils;
    use opus::tests::transmuter::utils::transmuter_utils;
    use opus::utils::access_control::{IAccessControlDispatcher, IAccessControlDispatcherTrait};
    use opus::utils::wadray::{Wad, WadZeroable};
    use opus::utils::wadray;
    use starknet::ContractAddress;
    use starknet::contract_address::ContractAddressZeroable;

    //
    // Tests - Deployment 
    //

    // Check constructor function
    #[test]
    #[available_gas(20000000000)]
    fn test_transmuter_deploy() {
        let (shrine, transmuter, mock_usd_stable) =
            transmuter_utils::shrine_with_mock_usd_stable_transmuter();

        // Check Transmuter getters
        let ceiling: Wad = transmuter_utils::INITIAL_CEILING.into();
        let receiver: ContractAddress = transmuter_utils::receiver();

        assert(transmuter.get_asset() == mock_usd_stable.contract_address, 'wrong asset');
        assert(transmuter.get_ceiling() == ceiling, 'wrong ceiling');
        assert(
            transmuter
                .get_percentage_cap() == transmuter_contract::PERCENTAGE_CAP_UPPER_BOUND
                .into(),
            'wrong percentage cap'
        );
        assert(transmuter.get_receiver() == receiver, 'wrong receiver');
        assert(transmuter.get_reversibility(), 'not reversible');
        assert(transmuter.get_transmute_fee().is_zero(), 'non-zero transmute fee');
        assert(transmuter.get_reverse_fee().is_zero(), 'non-zero reverse fee');
        assert(transmuter.get_live(), 'not live');
        assert(!transmuter.get_reclaimable(), 'reclaimable');

        let transmuter_ac: IAccessControlDispatcher = IAccessControlDispatcher {
            contract_address: transmuter.contract_address
        };
        assert(transmuter_ac.get_admin() == shrine_utils::admin(), 'wrong admin');

        let mut expected_events: Span<transmuter_contract::Event> = array![
            transmuter_contract::Event::CeilingUpdated(
                transmuter_contract::CeilingUpdated {
                    old_ceiling: WadZeroable::zero(), new_ceiling: ceiling,
                }
            ),
            transmuter_contract::Event::ReceiverUpdated(
                transmuter_contract::ReceiverUpdated {
                    old_receiver: ContractAddressZeroable::zero(), new_receiver: receiver
                }
            ),
            transmuter_contract::Event::PercentageCapUpdated(
                transmuter_contract::PercentageCapUpdated {
                    cap: transmuter_contract::PERCENTAGE_CAP_UPPER_BOUND.into(),
                }
            ),
        ]
            .span();
        common::assert_events_emitted(transmuter.contract_address, expected_events, Option::None);
    }
}

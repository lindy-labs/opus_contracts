mod AbbotUtils {
    use array::{ArrayTrait, SpanTrait};
    use integer::BoundedU256;
    use option::OptionTrait;
    use starknet::{
        ClassHash, class_hash_try_from_felt252, ContractAddress, contract_address_to_felt252,
        deploy_syscall, SyscallResultTrait
    };
    use starknet::contract_address::ContractAddressZeroable;
    use starknet::testing::set_contract_address;
    use traits::{Default, Into};

    use aura::core::abbot::Abbot;
    use aura::core::roles::SentinelRoles;
    use aura::core::roles::ShrineRoles;

    use aura::interfaces::IAbbot::{IAbbotDispatcher, IAbbotDispatcherTrait};
    use aura::interfaces::IERC20::{
        IERC20Dispatcher, IERC20DispatcherTrait, IMintableDispatcher, IMintableDispatcherTrait
    };
    use aura::interfaces::IGate::{IGateDispatcher, IGateDispatcherTrait};
    use aura::interfaces::ISentinel::{ISentinelDispatcher, ISentinelDispatcherTrait};
    use aura::interfaces::IShrine::{IShrineDispatcher, IShrineDispatcherTrait};
    use aura::utils::access_control::{IAccessControlDispatcher, IAccessControlDispatcherTrait};
    use aura::utils::wadray;
    use aura::utils::wadray::Wad;

    use aura::tests::sentinel::utils::SentinelUtils;
    use aura::tests::shrine::utils::ShrineUtils;

    //
    // Test setup helpers
    //

    fn abbot_deploy() -> (
        IShrineDispatcher,
        ISentinelDispatcher,
        IAbbotDispatcher,
        Span<ContractAddress>,
        Span<IGateDispatcher>
    ) {
        let (sentinel, shrine, yangs, gates) = SentinelUtils::deploy_sentinel_with_gates();
        ShrineUtils::shrine_setup(shrine.contract_address);

        let mut calldata = Default::default();
        calldata.append(contract_address_to_felt252(shrine.contract_address));
        calldata.append(contract_address_to_felt252(sentinel.contract_address));

        let abbot_class_hash: ClassHash = class_hash_try_from_felt252(Abbot::TEST_CLASS_HASH)
            .unwrap();
        let (abbot_addr, _) = deploy_syscall(abbot_class_hash, 0, calldata.span(), false)
            .unwrap_syscall();

        let abbot = IAbbotDispatcher { contract_address: abbot_addr };

        // Grant Shrine roles to Abbot
        set_contract_address(ShrineUtils::admin());
        let shrine_ac = IAccessControlDispatcher { contract_address: shrine.contract_address };
        shrine_ac.grant_role(ShrineRoles::abbot(), abbot_addr);

        // Grant Sentinel roles to Abbot
        set_contract_address(SentinelUtils::admin());
        let sentinel_ac = IAccessControlDispatcher { contract_address: sentinel.contract_address };
        sentinel_ac.grant_role(SentinelRoles::abbot(), abbot_addr);

        (shrine, sentinel, abbot, yangs, gates)
    }


    // Helper function to fund a user account with yang assets
    fn fund_user(
        user: ContractAddress, mut yangs: Span<ContractAddress>, mut asset_amts: Span<u128>
    ) {
        loop {
            match yangs.pop_front() {
                Option::Some(yang) => {
                    IMintableDispatcher {
                        contract_address: *yang
                    }.mint(user, (*asset_amts.pop_front().unwrap()).into());
                },
                Option::None(_) => {
                    break;
                }
            };
        };
    }

    // Helper function to approve Gates to transfer tokens from user, and to open a trove
    fn open_trove_helper(
        abbot: IAbbotDispatcher,
        user: ContractAddress,
        mut yangs: Span<ContractAddress>,
        yang_asset_amts: Span<u128>,
        mut gates: Span<IGateDispatcher>,
        forge_amt: Wad
    ) -> u64 {
        set_contract_address(user);
        let mut yangs_copy = yangs;
        loop {
            match yangs_copy.pop_front() {
                Option::Some(yang) => {
                    // Approve Gate to transfer from user
                    IERC20Dispatcher {
                        contract_address: *yang
                    }.approve((*gates.pop_front().unwrap()).contract_address, BoundedU256::max());
                },
                Option::None(_) => {
                    break;
                }
            };
        };

        let trove_id: u64 = abbot.open_trove(forge_amt, yangs, yang_asset_amts, 0_u128.into());

        set_contract_address(ContractAddressZeroable::zero());

        trove_id
    }
}

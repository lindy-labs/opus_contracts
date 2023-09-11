mod PragmaUtils {
    use array::ArrayTrait;
    use starknet::{
        ClassHash, class_hash_try_from_felt252, ContractAddress, contract_address_to_felt252,
        contract_address_try_from_felt252, deploy_syscall, get_block_timestamp, SyscallResultTrait
    };
    use starknet::contract_address::ContractAddressZeroable;
    use starknet::testing::set_contract_address;

    use aura::core::roles::ShrineRoles;
    use aura::external::pragma::Pragma;

    use aura::interfaces::external::{IPragmaOracleDispatcher, IPragmaOracleDispatcherTrait};
    use aura::interfaces::IGate::{IGateDispatcher, IGateDispatcherTrait};
    use aura::interfaces::IOracle::{IOracleDispatcher, IOracleDispatcherTrait};
    use aura::interfaces::IPragma::{IPragmaDispatcher, IPragmaDispatcherTrait};
    use aura::interfaces::ISentinel::{ISentinelDispatcher, ISentinelDispatcherTrait};
    use aura::interfaces::IShrine::{IShrineDispatcher, IShrineDispatcherTrait};
    use aura::types::Pragma::PricesResponse;
    use aura::utils::access_control::{IAccessControlDispatcher, IAccessControlDispatcherTrait};
    use aura::utils::math::pow;
    use aura::utils::wadray;
    use aura::utils::wadray::{WAD_DECIMALS, WAD_SCALE};

    use aura::tests::external::mock_pragma::{
        IMockPragmaDispatcher, IMockPragmaDispatcherTrait, MockPragma
    };
    use aura::tests::sentinel::utils::SentinelUtils;
    use aura::tests::shrine::utils::ShrineUtils;

    //
    // Constants
    //

    const FRESHNESS_THRESHOLD: u64 = consteval_int!(30 * 60); // 30 minutes * 60 seconds
    const SOURCES_THRESHOLD: u64 = 3;
    const UPDATE_FREQUENCY: u64 = consteval_int!(10 * 60); // 10 minutes * 60 seconds

    const DEFAULT_NUM_SOURCES: u256 = 5;

    const ETH_USD_PAIR_ID: u256 = 19514442401534788; // str_to_felt("ETH/USD")
    const ETH_INIT_PRICE: u128 = 1888; // raw integer value without fixed point decimals

    const WBTC_USD_PAIR_ID: u256 = 18669995996566340; // str_to_felt("BTC/USD")
    const WBTC_INIT_PRICE: u128 = 20000; // raw integer value without fixed point decimals

    const PRAGMA_DECIMALS: u8 = 8;

    //
    // Constant addresses
    //

    #[inline(always)]
    fn admin() -> ContractAddress {
        contract_address_try_from_felt252('pragma owner').unwrap()
    }

    //
    // Helpers
    //

    #[inline(always)]
    fn yang_pair_ids() -> Span<u256> {
        let mut pair_ids: Array<u256> = array![ETH_USD_PAIR_ID, WBTC_USD_PAIR_ID];
        pair_ids.span()
    }

    //
    // Test setup helpers
    //

    fn mock_pragma_deploy() -> IMockPragmaDispatcher {
        let mut calldata: Array<felt252> = Default::default();
        let mock_pragma_class_hash: ClassHash = class_hash_try_from_felt252(
            MockPragma::TEST_CLASS_HASH
        )
            .unwrap();
        let (mock_pragma_addr, _) = deploy_syscall(
            mock_pragma_class_hash, 0, calldata.span(), false
        )
            .unwrap_syscall();

        // Add ETH/USD and BTC/USD to mock Pragma oracle
        let mock_pragma: IMockPragmaDispatcher = IMockPragmaDispatcher {
            contract_address: mock_pragma_addr
        };

        let price_ts: u64 = get_block_timestamp() - 1000;
        mock_valid_price_update(
            mock_pragma, ETH_USD_PAIR_ID, convert_price_to_pragma_scale(ETH_INIT_PRICE), price_ts
        );
        mock_valid_price_update(
            mock_pragma, WBTC_USD_PAIR_ID, convert_price_to_pragma_scale(WBTC_INIT_PRICE), price_ts
        );

        mock_pragma
    }

    fn pragma_deploy() -> (
        IShrineDispatcher, IPragmaDispatcher, ISentinelDispatcher, IMockPragmaDispatcher,
    ) {
        let (sentinel, shrine_addr) = SentinelUtils::deploy_sentinel();
        pragma_deploy_with_shrine(sentinel, shrine_addr)
    }

    fn pragma_deploy_with_shrine(
        sentinel: ISentinelDispatcher, shrine_addr: ContractAddress
    ) -> (IShrineDispatcher, IPragmaDispatcher, ISentinelDispatcher, IMockPragmaDispatcher,) {
        let mock_pragma: IMockPragmaDispatcher = mock_pragma_deploy();

        let admin: ContractAddress = admin();

        let mut calldata: Array<felt252> = array![
            contract_address_to_felt252(admin),
            contract_address_to_felt252(mock_pragma.contract_address),
            contract_address_to_felt252(shrine_addr),
            contract_address_to_felt252(sentinel.contract_address),
            UPDATE_FREQUENCY.into(),
            FRESHNESS_THRESHOLD.into(),
            SOURCES_THRESHOLD.into(),
        ];

        let pragma_class_hash: ClassHash = class_hash_try_from_felt252(Pragma::TEST_CLASS_HASH)
            .unwrap();
        let (pragma_addr, _) = deploy_syscall(pragma_class_hash, 0, calldata.span(), false)
            .unwrap_syscall();

        // Grant necessary roles
        let shrine_ac = IAccessControlDispatcher { contract_address: shrine_addr };
        set_contract_address(ShrineUtils::admin());
        shrine_ac.grant_role(ShrineRoles::ADVANCE, pragma_addr);

        let shrine = IShrineDispatcher { contract_address: shrine_addr };
        let pragma = IPragmaDispatcher { contract_address: pragma_addr };

        set_contract_address(ContractAddressZeroable::zero());

        (shrine, pragma, sentinel, mock_pragma)
    }

    fn pragma_with_yangs() -> (
        IShrineDispatcher,
        IPragmaDispatcher,
        ISentinelDispatcher,
        IMockPragmaDispatcher,
        Span<ContractAddress>, // yang addresses
        Span<IGateDispatcher>
    ) {
        let (shrine, pragma, sentinel, mock_pragma) = pragma_deploy();

        let (eth_token_addr, eth_gate) = SentinelUtils::add_eth_yang(
            sentinel, shrine.contract_address
        );
        let (wbtc_token_addr, wbtc_gate) = SentinelUtils::add_wbtc_yang(
            sentinel, shrine.contract_address
        );

        let mut yangs: Array<ContractAddress> = array![eth_token_addr, wbtc_token_addr];
        let mut gates: Array<IGateDispatcher> = array![eth_gate, wbtc_gate];

        add_yangs_to_pragma(pragma, yangs.span());

        (shrine, pragma, sentinel, mock_pragma, yangs.span(), gates.span())
    }

    fn add_yangs_to_pragma(pragma: IPragmaDispatcher, yangs: Span<ContractAddress>) {
        set_contract_address(admin());

        // Add yangs to Pragma
        pragma.add_yang(ETH_USD_PAIR_ID, *yangs.at(0));
        pragma.add_yang(WBTC_USD_PAIR_ID, *yangs.at(1));

        set_contract_address(ContractAddressZeroable::zero());
    }

    //
    // Helpers
    //

    fn convert_price_to_pragma_scale(price: u128) -> u128 {
        let pragma_price_scale: u128 = pow(10_u128, PRAGMA_DECIMALS);
        price * pragma_price_scale
    }

    // Helper function to add a valid price update to the mock Pragma oracle
    // using default values for decimals and number of sources.
    // Note that `price` is the raw integer value without fixed point decimals.
    fn mock_valid_price_update(
        mock_pragma: IMockPragmaDispatcher, pair_id: u256, price: u128, timestamp: u64
    ) {
        let response = PricesResponse {
            price: price.into(),
            decimals: PRAGMA_DECIMALS.into(),
            last_updated_timestamp: timestamp.into(),
            num_sources_aggregated: DEFAULT_NUM_SOURCES,
        };
        mock_pragma.next_get_data_median(pair_id, response);
    }
}

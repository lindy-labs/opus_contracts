mod test_receptor {
    use opus::constants::{DAI_DECIMALS, USDC_DECIMALS, USDT_DECIMALS};
    use opus::core::receptor::receptor as receptor_contract;
    use opus::interfaces::IShrine::{IShrineDispatcher, IShrineDispatcherTrait};
    use opus::tests::receptor::utils::receptor_utils;
    use opus::tests::shrine::utils::shrine_utils;
    use opus::types::QuoteTokenInfo;


    #[test]
    fn test_receptor_deploy() {
        let shrine: IShrineDispatcher = shrine_utils::shrine_deploy_and_setup(Option::None);

        let quote_tokens: Span<QuoteTokenInfo> = array![
            QuoteTokenInfo { address: receptor_utils::mock_dai(), decimals: DAI_DECIMALS },
            QuoteTokenInfo { address: receptor_utils::mock_usdc(), decimals: USDC_DECIMALS },
            QuoteTokenInfo { address: receptor_utils::mock_usdt(), decimals: USDT_DECIMALS },
        ]
            .span();

        let receptor = receptor_utils::receptor_deploy(
            shrine.contract_address,
            receptor_utils::mock_oracle_extension(),
            receptor_utils::INITIAL_TWAP_DURATION,
            quote_tokens,
            Option::None
        );

        println!("Receptor deployed");
    }
}

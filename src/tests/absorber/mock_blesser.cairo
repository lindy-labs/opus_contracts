#[contract]
mod MockBlesser {
    use option::OptionTrait;
    use starknet::{ContractAddress, get_contract_address};
    use traits::{Into, TryInto};

    use aura::interfaces::IERC20::{IERC20Dispatcher, IERC20DispatcherTrait};
    use aura::utils::access_control::AccessControl;
    use aura::utils::u256_conversions;

    struct Storage {
        asset: IERC20Dispatcher,
        absorber: ContractAddress
    }

    const BLESS_AMT: u128 = 1000000000000000000000; // 1_000 (Wad)

    #[constructor]
    fn constructor(asset: ContractAddress, absorber: ContractAddress) {
        asset::write(IERC20Dispatcher { contract_address: asset });
        absorber::write(absorber);
    }

    #[view]
    fn preview_bless() -> u128 {
        preview_bless_internal(asset::read())
    }

    #[external]
    fn bless() -> u128 {
        let asset: IERC20Dispatcher = asset::read();
        let bless_amt: u256 = preview_bless_internal(asset).into();
        asset.transfer(absorber::read(), bless_amt);
        bless_amt.try_into().unwrap()
    }

    fn preview_bless_internal(asset: IERC20Dispatcher) -> u128 {
        let balance: u128 = asset.balance_of(get_contract_address()).try_into().unwrap();
        if balance < BLESS_AMT {
            0
        } else {
            BLESS_AMT
        }
    }
}

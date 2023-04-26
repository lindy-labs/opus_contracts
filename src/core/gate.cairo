#[contract]
mod Gate {
    use integer::u128_try_from_felt252;
    use option::OptionTrait;
    use starknet::ContractAddress;
    use starknet::get_contract_address;
    use traits::Into;
    use traits::TryInto;

    use aura::interfaces::IERC20::IERC20Dispatcher;
    use aura::interfaces::IERC20::IERC20DispatcherTrait;
    use aura::interfaces::IShrine::IShrineDispatcher;
    use aura::interfaces::IShrine::IShrineDispatcherTrait;
    use aura::utils::pow::pow10;
    use aura::utils::wadray::fixed_point_to_wad;
    use aura::utils::wadray::Wad;
    use aura::utils::wadray::WAD_DECIMALS;
    use aura::utils::wadray::WAD_ONE;
    use aura::utils::u256_conversions::U128IntoU256;
    use aura::utils::u256_conversions::U256TryIntoU128;

    struct Storage {
        shrine: ContractAddress,
        asset: ContractAddress,
        live: bool,
    }

    //
    // Events
    //

    #[event]
    fn Enter(user: ContractAddress, trove_id: u64, asset_amt: u128, yang_amt: Wad) {}

    #[event]
    fn Exit(user: ContractAddress, trove_id: u64, asset_amt: u128, yang_amt: Wad) {}

    #[event]
    fn Killed() {}

    //
    // Constructor
    //

    #[constructor]
    fn constructor(admin: ContractAddress, shrine: ContractAddress, asset: ContractAddress) {
        // TODO: initialize admin in access control
        // TODO: grant gate default role to admin

        initializer(shrine, asset);
        live::write(true);
    }

    //
    // Getters
    //

    #[view]
    fn get_shrine() -> ContractAddress {
        shrine::read()
    }

    #[view]
    fn get_asset() -> ContractAddress {
        asset::read()
    }

    #[view]
    fn get_total_assets() -> u128 {
        get_total_assets_internal()
    }

    #[view]
    fn get_total_yang() -> Wad {
        get_total_yang_internal()
    }

    #[view]
    fn get_asset_amt_per_yang() -> Wad {
        get_asset_amt_per_yang_internal()
    }

    #[view]
    fn preview_enter(asset_amt: u128) -> Wad {
        convert_to_yang(asset_amt)
    }

    #[view]
    fn preview_exit(yang_amt: Wad) -> u128 {
        convert_to_assets(yang_amt)
    }

    #[view]
    fn get_live() -> bool {
        live::read()
    }

    //
    // External
    //

    #[external]
    fn kill() {
        // TODO: add access control for kill role
        live::write(false);
        Killed();
    }

    // `assets` is denominated in the decimals of the asset
    #[external]
    fn enter(user: ContractAddress, trove_id: u64, asset_amt: u128) -> Wad {
        // TODO: Revisit whether reentrancy guard should be added here

        assert_live();

        // TODO: add access control for enter role

        let yang_amt: Wad = convert_to_yang(asset_amt);
        if yang_amt.val == 0 {
            return Wad { val: 0 };
        }

        let asset: ContractAddress = asset::read();
        let gate: ContractAddress = get_contract_address();

        let success: bool = IERC20Dispatcher {
            contract_address: asset
        }.transfer_from(user, gate, asset_amt.into());
        assert(success == true, 'GA: Asset transfer failed');

        Enter(user, trove_id, asset_amt, yang_amt);

        Wad { val: 0 }
    }

    #[external]
    fn exit(user: ContractAddress, trove_id: u64, yang_amt: Wad) -> u128 {
        // TODO: add access control for exit role

        let asset_amt: u128 = convert_to_assets(yang_amt);
        if asset_amt == 0 {
            return 0;
        }

        let asset: ContractAddress = asset::read();
        let success: bool = IERC20Dispatcher {
            contract_address: asset
        }.transfer(user, asset_amt.into());
        assert(success == true, 'GA: Asset transfer failed');

        Exit(user, trove_id, asset_amt, yang_amt);

        asset_amt
    }

    //
    // Internal
    //

    fn initializer(shrine: ContractAddress, asset: ContractAddress) {
        shrine::write(shrine);
        asset::write(asset);
    }

    fn assert_live() {
        let is_live: bool = live::read();
        assert(is_live == true, 'GA: not live');
    }

    fn get_total_assets_internal() -> u128 {
        let asset: ContractAddress = asset::read();
        let gate: ContractAddress = get_contract_address();
        let total_bal: u256 = IERC20Dispatcher { contract_address: asset }.balance_of(gate);
        total_bal.try_into().unwrap()
    }

    fn get_total_yang_internal() -> Wad {
        let shrine: ContractAddress = shrine::read();
        let asset: ContractAddress = asset::read();
        let yang_total: Wad = IShrineDispatcher { contract_address: shrine }.get_yang_total(asset);
        yang_total
    }

    fn get_asset_amt_per_yang_internal() -> Wad {
        let amt: u128 = convert_to_assets(Wad { val: WAD_ONE });
        let asset: ContractAddress = asset::read();
        let decimals: u8 = IERC20Dispatcher { contract_address: asset }.decimals();

        if decimals == WAD_DECIMALS {
            return Wad { val: amt };
        }

        fixed_point_to_wad(amt, decimals)
    }

    // Return value is `u128` and not `Wad` because it is denominated in the decimals of the asset
    fn convert_to_assets(yang_amt: Wad) -> u128 {
        let total_supply: Wad = get_total_yang_internal();

        if total_supply.val == 0 {
            let asset: ContractAddress = asset::read();
            let decimals: u8 = IERC20Dispatcher { contract_address: asset }.decimals();

            if decimals == WAD_DECIMALS {
                return yang_amt.val;
            }

            // Scale by difference to match the decimal precision of the asset
            let scale: u128 = pow10(WAD_DECIMALS - decimals);
            yang_amt.val / scale
        } else {
            let total_assets: Wad = Wad { val: get_total_assets_internal() };
            let assets: Wad = (yang_amt * total_assets) / total_supply;
            assets.val
        }
    }

    // `asset_amt` may not be 18 decimals
    fn convert_to_yang(asset_amt: u128) -> Wad {
        let total_supply: Wad = get_total_yang_internal();

        if total_supply.val == 0 {
            let asset: ContractAddress = asset::read();
            let decimals: u8 = IERC20Dispatcher { contract_address: asset }.decimals();

            // `assets` is already of `Wad` precision
            if decimals == WAD_DECIMALS {
                return Wad { val: asset_amt };
            }

            // Scale by difference to match `Wad` precision`
            fixed_point_to_wad(asset_amt, decimals)
        } else {
            let total_assets: Wad = Wad { val: get_total_assets_internal() };
            let yang: Wad = (Wad { val: asset_amt } * total_supply) / total_assets;
            yang
        }
    }
}

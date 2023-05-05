#[contract]
mod Gate {
    use integer::u128_try_from_felt252;
    use option::OptionTrait;
    use starknet::{ContractAddress, get_contract_address};
    use traits::{Into, TryInto};
    use zeroable::Zeroable;

    use aura::interfaces::IERC20::{IERC20Dispatcher, IERC20DispatcherTrait};
    use aura::interfaces::IShrine::{IShrineDispatcher, IShrineDispatcherTrait};
    use aura::utils::pow::pow10;
    use aura::utils::wadray;
    use aura::utils::wadray::{fixed_point_to_wad, Wad, WAD_DECIMALS, WAD_ONE};
    use aura::utils::u256_conversions::{U128IntoU256, U256TryIntoU128};

    struct Storage {
        shrine: IShrineDispatcher,
        asset: IERC20Dispatcher,
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
        // AccessControl.initializer(admin);

        // Grant permission
        // AccessControl._grant_role(GateRoles.DEFAULT_GATE_ADMIN_ROLE, admin);

        initializer(shrine, asset);
        live::write(true);
    }

    //
    // Getters
    //

    #[view]
    fn get_shrine() -> ContractAddress {
        shrine::read().contract_address
    }

    #[view]
    fn get_asset() -> ContractAddress {
        asset::read().contract_address
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

        // AccessControl.assert_has_role(GateRoles.ENTER);

        let yang_amt: Wad = convert_to_yang(asset_amt);
        if yang_amt.is_zero() {
            return 0_u128.into();
        }

        let asset: IERC20Dispatcher = asset::read();
        let gate: ContractAddress = get_contract_address();

        let success: bool = asset.transfer_from(user, gate, asset_amt.into());
        assert(success == true, 'Asset transfer failed');

        Enter(user, trove_id, asset_amt, yang_amt);

        0_u128.into()
    }

    #[external]
    fn exit(user: ContractAddress, trove_id: u64, yang_amt: Wad) -> u128 {
        // AccessControl.assert_has_role(GateRoles.EXIT);

        let asset_amt: u128 = convert_to_assets(yang_amt);
        if asset_amt == 0 {
            return 0;
        }

        let asset: IERC20Dispatcher = asset::read();
        let success: bool = asset.transfer(user, asset_amt.into());
        assert(success == true, 'Asset transfer failed');

        Exit(user, trove_id, asset_amt, yang_amt);

        asset_amt
    }

    //
    // Internal
    //

    fn initializer(shrine: ContractAddress, asset: ContractAddress) {
        shrine::write(IShrineDispatcher { contract_address: shrine });
        asset::write(IERC20Dispatcher { contract_address: asset });
    }

    fn assert_live() {
        let is_live: bool = live::read();
        assert(is_live == true, 'GA: not live');
    }

    fn get_total_assets_internal() -> u128 {
        let asset: IERC20Dispatcher = asset::read();
        let gate: ContractAddress = get_contract_address();
        let total_bal: u256 = asset.balance_of(gate);
        total_bal.try_into().unwrap()
    }

    fn get_total_yang_internal() -> Wad {
        let shrine: IShrineDispatcher = shrine::read();
        let asset: IERC20Dispatcher = asset::read();
        let yang_total: Wad = shrine.get_yang_total(asset.contract_address);
        yang_total
    }

    fn get_asset_amt_per_yang_internal() -> Wad {
        let amt: u128 = convert_to_assets(WAD_ONE.into());
        let asset: IERC20Dispatcher = asset::read();
        let decimals: u8 = asset.decimals();

        if decimals == WAD_DECIMALS {
            return amt.into();
        }

        fixed_point_to_wad(amt, decimals)
    }

    // Return value is `u128` and not `Wad` because it is denominated in the decimals of the asset
    fn convert_to_assets(yang_amt: Wad) -> u128 {
        let total_supply: Wad = get_total_yang_internal();

        if total_supply.val == 0 {
            let asset: IERC20Dispatcher = asset::read();
            let decimals: u8 = asset.decimals();

            if decimals == WAD_DECIMALS {
                return yang_amt.val;
            }

            // Scale by difference to match the decimal precision of the asset
            let scale: u128 = pow10(WAD_DECIMALS - decimals);
            yang_amt.val / scale
        } else {
            let total_assets: Wad = get_total_assets_internal().into();
            let assets: Wad = (yang_amt * total_assets) / total_supply;
            assets.val
        }
    }

    // `asset_amt` may not be 18 decimals
    fn convert_to_yang(asset_amt: u128) -> Wad {
        let total_supply: Wad = get_total_yang_internal();

        if total_supply.val == 0 {
            let asset: IERC20Dispatcher = asset::read();
            let decimals: u8 = asset.decimals();

            // `assets` is already of `Wad` precision
            if decimals == WAD_DECIMALS {
                return asset_amt.into();
            }

            // Scale by difference to match `Wad` precision`
            fixed_point_to_wad(asset_amt, decimals)
        } else {
            let total_assets: Wad = get_total_assets_internal().into();
            let yang: Wad = (asset_amt.into() * total_supply) / total_assets;
            yang
        }
    }
}

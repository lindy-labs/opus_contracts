#[contract]
mod Gate {
    use integer::u128_try_from_felt252;
    use option::OptionTrait;
    use starknet::{ContractAddress, get_contract_address};
    use traits::{Into, TryInto};
    use zeroable::Zeroable;

    use aura::core::roles::GateRoles;

    use aura::interfaces::IERC20::{IERC20Dispatcher, IERC20DispatcherTrait};
    use aura::interfaces::IShrine::{IShrineDispatcher, IShrineDispatcherTrait};
    use aura::utils::access_control::{AccessControl, IAccessControl};
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
        AccessControl::initializer(admin);

        // Grant permission
        AccessControl::grant_role_internal(GateRoles::default_admin_role(), admin);

        shrine::write(IShrineDispatcher { contract_address: shrine });
        asset::write(IERC20Dispatcher { contract_address: asset });
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
        get_total_assets_internal(asset::read())
    }

    #[view]
    fn get_total_yang() -> Wad {
        get_total_yang_internal(asset::read().contract_address)
    }

    #[view]
    fn get_asset_amt_per_yang() -> Wad {
        let amt: u128 = convert_to_assets(WAD_ONE.into());
        let decimals: u8 = asset::read().decimals();

        if decimals == WAD_DECIMALS {
            return amt.into();
        }

        fixed_point_to_wad(amt, decimals)
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
        AccessControl::assert_has_role(GateRoles::KILL);
        assert(live::read() == true, 'Already killed');
        live::write(false);
        Killed();
    }

    // `assets` is denominated in the decimals of the asset
    #[external]
    fn enter(user: ContractAddress, trove_id: u64, asset_amt: u128) -> Wad {
        // TODO: Revisit whether reentrancy guard should be added here

        assert_live();

        AccessControl::assert_has_role(GateRoles::ENTER);

        let yang_amt: Wad = convert_to_yang(asset_amt);
        if yang_amt.is_zero() {
            return 0_u128.into();
        }

        let asset: IERC20Dispatcher = asset::read();
        let success: bool = asset.transfer_from(user, get_contract_address(), asset_amt.into());
        assert(success == true, 'Asset transfer failed');

        Enter(user, trove_id, asset_amt, yang_amt);

        yang_amt
    }

    #[external]
    fn exit(user: ContractAddress, trove_id: u64, yang_amt: Wad) -> u128 {
        AccessControl::assert_has_role(GateRoles::EXIT);

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

    fn assert_live() {
        assert(live::read() == true, 'Gate is not live');
    }

    fn get_total_assets_internal(asset: IERC20Dispatcher) -> u128 {
        asset.balance_of(get_contract_address()).try_into().unwrap()
    }

    fn get_total_yang_internal(asset: ContractAddress) -> Wad {
        shrine::read().get_yang_total(asset)
    }

    // Return value is `u128` and not `Wad` because it is denominated in the decimals of the asset
    fn convert_to_assets(yang_amt: Wad) -> u128 {
        let asset: IERC20Dispatcher = asset::read();
        let total_supply: Wad = get_total_yang_internal(asset.contract_address);

        if total_supply.val == 0 {
            let decimals: u8 = asset.decimals();

            if decimals == WAD_DECIMALS {
                return yang_amt.val;
            }

            // Scale by difference to match the decimal precision of the asset
            let scale: u128 = pow10(WAD_DECIMALS - decimals);
            yang_amt.val / scale
        } else {
            let total_assets: Wad = get_total_assets_internal(asset).into();
            let assets: Wad = (yang_amt * total_assets) / total_supply;
            assets.val
        }
    }

    // `asset_amt` may not be 18 decimals
    fn convert_to_yang(asset_amt: u128) -> Wad {
        let asset: IERC20Dispatcher = asset::read();
        let total_supply: Wad = get_total_yang_internal(asset.contract_address);

        if total_supply.val == 0 {
            let decimals: u8 = asset.decimals();

            // `asset_amt` is already of `Wad` precision
            if decimals == WAD_DECIMALS {
                return asset_amt.into();
            }

            // Scale by difference to match `Wad` precision
            fixed_point_to_wad(asset_amt, decimals)
        } else {
            let total_assets: Wad = get_total_assets_internal(asset).into();
            (asset_amt.into() * total_supply) / total_assets
        }
    }
}

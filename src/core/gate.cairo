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
    use aura::utils::wadray::{fixed_point_to_wad, Wad, WadZeroable, WAD_DECIMALS, WAD_ONE};
    use aura::utils::u256_conversions::{U128IntoU256, U256TryIntoU128};

    // As the Gate is similar to a ERC-4626 vault, it therefore faces a similar issue whereby
    // the first depositor can artificially inflate a share price by depositing the smallest
    // unit of an asset and then sending assets to the contract directly. This is addressed
    // in the Sentinel, which enforces a minimum deposit before a yang and its Gate can be 
    // added to the Shrine.

    struct Storage {
        // the Shrine associated with this Gate
        shrine: IShrineDispatcher,
        // the ERC-20 asset that is the underlying asset of this Gate's yang
        asset: IERC20Dispatcher,
        // Keeps track of whether this Gate is live or killed
        is_live: bool,
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
        is_live::write(true);
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

    // Returns the amount of assets in Wad that corresponds to per Wad unit of yang.
    // If the asset's decimals is less than `WAD_DECIMALS`, the amount is scaled up accordingly.
    // Note that if there is no yang yet, this function will still return a positive value 
    // based on the asset amount being at parity with yang (with scaling where necessary). This is
    // so that the yang price can be properly calculated by the oracle even if no assets have been 
    // deposited yet.
    #[view]
    fn get_asset_amt_per_yang() -> Wad {
        let amt: u128 = convert_to_assets(WAD_ONE.into());
        let decimals: u8 = asset::read().decimals();

        if decimals == WAD_DECIMALS {
            return amt.into();
        }

        fixed_point_to_wad(amt, decimals)
    }

    // Simulates the effects of `enter` at the current on-chain conditions.
    // `asset_amt` is denoted in the asset's decimals.
    #[view]
    fn preview_enter(asset_amt: u128) -> Wad {
        convert_to_yang(asset_amt)
    }

    // Simulates the effects of `exit` at the current on-chain conditions.
    // The return value is denoted in the asset's decimals.
    #[view]
    fn preview_exit(yang_amt: Wad) -> u128 {
        convert_to_assets(yang_amt)
    }

    #[view]
    fn get_live() -> bool {
        is_live::read()
    }

    //
    // External
    //

    #[external]
    fn kill() {
        AccessControl::assert_has_role(GateRoles::KILL);
        is_live::write(false);
        Killed();
    }

    // Transfers the stipulated amount of assets, in the asset's decimals, from the given 
    // user to the Gate and returns the corresponding yang amount in Wad.
    // `asset_amt` is denominated in the decimals of the asset.
    #[external]
    fn enter(user: ContractAddress, trove_id: u64, asset_amt: u128) -> Wad {
        assert_live();

        AccessControl::assert_has_role(GateRoles::ENTER);

        let yang_amt: Wad = convert_to_yang(asset_amt);
        if yang_amt.is_zero() {
            return 0_u128.into();
        }

        let success: bool = asset::read().transfer_from(
            user, get_contract_address(), asset_amt.into()
        );
        assert(success, 'Asset transfer failed');

        Enter(user, trove_id, asset_amt, yang_amt);

        yang_amt
    }

    // Transfers such amount of assets, in the asset's decimals, corresponding to the 
    // stipulated yang amount to the given user.
    // The return value is denominated in the decimals of the asset.
    #[external]
    fn exit(user: ContractAddress, trove_id: u64, yang_amt: Wad) -> u128 {
        AccessControl::assert_has_role(GateRoles::EXIT);

        let asset_amt: u128 = convert_to_assets(yang_amt);
        if asset_amt == 0 {
            return 0;
        }

        let success: bool = asset::read().transfer(user, asset_amt.into());
        assert(success, 'Asset transfer failed');

        Exit(user, trove_id, asset_amt, yang_amt);

        asset_amt
    }

    //
    // Internal
    //

    #[inline(always)]
    fn assert_live() {
        assert(is_live::read(), 'Gate is not live');
    }

    #[inline(always)]
    fn get_total_assets_internal(asset: IERC20Dispatcher) -> u128 {
        asset.balance_of(get_contract_address()).try_into().unwrap()
    }

    #[inline(always)]
    fn get_total_yang_internal(asset: ContractAddress) -> Wad {
        shrine::read().get_yang_total(asset)
    }

    // Helper function to calculate the amount of assets corresponding to the given
    // amount of yang.
    // Return value is denominated in the decimals of the asset.
    fn convert_to_assets(yang_amt: Wad) -> u128 {
        let asset: IERC20Dispatcher = asset::read();
        let total_yang: Wad = get_total_yang_internal(asset.contract_address);

        if total_yang.is_zero() {
            let decimals: u8 = asset.decimals();

            // If asset is of `Wad` precision, then `yang_amt` is equivalent to asset amount
            if decimals == WAD_DECIMALS {
                return yang_amt.val;
            }

            // Otherwise, scale `yang_amt` down by the difference to match the decimal 
            // precision of the asset
            yang_amt.val / pow10(WAD_DECIMALS - decimals)
        } else {
            ((yang_amt * get_total_assets_internal(asset).into()) / total_yang).val
        }
    }

    // Helper function to calculate the amount of yang corresponding to the given
    // amount of assets.
    // `asset_amt` is denominated in the decimals of the asset.
    fn convert_to_yang(asset_amt: u128) -> Wad {
        let asset: IERC20Dispatcher = asset::read();
        let total_yang: Wad = get_total_yang_internal(asset.contract_address);

        if total_yang.is_zero() {
            let decimals: u8 = asset.decimals();

            // If asset is of `Wad` precision, then `asset_amt` is equivalent to yang amount
            if decimals == WAD_DECIMALS {
                return asset_amt.into();
            }

            // Otherwise, scale `asset_amt` up by the difference to match `Wad` precision
            // of yang
            fixed_point_to_wad(asset_amt, decimals)
        } else {
            (asset_amt.into() * total_yang) / get_total_assets_internal(asset).into()
        }
    }

    //
    // Public AccessControl functions
    //

    #[view]
    fn get_roles(account: ContractAddress) -> u128 {
        AccessControl::get_roles(account)
    }

    #[view]
    fn has_role(role: u128, account: ContractAddress) -> bool {
        AccessControl::has_role(role, account)
    }

    #[view]
    fn get_admin() -> ContractAddress {
        AccessControl::get_admin()
    }

    #[external]
    fn grant_role(role: u128, account: ContractAddress) {
        AccessControl::grant_role(role, account);
    }

    #[external]
    fn revoke_role(role: u128, account: ContractAddress) {
        AccessControl::revoke_role(role, account);
    }

    #[external]
    fn renounce_role(role: u128) {
        AccessControl::renounce_role(role);
    }

    #[external]
    fn set_pending_admin(new_admin: ContractAddress) {
        AccessControl::set_pending_admin(new_admin);
    }

    #[external]
    fn accept_admin() {
        AccessControl::accept_admin();
    }
}
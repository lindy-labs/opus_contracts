#[starknet::contract]
mod Bond {
    use cmp::min;
    use starknet::{ContractAddress, get_block_timestamp, get_caller_address, get_contract_address};

    use opus::core::roles::BondRoles;

    use opus::interfaces::IBond::IBond;
    use opus::interfaces::IERC20::{IERC20, IERC20Dispatcher, IERC20DispatcherTrait};
    use opus::interfaces::IShrine::{IShrineDispatcher, IShrineDispatcherTrait};
    use opus::types::{AssetBalance, BondStatus};
    use opus::utils::access_control::{AccessControl, IAccessControl};
    use opus::utils::exp::exp;
    use opus::utils::math::pow;
    use opus::utils::wadray;
    use opus::utils::wadray::{Ray, RAY_ONE, Wad, WadZeroable};
    use opus::utils::wadray_signed;

    //
    // Constants
    //

    // 1 second / seconds in a year = 0.000000031709791984 (Wad)
    const SECONDS_DIV_YEAR: u128 = 31709791984;

    // Note that the debt ceiling for a Transmuter is enforced via the `yang_asset_max`
    // for the Transmuter's dummy token in Sentinel. Therefore, any changes to the 
    // debt ceiling can be made via `Sentinel.set_yang_asset_max`.
    #[storage]
    struct Storage {
        // The Shrine associated with this Transmuter
        shrine: IShrineDispatcher,
        // Number of assets added as collateral
        assets_count: u8,
        // Mapping from an asset address to its asset ID
        asset_id: LegacyMap::<ContractAddress, u8>,
        // Mapping from an asset ID to its IERC20 dispatcher
        assets: LegacyMap::<u8, IERC20Dispatcher>,
        // Price of all collateral assets
        price: Wad,
        // Interest rate to charge
        rate: Ray,
        // Threshold of this bond module
        threshold: Ray,
        // Debt ceiling for this module
        ceiling: Wad,
        // Amount borrowed
        borrowed: Wad,
        // Timestamp at which interest was last accrued
        last_charge_timestamp: u64,
        // Keeps track of whether the Bond is:
        // 1. Active: An active bond allows borrowing.
        // 2. Inactive: An inactive bond has zero debt, and does not allow borrowing.  
        // 3. Killed: A killed bond does not allow borrowing, and allows yin holders
        //            to claim a proportionate share of the bond's assets.
        // The only accepted state transition is from active to inactive or killed.
        status: BondStatus
    }

    //
    // Events
    //

    #[event]
    #[derive(Copy, Drop, starknet::Event, PartialEq)]
    enum Event {
        CeilingUpdated: CeilingUpdated,
        ThresholdUpdated: ThresholdUpdated,
        PriceUpdated: PriceUpdated,
        RateUpdated: RateUpdated,
        AssetAdded: AssetAdded,
        Borrow: Borrow,
        Repay: Repay,
        Charge: Charge,
        Liquidate: Liquidate,
        Settle: Settle,
        Close: Close,
        Killed: Killed,
        Reclaim: Reclaim,
    }

    #[derive(Copy, Drop, starknet::Event, PartialEq)]
    struct CeilingUpdated {
        old_ceiling: Wad,
        new_ceiling: Wad
    }

    #[derive(Copy, Drop, starknet::Event, PartialEq)]
    struct ThresholdUpdated {
        threshold: Ray
    }

    #[derive(Copy, Drop, starknet::Event, PartialEq)]
    struct PriceUpdated {
        price: Wad
    }

    #[derive(Copy, Drop, starknet::Event, PartialEq)]
    struct RateUpdated {
        rate: Ray
    }

    #[derive(Copy, Drop, starknet::Event, PartialEq)]
    struct AssetAdded {
        #[key]
        asset_id: u8,
        asset: ContractAddress
    }

    #[derive(Copy, Drop, starknet::Event, PartialEq)]
    struct Borrow {
        yin_amt: Wad
    }

    #[derive(Copy, Drop, starknet::Event, PartialEq)]
    struct Repay {
        yin_amt: Wad
    }

    #[derive(Copy, Drop, starknet::Event, PartialEq)]
    struct Charge {
        yin_amt: Wad
    }

    #[derive(Copy, Drop, starknet::Event, PartialEq)]
    struct Liquidate {}

    #[derive(Copy, Drop, starknet::Event, PartialEq)]
    struct Settle {
        deficit: Wad,
        excess: Wad,
        recipient: ContractAddress
    }

    #[derive(Copy, Drop, starknet::Event, PartialEq)]
    struct Close {}

    #[derive(Copy, Drop, starknet::Event, PartialEq)]
    struct Killed {}

    #[derive(Copy, Drop, starknet::Event, PartialEq)]
    struct Reclaim {
        #[key]
        user: ContractAddress,
        yin_amt: Wad,
        assets: Span<AssetBalance>
    }

    // Constructor

    #[constructor]
    fn constructor(
        ref self: ContractState,
        admin: ContractAddress,
        shrine: ContractAddress,
        rate: Ray,
        threshold: Ray,
        ceiling: Wad,
    ) {
        AccessControl::initializer(admin, Option::Some(BondRoles::default_admin_role()));

        self.shrine.write(IShrineDispatcher { contract_address: shrine });

        self.set_ceiling_helper(ceiling);
        self.set_rate_helper(rate);
        self.set_threshold_helper(threshold);

        self.last_charge_timestamp.write(get_block_timestamp());
    }

    #[external(v0)]
    impl IBondImpl of IBond<ContractState> {
        //
        // Getters
        //

        fn get_assets_count(self: @ContractState) -> u8 {
            self.assets_count.read()
        }

        fn get_assets(self: @ContractState) -> Span<ContractAddress> {
            let mut assets: Array<ContractAddress> = ArrayTrait::new();
            let loop_end: u8 = 0;
            let mut asset_id: u8 = self.assets_count.read();

            loop {
                if asset_id == loop_end {
                    break assets.span();
                }

                assets.append(self.assets.read(asset_id).contract_address);
            };

            assets.span()
        }

        fn get_ceiling(self: @ContractState) -> Wad {
            self.ceiling.read()
        }

        fn get_price(self: @ContractState) -> Wad {
            self.price.read()
        }

        fn get_rate(self: @ContractState) -> Ray {
            self.rate.read()
        }

        fn get_threshold(self: @ContractState) -> Ray {
            self.threshold.read()
        }

        fn get_borrowed(self: @ContractState) -> Wad {
            self.borrowed.read()
        }

        fn get_status(self: @ContractState) -> BondStatus {
            self.status.read()
        }

        //
        // View
        //

        fn is_healthy(self: @ContractState) -> bool {
            let ltv: Ray = wadray::rdiv_ww(self.borrowed.read(), self.price.read());
            ltv <= self.threshold.read()
        }

        //
        // Setters
        //

        fn set_ceiling(ref self: ContractState, ceiling: Wad) {
            AccessControl::assert_has_role(BondRoles::SET_CEILING);

            self.set_ceiling_helper(ceiling);
        }

        fn set_price(ref self: ContractState, price: Wad) {
            AccessControl::assert_has_role(BondRoles::SET_PRICE);

            self.price.write(price);

            self.emit(PriceUpdated { price });
        }

        fn set_rate(ref self: ContractState, rate: Ray) {
            AccessControl::assert_has_role(BondRoles::SET_RATE);

            self.set_threshold_helper(rate);
        }

        fn set_threshold(ref self: ContractState, threshold: Ray) {
            AccessControl::assert_has_role(BondRoles::SET_THRESHOLD);

            self.set_threshold_helper(threshold);
        }

        fn add_asset(ref self: ContractState, asset: ContractAddress) {
            AccessControl::assert_has_role(BondRoles::ADD_ASSET);

            assert(self.asset_id.read(asset).is_zero(), 'BO: Asset already added');
            let asset_id: u8 = self.assets_count.read() + 1;

            self.assets_count.write(asset_id);
            self.asset_id.write(asset, asset_id);
            self.assets.write(asset_id, IERC20Dispatcher { contract_address: asset });

            self.emit(AssetAdded { asset_id, asset });
        }

        // 
        // Core functions
        //

        fn borrow(ref self: ContractState, yin_amt: Wad) {
            AccessControl::assert_has_role(BondRoles::BORROW);

            // Assertions
            self.assert_active();

            self.charge_helper();
            assert(self.borrowed.read() + yin_amt <= self.ceiling.read(), 'BO: Ceiling exceeded');

            let ltv: Ray = wadray::rdiv_ww(self.borrowed.read() + yin_amt, self.price.read());
            assert(ltv <= self.threshold.read(), 'BO: Not healthy');

            // Start of logic
            self.borrowed.write(self.borrowed.read() + yin_amt);

            self.shrine.read().inject(get_caller_address(), yin_amt);

            self.emit(Borrow { yin_amt });
        }

        // Reduces the borrowed amount by the bond's yin balance
        fn repay(ref self: ContractState) {
            self.charge_helper();

            let bond: ContractAddress = get_contract_address();

            let shrine: IShrineDispatcher = self.shrine.read();
            let balance: Wad = shrine.get_yin(bond);
            let borrowed: Wad = self.borrowed.read();
            let capped_yin_amt: Wad = min(balance, borrowed);
            self.borrowed.write(borrowed - capped_yin_amt);

            shrine.eject(bond, capped_yin_amt);

            self.emit(Repay { yin_amt: capped_yin_amt });
        }

        // Charge interest and add the surplus to Shrine
        fn charge(ref self: ContractState) {
            self.assert_active();

            self.charge_helper();
        }

        // Repay all debt, transfer all assets to the recipient, and set bond status
        // to inactive.
        // This is intended to be called by the borrower who wishes to close this bond module.
        fn close(ref self: ContractState, recipient: ContractAddress) {
            AccessControl::assert_has_role(BondRoles::CLOSE);

            self.assert_active();

            self.repay();
            assert(self.borrowed.read().is_zero(), 'BO: Insufficent yin to close');

            self.status.write(BondStatus::Inactive);

            self.transfer_assets(recipient, RAY_ONE.into());

            let shrine: IShrineDispatcher = self.shrine.read();
            let excess: Wad = shrine.get_yin(get_contract_address());
            IERC20Dispatcher { contract_address: shrine.contract_address }
                .transfer(recipient, excess.into());

            self.emit(Close {})
        }


        // Liquidation occurs in two phases:
        // 1. `liquidate` sets the bond to inactive, and transfer the assets to an address
        //    for off-chain liquidation;
        // 2. after yin is transferred to the bond module after all liquidations, `settle` 
        //    pays down the outstanding debt, and if there is any deficit, it is accounted in Shrine
        fn liquidate(ref self: ContractState, recipient: ContractAddress) {
            AccessControl::assert_has_role(BondRoles::LIQUIDATE);

            self.assert_active();

            self.charge_helper();
            assert(!self.is_healthy(), 'BO: Bond is healthy');

            self.status.write(BondStatus::Inactive);

            self.transfer_assets(recipient, RAY_ONE.into());

            self.emit(Liquidate {})
        }

        fn settle(ref self: ContractState, recipient: ContractAddress) {
            AccessControl::assert_has_role(BondRoles::LIQUIDATE);

            assert(self.status.read() == BondStatus::Inactive, 'BO: Bond is not inactive');

            self.repay();

            let outstanding: Wad = self.borrowed.read();
            if outstanding.is_non_zero() {
                self.shrine.read().adjust_budget(SignedWad { val: outstanding.val, sign: true });
                self.borrowed.write(WadZeroable::zero());
            }

            let shrine: IShrineDispatcher = self.shrine.read();
            let excess: Wad = shrine.get_yin(get_contract_address());
            IERC20Dispatcher { contract_address: shrine.contract_address }
                .transfer(recipient, excess.into());

            self.emit(Settle { deficit: outstanding, excess, recipient });
        }

        //
        // Shutdown
        //

        // Killing the bond sets the status to `Killed`, and transfers the assets to an address
        // for off-chain liquidation. The liquidated value is expected to be transferred back to
        // this module in whichever form that can then be added via `add_asset`.
        fn kill(ref self: ContractState, recipient: ContractAddress) {
            AccessControl::assert_has_role(BondRoles::KILL);

            self.assert_active();

            self.status.write(BondStatus::Killed);

            self.transfer_assets(recipient, RAY_ONE.into());

            self.emit(Killed {});
        }

        // Note that the amount of asset that can be claimed is no longer pegged 1 : 1
        // because we do not make any assumptions as to the amount of assets held by the 
        // Transmuter.
        fn reclaim(ref self: ContractState, amount: Wad) {
            assert(self.status.read() == BondStatus::Killed, 'BO: Bond is not killed');

            let caller: ContractAddress = get_caller_address();

            let borrowed: Wad = self.borrowed.read();
            let pct_to_reclaim: Ray = wadray::rdiv_ww(amount, borrowed);

            self.borrowed.write(self.borrowed.read() - amount);

            self.shrine.read().eject(caller, amount);

            let reclaimed_assets: Span<AssetBalance> = self.transfer_assets(caller, pct_to_reclaim);

            self.emit(Reclaim { user: caller, yin_amt: amount, assets: reclaimed_assets });
        }
    }

    #[generate_trait]
    impl BondHelpers of BondHelpersTrait {
        #[inline(always)]
        fn assert_active(self: @ContractState) {
            assert(self.status.read() == BondStatus::Active, 'BO: Bond is not active');
        }

        fn set_rate_helper(ref self: ContractState, rate: Ray) {
            self.rate.write(rate);
            self.emit(RateUpdated { rate });
        }

        fn set_threshold_helper(ref self: ContractState, threshold: Ray) {
            self.threshold.read();
            self.emit(ThresholdUpdated { threshold });
        }

        fn set_ceiling_helper(ref self: ContractState, ceiling: Wad) {
            let old_ceiling: Wad = self.ceiling.read();
            self.ceiling.write(ceiling);

            self.emit(CeilingUpdated { old_ceiling, new_ceiling: ceiling });
        }

        fn charge_helper(ref self: ContractState) {
            let last_charged: u64 = self.last_charge_timestamp.read();
            let current_ts: u64 = get_block_timestamp();

            let t: Wad = Wad { val: (current_ts - last_charged).into() * SECONDS_DIV_YEAR };
            let start_debt: Wad = self.borrowed.read();
            let updated_debt: Wad = start_debt * exp(wadray::rmul_rw(self.rate.read(), t));

            self.last_charge_timestamp.write(current_ts);
            self.borrowed.write(updated_debt);

            let interest: Wad = updated_debt - start_debt;
            self.shrine.read().adjust_budget(interest.into());

            self.emit(Charge { yin_amt: interest });
        }

        fn transfer_assets(
            ref self: ContractState, recipient: ContractAddress, pct_to_transfer: Ray
        ) -> Span<AssetBalance> {
            let bond: ContractAddress = get_contract_address();

            let mut asset_balances: Array<AssetBalance> = ArrayTrait::new();

            let mut asset_id: u8 = self.assets_count.read();
            let loop_end: u8 = 0;

            loop {
                if asset_id == loop_end {
                    break;
                }

                let asset: IERC20Dispatcher = self.assets.read(asset_id);
                let balance: Wad = asset.balance_of(bond).try_into().unwrap();
                if balance.is_non_zero() {
                    let asset_amt: u128 = wadray::rmul_wr(balance, pct_to_transfer).val;
                    asset.transfer(recipient, asset_amt.into());

                    asset_balances
                        .append(AssetBalance { address: asset.contract_address, amount: asset_amt })
                }

                asset_id -= 1;
            };

            asset_balances.span()
        }
    }

    //
    // Public AccessControl functions
    //

    #[external(v0)]
    impl IAccessControlImpl of IAccessControl<ContractState> {
        fn get_roles(self: @ContractState, account: ContractAddress) -> u128 {
            AccessControl::get_roles(account)
        }

        fn has_role(self: @ContractState, role: u128, account: ContractAddress) -> bool {
            AccessControl::has_role(role, account)
        }

        fn get_admin(self: @ContractState) -> ContractAddress {
            AccessControl::get_admin()
        }

        fn get_pending_admin(self: @ContractState) -> ContractAddress {
            AccessControl::get_pending_admin()
        }

        fn grant_role(ref self: ContractState, role: u128, account: ContractAddress) {
            AccessControl::grant_role(role, account);
        }

        fn revoke_role(ref self: ContractState, role: u128, account: ContractAddress) {
            AccessControl::revoke_role(role, account);
        }

        fn renounce_role(ref self: ContractState, role: u128) {
            AccessControl::renounce_role(role);
        }

        fn set_pending_admin(ref self: ContractState, new_admin: ContractAddress) {
            AccessControl::set_pending_admin(new_admin);
        }

        fn accept_admin(ref self: ContractState) {
            AccessControl::accept_admin();
        }
    }
}

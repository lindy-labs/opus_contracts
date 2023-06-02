#[contract]
mod Caretaker {
    use array::{ArrayTrait, SpanTrait};
    use clone::Clone;
    use cmp::min;
    use option::OptionTrait;
    use starknet::{ContractAddress, get_block_timestamp, get_caller_address, get_contract_address};
    use traits::{Default, Into, TryInto};
    use zeroable::Zeroable;

    use aura::core::roles::CaretakerRoles;

    use aura::interfaces::IAbbot::{IAbbotDispatcher, IAbbotDispatcherTrait};
    use aura::interfaces::ICaretaker::ICaretaker;
    use aura::interfaces::IEqualizer::{IEqualizerDispatcher, IEqualizerDispatcherTrait};
    use aura::interfaces::IERC20::{IERC20Dispatcher, IERC20DispatcherTrait};
    use aura::interfaces::ISentinel::{ISentinelDispatcher, ISentinelDispatcherTrait};
    use aura::interfaces::IShrine::{IShrineDispatcher, IShrineDispatcherTrait};
    use aura::utils::access_control::AccessControl;
    use aura::utils::reentrancy_guard::ReentrancyGuard;
    use aura::utils::serde;
    use aura::utils::storage_access;
    use aura::utils::u256_conversions;
    use aura::utils::wadray;
    use aura::utils::wadray::{Ray, RAY_ONE, Wad};

    //
    // Constants
    //

    // A dummy trove ID for Caretaker
    const DUMMY_TROVE_ID: u64 = 0;

    #[starknet::storage]
    struct Storage {
        // Abbot associated with the Shrine for this Caretaker
        abbot: IAbbotDispatcher,
        // Equalizer associated with the Shrine for this Caretaker
        equalizer: IEqualizerDispatcher,
        // Sentinel associated with the Shrine for this Caretaker
        sentinel: ISentinelDispatcher,
        // Shrine associated with this Caretaker
        shrine: IShrineDispatcher,
        // Keeps track of whether Caretaker is live or killed
        is_live: bool,
    }

    //
    // Events
    //

    #[derive(Drop, starknet::Event)]
    enum Event {
        #[event]
        Shut: Shut,
        #[event]
        Release: Release,
        #[event]
        Reclaim: Reclaim,
    }

    #[derive(Drop, starknet::Event)]
    struct Shut {}

    #[derive(Drop, starknet::Event)]
    struct Release {
        user: ContractAddress,
        trove_id: u64,
        assets: Span<ContractAddress>,
        asset_amts: Span<u128>,
    }

    #[derive(Drop, starknet::Event)]
    struct Reclaim {
        user: ContractAddress,
        yin_amt: Wad,
        assets: Span<ContractAddress>,
        asset_amts: Span<u128>,
    }


    //
    // Constructor
    //

    #[constructor]
    fn constructor(
        ref self: Storage,
        admin: ContractAddress,
        shrine: ContractAddress,
        abbot: ContractAddress,
        sentinel: ContractAddress,
        equalizer: ContractAddress
    ) {
        AccessControl::initializer(admin);
        AccessControl::grant_role_internal(CaretakerRoles::default_admin_role(), admin);

        self.abbot.write(IAbbotDispatcher { contract_address: abbot });
        self.shrine.write(IShrineDispatcher { contract_address: shrine });
        self.sentinel.write(ISentinelDispatcher { contract_address: sentinel });
        self.equalizer.write(IEqualizerDispatcher { contract_address: equalizer });

        self.is_live.write(true);
    }

    impl ICaretakerImpl of ICaretaker<Storage> {
        //
        // View functions
        //

        fn get_live(self: @Storage) -> bool {
            self.is_live.read()
        }

        // Simulates the effects of `release` at the current on-chain conditions.
        fn preview_release(self: @Storage, trove_id: u64) -> (Span<ContractAddress>, Span<u128>) {
            assert(self.is_live.read() == false, 'System is live');

            // Calculate trove value using last price
            let sentinel: ISentinelDispatcher = self.sentinel.read();
            let yangs: Span<ContractAddress> = sentinel.get_yang_addresses();

            let shrine: IShrineDispatcher = self.shrine.read();
            let mut asset_amts: Array<u128> = Default::default();
            let mut yangs_copy = yangs;

            loop {
                match yangs_copy.pop_front() {
                    Option::Some(yang) => {
                        let deposited_yang: Wad = shrine.get_deposit(*yang, trove_id);

                        if deposited_yang.is_zero() {
                            asset_amts.append(0_u128);
                            continue;
                        }

                        let asset_amt: u128 = sentinel.preview_exit(*yang, deposited_yang);
                        asset_amts.append(asset_amt);
                    },
                    Option::None(_) => {
                        break (yangs, asset_amts.span());
                    },
                };
            }
        }

        // Simulates the effects of `reclaim` at the current on-chain conditions.
        fn preview_reclaim(self: @Storage, yin: Wad) -> (Span<ContractAddress>, Span<u128>) {
            assert(self.is_live.read() == false, 'System is live');

            let shrine: IShrineDispatcher = self.shrine.read();

            // Cap percentage of amount to be reclaimed to 100% to catch
            // invalid values beyond total yin
            let pct_to_reclaim: Ray = wadray::rdiv_ww(yin, shrine.get_total_yin());
            let capped_pct: Ray = min(pct_to_reclaim, RAY_ONE.into());

            let yangs: Span<ContractAddress> = self.sentinel.read().get_yang_addresses();

            let mut asset_amts: Array<u128> = Default::default();
            let caretaker = get_contract_address();
            let mut yangs_copy = yangs;

            loop {
                match yangs_copy.pop_front() {
                    Option::Some(yang) => {
                        let asset = IERC20Dispatcher { contract_address: *yang };
                        let caretaker_balance: u128 = asset
                            .balance_of(caretaker)
                            .try_into()
                            .unwrap();
                        let asset_amt: Wad = wadray::rmul_rw(
                            pct_to_reclaim, caretaker_balance.into()
                        );

                        if asset_amt.is_zero() {
                            asset_amts.append(0_u128);
                            continue;
                        }

                        asset_amts.append(asset_amt.val);
                    },
                    Option::None(_) => {
                        break (yangs, asset_amts.span());
                    },
                };
            }
        }

        //
        // External
        //

        // Admin will initially have access to `terminate`. At a later date, this access will be
        // transferred to a new module that allows users to irreversibly deposit AURA tokens to
        // trigger this emergency shutdown.
        #[external]
        fn shut(ref self: Storage) {
            AccessControl::assert_has_role(CaretakerRoles::SHUT);

            // Prevent repeated `shut`
            assert(self.is_live.read() == true, 'Caretaker is not live');

            // Mint surplus debt
            // Note that the total debt may stil be higher than total yin after this final
            // minting of surplus debt due to loss of precision. Any excess debt is ignored
            // because trove owners can withdraw all excess collateral in their trove after 
            // assets needed to back total yin supply has been transferred to the Caretaker.
            self.equalizer.read().equalize();

            let shrine: IShrineDispatcher = self.shrine.read();

            // Calculate the percentage of collateral needed to back yin 1 : 1
            // based on the last value of all collateral in Shrine
            let (_, total_value) = shrine.get_shrine_threshold_and_value();
            let backing_pct: Ray = wadray::rdiv_ww(shrine.get_total_yin(), total_value);

            // Cap the percentage to 100%
            let capped_backing_pct: Ray = min(backing_pct, RAY_ONE.into());

            // Loop through yangs and transfer the amount of each yang asset needed
            // to back yin to this contract.
            // This is equivalent to a final redistribution enforced on all trove
            // owners.
            // Since yang assets are transferred out of the Gate and the total number 
            // of yang is not updated in Shrine, the asset amount per yang will decrease. 
            let sentinel: ISentinelDispatcher = self.sentinel.read();
            let mut yangs: Span<ContractAddress> = sentinel.get_yang_addresses();
            let caretaker = get_contract_address();

            loop {
                match yangs.pop_front() {
                    Option::Some(yang) => {
                        let backed_yang: Wad = wadray::rmul_rw(
                            capped_backing_pct, shrine.get_yang_total(*yang)
                        );
                        sentinel.exit(*yang, caretaker, DUMMY_TROVE_ID, backed_yang);
                    },
                    Option::None(_) => {
                        break;
                    },
                };
            };

            // Kill modules
            self.is_live.write(false);
            shrine.kill();

            // Note that Absorber is not killed. When the final debt surplus is minted, the
            // absorber may be an allocated recipient. If the Absorber has been completely
            // drained (i.e. no shares in current epoch), receives a portion of the minted
            // debt surplus and is killed, then the final yin surplus will be inaccessible
            // if users can no longer call `Absorber.provide()`. Therefore, we do not kill
            // the Absorber, and allow the first provider in such a situation to gain a windfall
            // of the final debt surplus minted to the Absorber.

            let shut_time: u64 = get_block_timestamp();
            self.emit(Event::Shut(Shut{}));
        }

        // Releases all remaining collateral in a trove to the trove owner directly.
        // - Note that after `shut` is triggered, the amount of yang in a trove will be fixed, 
        //   but the asset amount per yang may have decreased because the assets needed to back 
        //   yin 1 : 1 have been transferred from the Gates to the Caretaker.
        // Returns a tuple of arrays of the released asset addresses and released asset amounts
        // denominated in each respective asset's decimals.
        #[external]
        fn release(ref self: Storage, trove_id: u64) -> (Span<ContractAddress>, Span<u128>) {
            assert(self.is_live.read() == false, 'System is live');

            // reentrancy guard is used as a precaution
            ReentrancyGuard::start();

            // Assert caller is trove owner
            let trove_owner: ContractAddress = self.abbot.read().get_trove_owner(trove_id);
            assert(trove_owner == get_caller_address(), 'Not trove owner');

            let sentinel: ISentinelDispatcher = self.sentinel.read();
            let yangs: Span<ContractAddress> = sentinel.get_yang_addresses();

            let shrine: IShrineDispatcher = self.shrine.read();
            let mut asset_amts: Array<u128> = Default::default();
            let mut yangs_copy = yangs;

            // Loop over yangs deposited in trove and transfer to trove owner
            loop {
                match yangs_copy.pop_front() {
                    Option::Some(yang) => {
                        let deposited_yang: Wad = shrine.get_deposit(*yang, trove_id);

                        if deposited_yang.is_zero() {
                            asset_amts.append(0_u128);
                            continue;
                        }

                        let asset_amt: u128 = sentinel
                            .exit(*yang, trove_owner, trove_id, deposited_yang);
                        // Seize the collateral only after assets have been transferred so that the asset 
                        // amount per yang in Gate does not change and user receives the correct amount
                        shrine.seize(*yang, trove_id, deposited_yang);

                        asset_amts.append(asset_amt);
                    },
                    Option::None(_) => {
                        break;
                    },
                };
            };

            self.emit(Event::Release(Release{user: trove_owner, trove_id, assets: yangs, asset_amts: asset_amts.span()}));
            ReentrancyGuard::end();
            (yangs, asset_amts.span())
        }

        // Allow yin holders to burn their yin and receive their proportionate share of collateral assets
        // in the Caretaker contract based on the amount of yin as a proportion of total supply.
        // Example: assuming total system yin of 1_000, and Caretaker has a yang A asset balance of 4_000.
        //          User A and User B each wants to reclaim 100 yin, and expects to receive the same amount 
        //          of yang assets from the Caretaker regardless of who does so first.
        //          1. User A reclaims 100 yin, amounting to 100 / 1_000 = 10%, which entitles him to receive 
        //             10% * 4_000 = 400 yang A assets from the Caretaker.
        //          
        //             After User A reclaims, total system yin decreaes to 900, and the Caretaker's balance of
        //             yang A assets decreases to 3_600.
        //
        //          2. User B reclaims 100 yin, amounting to 100 / 900 = 11.11%, which entitles him to receive 
        //             11.1% * 3_600 = 400 yang A assets approximately.
        //              
        // Returns a tuple of arrays of the reclaimed asset addresses and reclaimed asset amounts denominated 
        // in each respective asset's decimals.
        #[external]
        fn reclaim(ref self: Storage, yin: Wad) -> (Span<ContractAddress>, Span<u128>) {
            assert(self.is_live.read() == false, 'System is live');

            // reentrancy guard is used as a precaution
            ReentrancyGuard::start();

            let caller = get_caller_address();
            let shrine: IShrineDispatcher = self.shrine.read();

            // Cap the amount reclaimed to the caller's balance
            let burn_amt: Wad = min(yin, shrine.get_yin(caller));

            // Calculate percentage of amount to be reclaimed out of total yin
            let pct_to_reclaim: Ray = wadray::rdiv_ww(burn_amt, shrine.get_total_yin());

            let yangs: Span<ContractAddress> = self.sentinel.read().get_yang_addresses();

            let mut asset_amts: Array<u128> = Default::default();
            let caretaker = get_contract_address();
            let mut yangs_copy = yangs;

            // Burn the reclaimed yin amount from the caller
            shrine.eject(caller, burn_amt);

            // Loop through yangs and transfer a proportionate share of each 
            // yang asset in the Caretaker to caller
            loop {
                match yangs_copy.pop_front() {
                    Option::Some(yang) => {
                        let asset = IERC20Dispatcher { contract_address: *yang };
                        let caretaker_balance: u128 = asset
                            .balance_of(caretaker)
                            .try_into()
                            .unwrap();
                        let asset_amt: Wad = wadray::rmul_rw(
                            pct_to_reclaim, caretaker_balance.into()
                        );

                        if asset_amt.is_zero() {
                            asset_amts.append(0_u128);
                            continue;
                        }

                        let success: bool = asset.transfer(caller, asset_amt.val.into());
                        assert(success, 'Asset transfer failed');
                        asset_amts.append(asset_amt.val);
                    },
                    Option::None(_) => {
                        break;
                    },
                };
            };

            self.emit(Event::Reclaim(Reclaim{user: caller, yin_amt: burn_amt, assets: yangs, asset_amts: asset_amts.span()}));
            ReentrancyGuard::end();
            (yangs, asset_amts.span())
        }
    }
}

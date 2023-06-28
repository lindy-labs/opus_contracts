#[contract]
mod Settler {
    use array::{ArrayTrait, SpanTrait};
    use cmp::min;
    use option::OptionTrait;
    use starknet::{ContractAddress, get_caller_address};
    use traits::{Default, Into};
    use zeroable::Zeroable;

    use aura::core::sentinel::Sentinel;

    use aura::interfaces::ISentinel::{ISentinelDispatcher, ISentinelDispatcherTrait};
    use aura::interfaces::IShrine::{IShrineDispatcher, IShrineDispatcherTrait};
    use aura::utils::access_control::{IAccessControlDispatcher, IAccessControlDispatcherTrait};
    use aura::utils::serde;
    use aura::utils::wadray;
    use aura::utils::wadray::{Ray, Wad, WadZeroable};

    struct Storage {
        // The Shrine instance this module is associated with
        shrine: IShrineDispatcher,
        // The Sentinel instance that is associated with the Shrine
        sentinel: ISentinelDispatcher,
        // Stores the amount of yang currently belonging to the protocol
        // The start value is the initial yang amount that is minted via `Sentinel.add_yang`
        // and is fetched from the Sentinel
        protocol_yang_amt: LegacyMap::<ContractAddress, Wad>,
        // Stores the amount of debt redistributed to the initial yang amount
        // for all yangs, up to the current redistribution ID
        // (yang_address) -> (total debt redistributed)
        cumulative_redistributed_debt: Wad,
        // Stores the last redistribution ID that has been accounted for
        last_redistribution_id: u32,
        // Stores the amount of debt repaid
        cumulative_repaid_debt: Wad,
    }

    //
    // Constants
    //

    // Dummy trove ID to be used for Sentinel
    const DUMMY_TROVE_ID: u64 = 0;

    //
    // Events
    //

    #[event]
    fn YangAdded(yang_address: ContractAddress, initial_yang_amt: Wad) {}

    #[event]
    fn Recall(
        yangs: Span<ContractAddress>,
        remaining_yang_amts: Span<Wad>,
        withdrawn_asset_amts: Span<u128>
    ) {}

    #[event]
    fn Record(debt: Wad, last_redistribution_id: u32) {}

    #[event]
    fn Settle(settler: ContractAddress, amt: Wad) {}

    //
    // Constructor
    //

    #[constructor]
    fn constructor(admin: ContractAddress, shrine: ContractAddress, sentinel: ContractAddress) {
        shrine::write(IShrineDispatcher { contract_address: shrine });
        sentinel::write(ISentinelDispatcher { contract_address: sentinel });
    }

    //
    // View
    //

    #[view]
    fn get_outstanding_debt() -> Wad {
        cumulative_redistributed_debt::read() - cumulative_repaid_debt::read()
    }

    //
    // External
    //

    // Update the cumulative redistributed debt to the latest redistribution
    #[external]
    fn record() {
        let shrine: IShrineDispatcher = shrine::read();
        let sentinel: ISentinelDispatcher = sentinel::read();

        let latest_redistribution_id: u32 = shrine.get_redistributions_count();
        let last_redistribution_id: u32 = last_redistribution_id::read();

        if last_redistribution_id == latest_redistribution_id {
            return;
        }

        let mut yang_addresses: Span<ContractAddress> = sentinel.get_yang_addresses();
        let mut debt_increment: Wad = WadZeroable::zero();

        loop {
            match yang_addresses.pop_front() {
                Option::Some(yang) => {
                    let mut current_redistribution_id = last_redistribution_id;

                    let mut yang_amt: Wad = protocol_yang_amt::read(*yang);
                    if yang_amt.is_zero() {
                        // If it is a new yang that has not been accounted for in this module, then read
                        // the initial yang amount from the Sentinel and update in storage.
                        yang_amt = sentinel.get_initial_yang_amt(*yang);
                        protocol_yang_amt::write(*yang, yang_amt);
                    }
                    loop {
                        if current_redistribution_id == latest_redistribution_id {
                            break;
                        }

                        current_redistribution_id += 1;

                        let yang_unit_debt: Wad = shrine
                            .get_redistributed_unit_debt_for_yang(*yang, current_redistribution_id);
                        debt_increment += yang_amt * yang_unit_debt;
                    };
                },
                Option::None(_) => {
                    break;
                }
            };
        };

        let cumulative_redistributed_debt: Wad = cumulative_redistributed_debt::read();
        cumulative_redistributed_debt::write(cumulative_redistributed_debt + debt_increment);
        last_redistribution_id::write(latest_redistribution_id);

        Record(debt_increment, latest_redistribution_id);
    }

    // Pay down outstanding debt from the caller's yin
    #[external]
    fn settle(amt: Wad) {
        record();

        let caller: ContractAddress = get_caller_address();
        let mut cumulative_repaid_debt: Wad = cumulative_repaid_debt::read();
        // Cap the amount to the outstanding debt
        let repay_amt: Wad = min(
            amt, cumulative_redistributed_debt::read() - cumulative_repaid_debt
        );
        cumulative_repaid_debt::write(cumulative_repaid_debt + repay_amt);

        shrine::read().eject(caller, amt);

        Settle(caller, repay_amt);
    }

    // Release all redistributed yang assets to the Shrine's admin, while ensuring
    // that an amount of yang equivalent to the minimum initial deposit remains in the
    // protocol to guard against the first depositor front-running exploit.
    #[external]
    fn recall() {
        let sentinel: ISentinelDispatcher = sentinel::read();
        let yangs: Span<ContractAddress> = sentinel.get_yang_addresses();
        let mut remaining_yang_amts: Array<Wad> = Default::default();
        let mut withdrawn_asset_amts: Array<u128> = Default::default();

        let shrine_ac = IAccessControlDispatcher {
            contract_address: shrine::read().contract_address
        };
        let recipient: ContractAddress = shrine_ac.get_admin();

        let mut yangs_copy = yangs;
        loop {
            match yangs_copy.pop_front() {
                Option::Some(yang) => {
                    let mut yang_amt: Wad = protocol_yang_amt::read(*yang);
                    if yang_amt.is_zero() {
                        // If it is a new yang that has not been accounted for in this module, then read
                        // the initial yang amount from the Sentinel and update in storage.
                        yang_amt = sentinel.get_initial_yang_amt(*yang);
                    }

                    let current_asset_amt: u128 = sentinel.preview_exit(*yang, yang_amt);

                    let withdrawable_asset_amt: u128 = current_asset_amt
                        - Sentinel::INITIAL_DEPOSIT_AMT;
                    let pct_to_withdraw: Ray = withdrawable_asset_amt.into()
                        / current_asset_amt.into();
                    let yang_to_withdraw: Wad = wadray::rmul_wr(yang_amt, pct_to_withdraw);

                    let remaining_yang_amt: Wad = yang_amt - yang_to_withdraw;
                    protocol_yang_amt::write(*yang, remaining_yang_amt);
                    remaining_yang_amts.append(remaining_yang_amt);

                    let asset_amt: u128 = sentinel
                        .exit(*yang, recipient, DUMMY_TROVE_ID, yang_to_withdraw);
                    withdrawn_asset_amts.append(asset_amt);
                },
                Option::None(_) => {
                    break;
                },
            };
        };

        Recall(yangs, remaining_yang_amts.span(), withdrawn_asset_amts.span());
    }
}

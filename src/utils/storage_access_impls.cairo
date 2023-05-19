use option::OptionTrait;
use starknet::ContractAddress;
use starknet::contract_address;
use starknet::{StorageAccess, StorageBaseAddress, SyscallResult};
use starknet::syscalls::{storage_read_syscall, storage_write_syscall};
use starknet::storage_access::storage_address_from_base_and_offset;
use traits::{Into, TryInto};

use aura::interfaces::IAbsorber::IBlesserDispatcher;
use aura::utils::misc::BoolIntoFelt252;
use aura::utils::types::{AssetApportion, Reward, Provision, Request, Trove, YangRedistribution};
use aura::utils::wadray::{Ray, Wad};

// Storage Access
impl WadStorageAccess of StorageAccess<Wad> {
    fn write(address_domain: u32, base: StorageBaseAddress, value: Wad) -> SyscallResult::<()> {
        StorageAccess::write(address_domain, base, value.val)
    }

    fn read(address_domain: u32, base: StorageBaseAddress) -> SyscallResult::<Wad> {
        Result::Ok(
            Wad {
                val: storage_read_syscall(
                    address_domain, storage_address_from_base_and_offset(base, 0_u8)
                )?.try_into().unwrap(),
            }
        )
    }
}

impl RayStorageAccess of StorageAccess<Ray> {
    fn write(address_domain: u32, base: StorageBaseAddress, value: Ray) -> SyscallResult::<()> {
        StorageAccess::write(address_domain, base, value.val)
    }

    fn read(address_domain: u32, base: StorageBaseAddress) -> SyscallResult::<Ray> {
        Result::Ok(
            Ray {
                val: storage_read_syscall(
                    address_domain, storage_address_from_base_and_offset(base, 0_u8)
                )?.try_into().unwrap(),
            }
        )
    }
}

impl TroveStorageAccess of StorageAccess<Trove> {
    fn read(address_domain: u32, base: StorageBaseAddress) -> SyscallResult::<Trove> {
        Result::Ok(
            Trove {
                charge_from: storage_read_syscall(
                    address_domain, storage_address_from_base_and_offset(base, 0_u8)
                )?.try_into().unwrap(),
                debt: Wad {
                    val: storage_read_syscall(
                        address_domain, storage_address_from_base_and_offset(base, 1_u8)
                    )?.try_into().unwrap()
                },
                last_rate_era: storage_read_syscall(
                    address_domain, storage_address_from_base_and_offset(base, 2_u8)
                )?.try_into().unwrap(),
            }
        )
    }

    fn write(address_domain: u32, base: StorageBaseAddress, value: Trove) -> SyscallResult::<()> {
        storage_write_syscall(
            address_domain,
            storage_address_from_base_and_offset(base, 0_u8),
            value.charge_from.into()
        )?;
        storage_write_syscall(
            address_domain, storage_address_from_base_and_offset(base, 1_u8), value.debt.val.into()
        )?;
        storage_write_syscall(
            address_domain,
            storage_address_from_base_and_offset(base, 2_u8),
            value.last_rate_era.into()
        )
    }
}

type U128Tuple = (u128, u128);

impl U128TupleStorageAccess of StorageAccess<U128Tuple> {
    fn read(address_domain: u32, base: StorageBaseAddress) -> SyscallResult::<U128Tuple> {
        let first_val = storage_read_syscall(
            address_domain, storage_address_from_base_and_offset(base, 0_u8)
        )?.try_into().unwrap();
        let second_val = storage_read_syscall(
            address_domain, storage_address_from_base_and_offset(base, 1_u8)
        )?.try_into().unwrap();

        Result::Ok((first_val, second_val))
    }

    fn write(
        address_domain: u32, base: StorageBaseAddress, value: U128Tuple
    ) -> SyscallResult::<()> {
        let (first_val, second_val) = value;

        storage_write_syscall(
            address_domain, storage_address_from_base_and_offset(base, 0_u8), first_val.into()
        )?;
        storage_write_syscall(
            address_domain, storage_address_from_base_and_offset(base, 1_u8), second_val.into()
        )
    }
}

type WadTuple = (Wad, Wad);

impl WadTupleStorageAccess of StorageAccess<WadTuple> {
    fn read(address_domain: u32, base: StorageBaseAddress) -> SyscallResult::<WadTuple> {
        let (first_val, second_val) = U128TupleStorageAccess::read(address_domain, base)?;
        Result::Ok((Wad { val: first_val }, Wad { val: second_val }))
    }

    fn write(
        address_domain: u32, base: StorageBaseAddress, value: WadTuple
    ) -> SyscallResult::<()> {
        let (first_wad, second_wad) = value;
        U128TupleStorageAccess::write(address_domain, base, (first_wad.val, second_wad.val))
    }
}

type RayTuple = (Ray, Ray);

impl RayTupleStorageAccess of StorageAccess<RayTuple> {
    fn read(address_domain: u32, base: StorageBaseAddress) -> SyscallResult::<RayTuple> {
        let (first_val, second_val) = U128TupleStorageAccess::read(address_domain, base)?;
        Result::Ok((Ray { val: first_val }, Ray { val: second_val }))
    }

    fn write(
        address_domain: u32, base: StorageBaseAddress, value: RayTuple
    ) -> SyscallResult::<()> {
        let (first_ray, second_ray) = value;
        U128TupleStorageAccess::write(address_domain, base, (first_ray.val, second_ray.val))
    }
}

impl YangRedistributionStorageAccess of StorageAccess<YangRedistribution> {
    fn read(address_domain: u32, base: StorageBaseAddress) -> SyscallResult::<YangRedistribution> {
        let (unit_debt, error) = WadTupleStorageAccess::read(address_domain, base)?;
        Result::Ok(YangRedistribution { unit_debt, error })
    }

    fn write(
        address_domain: u32, base: StorageBaseAddress, value: YangRedistribution
    ) -> SyscallResult::<()> {
        WadTupleStorageAccess::write(address_domain, base, (value.unit_debt, value.error))
    }
}

impl AssetApportionStorageAccess of StorageAccess<AssetApportion> {
    fn read(address_domain: u32, base: StorageBaseAddress) -> SyscallResult::<AssetApportion> {
        let (asset_amt_per_share, error) = U128TupleStorageAccess::read(address_domain, base)?;
        Result::Ok(AssetApportion { asset_amt_per_share, error })
    }

    fn write(
        address_domain: u32, base: StorageBaseAddress, value: AssetApportion
    ) -> SyscallResult::<()> {
        U128TupleStorageAccess::write(
            address_domain, base, (value.asset_amt_per_share, value.error)
        )
    }
}


// TODO: Double check that this implementation actually works
impl RewardStorageAccess of StorageAccess<Reward> {
    fn read(address_domain: u32, base: StorageBaseAddress) -> SyscallResult::<Reward> {
        let asset: ContractAddress = storage_read_syscall(
            address_domain, storage_address_from_base_and_offset(base, 0_u8)
        )?.try_into().unwrap();
        let blesser: IBlesserDispatcher = IBlesserDispatcher {
            contract_address: storage_read_syscall(
                address_domain, storage_address_from_base_and_offset(base, 1_u8)
            )?.try_into().unwrap()
        };
        let is_active_raw: felt252 = storage_read_syscall(
            address_domain, storage_address_from_base_and_offset(base, 2_u8)
        )?;

        Result::Ok(Reward { asset: asset, blesser: blesser, is_active: is_active_raw != 0 })
    }

    fn write(address_domain: u32, base: StorageBaseAddress, value: Reward) -> SyscallResult::<()> {
        storage_write_syscall(
            address_domain, storage_address_from_base_and_offset(base, 0_u8), value.asset.into()
        )?;
        storage_write_syscall(
            address_domain,
            storage_address_from_base_and_offset(base, 1_u8),
            value.blesser.contract_address.into()
        )?;

        storage_write_syscall(
            address_domain, storage_address_from_base_and_offset(base, 2_u8), value.is_active.into()
        )
    }
}

impl ProvisionStorageAccess of StorageAccess<Provision> {
    fn read(address_domain: u32, base: StorageBaseAddress) -> SyscallResult::<Provision> {
        let epoch = storage_read_syscall(
            address_domain, storage_address_from_base_and_offset(base, 0_u8)
        )?.try_into().unwrap();
        let shares_val = storage_read_syscall(
            address_domain, storage_address_from_base_and_offset(base, 1_u8)
        )?.try_into().unwrap();

        Result::Ok(Provision { epoch, shares: Wad { val: shares_val } })
    }

    fn write(
        address_domain: u32, base: StorageBaseAddress, value: Provision
    ) -> SyscallResult::<()> {
        storage_write_syscall(
            address_domain, storage_address_from_base_and_offset(base, 0_u8), value.epoch.into()
        )?;
        storage_write_syscall(
            address_domain,
            storage_address_from_base_and_offset(base, 1_u8),
            value.shares.val.into()
        )
    }
}

impl RequestStorageAccess of StorageAccess<Request> {
    fn read(address_domain: u32, base: StorageBaseAddress) -> SyscallResult::<Request> {
        let timestamp = storage_read_syscall(
            address_domain, storage_address_from_base_and_offset(base, 0_u8)
        )?.try_into().unwrap();
        let timelock = storage_read_syscall(
            address_domain, storage_address_from_base_and_offset(base, 1_u8)
        )?.try_into().unwrap();
        let has_removed_raw = storage_read_syscall(
            address_domain, storage_address_from_base_and_offset(base, 2_u8)
        )?;

        Result::Ok(Request { timestamp, timelock, has_removed: has_removed_raw != 0 })
    }

    fn write(address_domain: u32, base: StorageBaseAddress, value: Request) -> SyscallResult::<()> {
        storage_write_syscall(
            address_domain, storage_address_from_base_and_offset(base, 0_u8), value.timestamp.into()
        )?;
        storage_write_syscall(
            address_domain, storage_address_from_base_and_offset(base, 1_u8), value.timelock.into()
        )?;
        storage_write_syscall(
            address_domain,
            storage_address_from_base_and_offset(base, 2_u8),
            value.has_removed.into()
        )
    }
}

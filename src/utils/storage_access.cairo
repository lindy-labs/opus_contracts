use option::OptionTrait;
use starknet::{StorageAccess, StorageBaseAddress, SyscallResult};
use starknet::storage_access::storage_address_from_base_and_offset;
use starknet::syscalls::{storage_read_syscall, storage_write_syscall};
use traits::{Into, TryInto};

use aura::utils::types::{Trove, YangRedistribution};
use aura::utils::wadray::{Ray, Wad};

// Storage Access
impl WadStorageAccess of StorageAccess<Wad> {
    #[inline(always)]
    fn read(address_domain: u32, base: StorageBaseAddress) -> SyscallResult::<Wad> {
        Result::Ok(
            Wad {
                val: storage_read_syscall(
                    address_domain, storage_address_from_base_and_offset(base, 0_u8)
                )?.try_into().unwrap(),
            }
        )
    }

    #[inline(always)]
    fn write(address_domain: u32, base: StorageBaseAddress, value: Wad) -> SyscallResult::<()> {
        StorageAccess::write(address_domain, base, value.val)
    }

    fn read_at_offset_internal(
        address_domain: u32, base: StorageBaseAddress, offset: u8
    ) -> SyscallResult<Wad> {
        Result::Ok(
            Wad { val: StorageAccess::read_at_offset_internal(address_domain, base, offset)? }
        )
    }

    fn write_at_offset_internal(
        address_domain: u32, base: StorageBaseAddress, offset: u8, value: Wad
    ) -> SyscallResult<()> {
        StorageAccess::write_at_offset_internal(address_domain, base, offset, value.val)
    }

    fn size_internal(value: Wad) -> u8 {
        1
    }
}

impl RayStorageAccess of StorageAccess<Ray> {
    #[inline(always)]
    fn read(address_domain: u32, base: StorageBaseAddress) -> SyscallResult::<Ray> {
        Result::Ok(
            Ray {
                val: storage_read_syscall(
                    address_domain, storage_address_from_base_and_offset(base, 0_u8)
                )?.try_into().unwrap(),
            }
        )
    }

    #[inline(always)]
    fn write(address_domain: u32, base: StorageBaseAddress, value: Ray) -> SyscallResult::<()> {
        StorageAccess::write(address_domain, base, value.val)
    }

    #[inline(always)]
    fn read_at_offset_internal(
        address_domain: u32, base: StorageBaseAddress, offset: u8
    ) -> SyscallResult<Ray> {
        Result::Ok(
            Ray { val: StorageAccess::read_at_offset_internal(address_domain, base, offset)? }
        )
    }

    #[inline(always)]
    fn write_at_offset_internal(
        address_domain: u32, base: StorageBaseAddress, offset: u8, value: Ray
    ) -> SyscallResult<()> {
        StorageAccess::write_at_offset_internal(address_domain, base, offset, value.val)
    }

    #[inline(always)]
    fn size_internal(value: Ray) -> u8 {
        1
    }
}

impl TroveStorageAccess of StorageAccess<Trove> {
    #[inline(always)]
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

    #[inline(always)]
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

    #[inline(always)]
    fn read_at_offset_internal(
        address_domain: u32, base: StorageBaseAddress, offset: u8
    ) -> SyscallResult<Trove> {
        let charge_from: u64 = StorageAccess::read_at_offset_internal(
            address_domain, base, offset
        )?;

        let offset = offset + StorageAccess::size_internal(charge_from);
        let debt: Wad = StorageAccess::read_at_offset_internal(address_domain, base, offset)?;

        let offset = offset + StorageAccess::size_internal(debt);
        let last_rate_era: u64 = StorageAccess::read_at_offset_internal(
            address_domain, base, offset
        )?;

        Result::Ok(Trove { charge_from, debt, last_rate_era })
    }

    #[inline(always)]
    fn write_at_offset_internal(
        address_domain: u32, base: StorageBaseAddress, offset: u8, value: Trove
    ) -> SyscallResult<()> {
        StorageAccess::write_at_offset_internal(address_domain, base, offset, value.charge_from)?;

        let offset = offset + StorageAccess::size_internal(value.charge_from);
        StorageAccess::write_at_offset_internal(address_domain, base, offset, value.debt)?;

        let offset = offset + StorageAccess::size_internal(value.debt);
        StorageAccess::write_at_offset_internal(address_domain, base, offset, value.last_rate_era)
    }

    #[inline(always)]
    fn size_internal(value: Trove) -> u8 {
        StorageAccess::size_internal(value.charge_from)
            + StorageAccess::size_internal(value.debt)
            + StorageAccess::size_internal(value.last_rate_era)
    }
}

type U128Tuple = (u128, u128);

impl U128TupleStorageAccess of StorageAccess<U128Tuple> {
    #[inline(always)]
    fn read(address_domain: u32, base: StorageBaseAddress) -> SyscallResult::<U128Tuple> {
        let first_val = storage_read_syscall(
            address_domain, storage_address_from_base_and_offset(base, 0_u8)
        )?.try_into().unwrap();
        let second_val = storage_read_syscall(
            address_domain, storage_address_from_base_and_offset(base, 1_u8)
        )?.try_into().unwrap();

        Result::Ok((first_val, second_val))
    }

    #[inline(always)]
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

    #[inline(always)]
    fn read_at_offset_internal(
        address_domain: u32, base: StorageBaseAddress, offset: u8
    ) -> SyscallResult<U128Tuple> {
        Result::Ok(
            (
                StorageAccess::read_at_offset_internal(address_domain, base, offset)?,
                StorageAccess::read_at_offset_internal(address_domain, base, offset + 1)?
            )
        )
    }

    #[inline(always)]
    fn write_at_offset_internal(
        address_domain: u32, base: StorageBaseAddress, offset: u8, value: U128Tuple
    ) -> SyscallResult<()> {
        let (v0, v1) = value;
        StorageAccess::write_at_offset_internal(address_domain, base, offset, v0)?;
        StorageAccess::write_at_offset_internal(
            address_domain, base, offset + StorageAccess::<u128>::size_internal(v0), v1
        )
    }

    #[inline(always)]
    fn size_internal(value: U128Tuple) -> u8 {
        let (v0, v1) = value;
        StorageAccess::size_internal(v0) + StorageAccess::size_internal(v1)
    }
}

type WadTuple = (Wad, Wad);

impl WadTupleStorageAccess of StorageAccess<WadTuple> {
    #[inline(always)]
    fn read(address_domain: u32, base: StorageBaseAddress) -> SyscallResult::<WadTuple> {
        let (first_val, second_val) = U128TupleStorageAccess::read(address_domain, base)?;
        Result::Ok((Wad { val: first_val }, Wad { val: second_val }))
    }

    #[inline(always)]
    fn write(
        address_domain: u32, base: StorageBaseAddress, value: WadTuple
    ) -> SyscallResult::<()> {
        let (first_wad, second_wad) = value;
        U128TupleStorageAccess::write(address_domain, base, (first_wad.val, second_wad.val))
    }

    #[inline(always)]
    fn read_at_offset_internal(
        address_domain: u32, base: StorageBaseAddress, offset: u8
    ) -> SyscallResult<WadTuple> {
        let (v0, v1) = StorageAccess::<U128Tuple>::read_at_offset_internal(
            address_domain, base, offset
        )?;
        Result::Ok((Wad { val: v0 }, Wad { val: v1 }))
    }

    #[inline(always)]
    fn write_at_offset_internal(
        address_domain: u32, base: StorageBaseAddress, offset: u8, value: WadTuple
    ) -> SyscallResult<()> {
        let (w0, w1) = value;
        StorageAccess::<U128Tuple>::write_at_offset_internal(
            address_domain, base, offset, (w0.val, w1.val)
        )
    }

    #[inline(always)]
    fn size_internal(value: WadTuple) -> u8 {
        let (w0, w1) = value;
        StorageAccess::<U128Tuple>::size_internal((w0.val, w1.val))
    }
}

type RayTuple = (Ray, Ray);

impl RayTupleStorageAccess of StorageAccess<RayTuple> {
    #[inline(always)]
    fn read(address_domain: u32, base: StorageBaseAddress) -> SyscallResult::<RayTuple> {
        let (first_val, second_val) = U128TupleStorageAccess::read(address_domain, base)?;
        Result::Ok((Ray { val: first_val }, Ray { val: second_val }))
    }

    #[inline(always)]
    fn write(
        address_domain: u32, base: StorageBaseAddress, value: RayTuple
    ) -> SyscallResult::<()> {
        let (first_ray, second_ray) = value;
        U128TupleStorageAccess::write(address_domain, base, (first_ray.val, second_ray.val))
    }

    #[inline(always)]
    fn read_at_offset_internal(
        address_domain: u32, base: StorageBaseAddress, offset: u8
    ) -> SyscallResult<RayTuple> {
        let (v0, v1) = StorageAccess::<U128Tuple>::read_at_offset_internal(
            address_domain, base, offset
        )?;
        Result::Ok((Ray { val: v0 }, Ray { val: v1 }))
    }

    #[inline(always)]
    fn write_at_offset_internal(
        address_domain: u32, base: StorageBaseAddress, offset: u8, value: RayTuple
    ) -> SyscallResult<()> {
        let (r0, r1) = value;
        StorageAccess::write_at_offset_internal(address_domain, base, offset, (r0.val, r1.val))
    }

    #[inline(always)]
    fn size_internal(value: RayTuple) -> u8 {
        let (r0, r1) = value;
        StorageAccess::size_internal((r0.val, r1.val))
    }
}

impl YangRedistributionStorageAccess of StorageAccess<YangRedistribution> {
    #[inline(always)]
    fn read(address_domain: u32, base: StorageBaseAddress) -> SyscallResult::<YangRedistribution> {
        let (unit_debt, error) = WadTupleStorageAccess::read(address_domain, base)?;
        Result::Ok(YangRedistribution { unit_debt, error })
    }

    #[inline(always)]
    fn write(
        address_domain: u32, base: StorageBaseAddress, value: YangRedistribution
    ) -> SyscallResult::<()> {
        WadTupleStorageAccess::write(address_domain, base, (value.unit_debt, value.error))
    }

    #[inline(always)]
    fn read_at_offset_internal(
        address_domain: u32, base: StorageBaseAddress, offset: u8
    ) -> SyscallResult<YangRedistribution> {
        let (w0, w1) = StorageAccess::<U128Tuple>::read_at_offset_internal(
            address_domain, base, offset
        )?;
        let unit_debt = Wad { val: w0 };
        let error = Wad { val: w1 };
        Result::Ok(YangRedistribution { unit_debt, error })
    }

    #[inline(always)]
    fn write_at_offset_internal(
        address_domain: u32, base: StorageBaseAddress, offset: u8, value: YangRedistribution
    ) -> SyscallResult<()> {
        StorageAccess::write_at_offset_internal(
            address_domain, base, offset, (value.unit_debt.val, value.error.val)
        )
    }

    #[inline(always)]
    fn size_internal(value: YangRedistribution) -> u8 {
        StorageAccess::size_internal((value.unit_debt.val, value.error.val))
    }
}

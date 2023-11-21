use rand::{Rng, seq::SliceRandom};
pub enum Domain {
    Range(std::ops::Range<u128>),
    Set(Vec<u128>),
}

pub trait Arg {
    fn generate(&self) -> String;
}

pub struct U128Arg {
    domain: Domain,
}

impl U128Arg {
    pub fn new(domain: Domain) -> Self {
        Self { domain }
    }
}

impl Arg for U128Arg {
    fn generate(&self) -> String {
        generate_u128(&self.domain)
    }
}

pub struct WadArg {
    domain: Domain,
}

impl WadArg {
    pub fn new(domain: Domain) -> Self {
        Self { domain }
    }
}

impl Arg for WadArg {
    fn generate(&self) -> String {
        format!("Wad{{val: {}}}", generate_u128(&self.domain))
    }
}

pub struct RayArg {
    domain: Domain,
}

impl RayArg {
    pub fn new(domain: Domain) -> Self {
        Self { domain }
    }
}

impl Arg for RayArg {
    fn generate(&self) -> String {
        format!("Ray{{val: {}}}", generate_u128(&self.domain))
    }
}

fn generate_u128(domain: &Domain) -> String {
    match domain {
        Domain::Range(ref range) => {
            let mut rng = rand::thread_rng();
            let value = rng.gen_range(range.start..range.end);
            format!("{}", value)
        }
        Domain::Set(ref set) => {
            let mut rng = rand::thread_rng();
            let value = set.choose(&mut rng).unwrap();
            format!("{}", value)
        }
    }
}

pub struct BoolArg {}

impl Arg for BoolArg {
    fn generate(&self) -> String {
        true.to_string()
    }
}

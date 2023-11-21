use std::rc::Rc;

use rand::{seq::SliceRandom, Rng};

pub const RAY_ONE: u128 = 10_u128.pow(27);
pub const WAD_ONE: u128 = 10_u128.pow(18);

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

pub struct BoolArg {
    domain: Option<bool>,
}

impl BoolArg {
    pub fn new(domain: Option<bool>) -> Self {
        Self { domain }
    }
}

impl Arg for BoolArg {
    fn generate(&self) -> String {
        self.domain
            .unwrap_or_else(|| {
                let mut rng = rand::thread_rng();
                rng.gen_bool(0.5)
            })
            .to_string()
    }
}

pub struct TupleArg {
    args: Vec<Rc<dyn Arg>>,
}

impl TupleArg {
    pub fn new(args: Vec<Rc<dyn Arg>>) -> Self {
        Self { args }
    }
}

impl Arg for TupleArg {
    fn generate(&self) -> String {
        let mut result = String::from("(");
        for (i, arg) in self.args.iter().enumerate() {
            if i > 0 {
                result.push_str(", ");
            }
            result.push_str(&arg.generate());
        }
        result.push_str(")");
        result
    }
}

pub struct AssetBalanceArg<'a> {
    address_domain: Vec<&'a str>,
    amount_domain: Domain,
}

impl AssetBalanceArg<'_> {
    pub fn new<'a>(address_domain: Vec<&'a str>, amount_domain: Domain) -> AssetBalanceArg<'a> {
        AssetBalanceArg {
            address_domain,
            amount_domain,
        }
    }
}

impl<'a> Arg for AssetBalanceArg<'a> {
    fn generate(&self) -> String {
        let mut rng = rand::thread_rng();
        let address = self.address_domain.choose(&mut rng).unwrap();
        let amount = generate_u128(&self.amount_domain);
        format!("AssetBalance{{address: {}, amount: {}}}", address, amount)
    }
}

pub struct SpanArg<T: Arg> {
    len: usize,
    arg: T,
}

impl<T: Arg> SpanArg<T> {
    pub fn new(len: usize, arg: T) -> SpanArg<T> {
        SpanArg { len, arg }
    }
}

impl<T: Arg> Arg for SpanArg<T> {
    fn generate(&self) -> String {
        let mut result = String::from("array![");
        for i in 0..self.len {
            if i > 0 {
                result.push_str(", ");
            }
            result.push_str(&self.arg.generate());
        }
        result.push_str("].span()");
        result
    }
}

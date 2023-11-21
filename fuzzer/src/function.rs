use std::fmt;
use crate::arg::Arg;
pub struct Func {
    name: String,
    args: Vec<Box<dyn Arg>>,
}

impl Func {
    pub fn new(name: &str, args: Vec<Box<dyn Arg>>) -> Self {
        Self {
            name: name.to_string(),
            args,
        }
    }
}

impl fmt::Display for Func {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{}(", self.name)?;
        for (i, arg) in self.args.iter().enumerate() {
            if i > 0 {
                write!(f, ", ")?;
            }
            write!(f, "{}", arg.generate())?;
        }
        write!(f, ");")
    }
}

#[macro_export]
macro_rules! vec_args {
    ($($type:expr),*) => {
        {
            let mut temp_vec = Vec::new();
            $(
                temp_vec.push(Box::new($type) as Box<dyn Arg>);
            )*
            temp_vec
        }
    };
}

use crate::arg::Arg;
use std::fmt;
use std::rc::Rc;
pub struct Func {
    name: String,
    args: Vec<Rc<dyn Arg>>,
}

impl Func {
    pub fn new(name: &str, args: Vec<Rc<dyn Arg>>) -> Self {
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

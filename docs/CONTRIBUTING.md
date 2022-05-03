# 🚢 💻 📡

Guidelines on how to effectively contribute to the project.

## Environment setup

We're assuming you already have a Cairo development environment set up. We use
the latest version of Cairo and Python 3.8 or 3.9 for development. To install
the necessary libraries, run:

```sh
pip install -r requirements-dev.txt
```

You'll also want to install [pre-commit](https://pre-commit.com/) so that certain
checks can be run before pushing your changes upstream:

```sh
pre-commit install
```

## Contributing

### Pull requests and code reviews

Most contributions should happen via a pull request. Unless it's trivial change,
opening a PR is always preferrable - besides the obvious benefits, it is a
chance for all involved parties to learn something.

When creating a PR, please include at least a short description of the change
and the context (i.e. what, why, how), so it's easier for a reviewer to pick
up. If you want to get feedback on specific areas, point it out in the
description as well.

Repo maintainers should prioritize reviewing pull requests over their "normal"
tasks to unblock other teammates and help push the project forward.

### Cairo conventions

When adding new Cairo code, please make sure it follows our [Cairo Conventions](./CairoConventions.md).

### Conventional commits

Commit messages should follow the [conventional commits](https://www.conventionalcommits.org/en/v1.0.0/) guidelines.

### Adding new Cairo libraries

As of yet, Cairo doesn't have a good way how to install libraries into a project.
They way we solved it is just to simply copy over the whole library we want to
use into a its own directory under `contracts/lib`. The reasoning behind this
approach is that we all always work on the same codebase, the repo is ready to
be used just with a single `git clone`, and we can easily incorporate our own
changes into the libraries themselves.

This also means that **we** are responsible for the correctness of the introduced
library code. Be wary of that.

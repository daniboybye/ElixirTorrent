# Contributing to ElixirTorrent

Thanks for taking a look at this project — contributions are genuinely welcome, whether that's a bug report, a documentation fix, a new BEP, or just a question. This started as a student project and grew from there, so no contribution is too small to be useful, and no question is too basic to ask.

## Ways to help

- **Report a bug** — [open an issue](https://github.com/daniboybye/ElixirTorrent/issues/new). Include what you expected, what happened, and (if you can) the relevant slice of the log or a minimal reproduction.
- **Suggest an improvement** — an issue works fine for this too; it's fine if it's just an idea rather than a fully worked-out proposal.
- **Improve documentation** — README clarity, HexDocs `@moduledoc`/`@doc` coverage, or the BEP compliance table all count.
- **Send a pull request** — for anything beyond a typo fix, opening an issue first is a good way to make sure the approach makes sense before you put time into it.

Found a security vulnerability instead? Please don't open a public issue for that — see [SECURITY.md](SECURITY.md) for how to report it privately.

## Getting set up

```bash
git clone https://github.com/daniboybye/ElixirTorrent.git
cd ElixirTorrent
mix deps.get
mix test
```

Requires Elixir 1.20+ (see `.tool-versions` for the exact pinned toolchain used in CI).

## Before opening a pull request

The same checks CI runs are available locally, so you can catch issues before pushing:

```bash
mix format
mix quality   # compile --warnings-as-errors, dialyzer, credo --all
mix test
```

A few conventions this codebase follows, worth keeping in mind:

- **Tests are event-driven, not timing-based.** Avoid `Process.sleep`/`:timer.sleep` in tests — use messages, monitors, socket events, or `:sys.get_state` barriers instead. Flaky sleep-based tests are worse than no test.
- **Commit messages** follow a lowercase [Conventional Commits](https://www.conventionalcommits.org/)-style prefix, e.g. `fix(peer): ...`, `feat(dht): ...`, `test: ...`, `docs: ...`.
- New functionality should come with tests; a bug fix is a good opportunity to add a regression test for it.

None of this needs to be perfect before you open a PR — it's fine to ask for help getting there. CI (`Build, analyze, and test`) has to pass before a PR can merge, and existing pull requests are a good place to see the expected shape of a change.

## Code of conduct

Be respectful and assume good faith — that's really the whole policy. Disagreements about code and design are normal and welcome; personal attacks aren't.

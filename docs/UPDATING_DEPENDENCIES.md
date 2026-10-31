# Updating dependencies and tooling

A repeatable procedure for bringing every moving part of the engine up to date:
Hex dependencies, the Erlang/Elixir toolchain, the analysis and formatting
tools, and the GitHub Actions workflows. Run it roughly once a month, or
whenever Dependabot opens a batch of PRs. The same procedure exists for
ElixirTorrentWebUI (`docs/UPDATING_DEPENDENCIES.md` there); when the engine
bumps something that the WebUI also uses (Erlang/Elixir, credo, dialyxir,
sobelow, excoveralls), update the WebUI right after, so the two stay aligned.

> Rules that apply to the whole procedure
>
> - Language of commit messages, PR titles, PR descriptions and PR comments is
>   **English**.
> - Work on a feature branch, never on `master`. Commit style follows
>   [CONTRIBUTING.md](../CONTRIBUTING.md) (`chore(deps): ...`, `ci: ...`).
> - Delete the feature branch (local and remote) once it is merged.
> - A PR produced by an autonomous cloud agent must be validated locally on a
>   developer machine (real torrents, not only the test suite) before merge.
> - One concern per PR where practical: toolchain, Hex deps and Actions can
>   each be reverted independently. Splitting is preferred over one big PR
>   when more than one of them has breaking changes.

## 0. Preparation

1. `git switch master && git pull`, then `git switch -c chore/update-deps-YYYY-MM`.
2. Make sure the baseline is green first: `mix deps.get && mix format --check-formatted && mix quality && mix test`.
   If it is not green, fix or note that before updating anything, so failures
   can be attributed correctly.
3. Merge or close open Dependabot PRs that overlap with this run (see
   `.github/dependabot.yml`; weekly, groups `dev-and-test-tooling` and
   `github-actions`).

## 1. Erlang and Elixir

Files that carry the version:

| File | What to change |
| --- | --- |
| `.tool-versions` | `elixir X.Y.Z-otp-N` and `erlang X.Y.Z` (the OTP major in both lines must match) |
| `mix.exs` | `elixir: "~> 1.NN"` requirement, change only when the minimum supported Elixir changes |
| `CONTRIBUTING.md` | "Requires Elixir 1.NN+" sentence |
| `.github/workflows/*.yml` | versions come from `.tool-versions` through `erlef/setup-beam` (`version-type: strict`); there is no separate matrix to edit |

Steps:

1. Check the latest releases: <https://www.erlang.org/downloads>,
   <https://github.com/elixir-lang/elixir/releases>, and that
   `erlef/setup-beam` can install the combination
   (<https://github.com/erlef/setup-beam#compatibility-between-operating-system-and-erlangotp>).
   `version-type: strict` means a typo or a not-yet-published build fails CI.
2. Edit `.tool-versions`, then `asdf install` (or `mise install`).
3. `rm -rf _build deps && mix deps.get`, then run the full check (section 6).
   A new OTP major commonly brings new compiler or Dialyzer warnings, and can
   break test-only git dependencies (see `proper` in section 2).
4. Bump the `mix.exs` Elixir requirement only if the code now relies on a newer
   language or stdlib feature, or the oldest Elixir is no longer tested.
5. After merging, update the WebUI `.tool-versions` to the same pair.

## 2. Hex dependencies

1. See what is outdated: `mix hex.outdated` (add `--all` to include
   transitive deps).
2. Update within the existing requirements: `mix deps.update --all`.
   Then handle the majors one at a time: raise the requirement in `mix.exs`,
   run `mix deps.update <name>`, read the changelog, adapt the code.
3. Things specific to this repo:
   - `proper` is pinned to an immutable git `ref` because the Hex release
     predates the OTP 29 warning fixes. Dependabot ignores it. Once a Hex
     release includes the fix, replace the git pin with a Hex requirement and
     remove the `ignore` entry in `.github/dependabot.yml`.
   - `propcheck` and `excoveralls` are patched in the test environment by
     `scripts/patch-propcheck.exs` and `scripts/patch-excoveralls.exs`
     (`mix deps.patch-test`). After updating either, check that the patch still
     applies and whether upstream made it unnecessary.
   - `scripts/compile-property-deps.sh` compiles the property-test dependencies
     without warnings; CI runs it. Run it locally after any test-dep bump.
   - This is a published library: keep requirement ranges as wide as is safe
     (`~> 3.0` stays for 3.1, widen only when a new major is supported).
4. Hygiene checks (the same ones CI runs):
   ```bash
   mix deps.get --check-locked
   MIX_ENV=test mix deps.get --check-locked
   mix deps.unlock --check-unused
   mix hex.audit
   ```
5. Commit `mix.exs` and `mix.lock` together.

## 3. Analysis and formatting tools

Tools: `credo`, `dialyxir`, `sobelow`, `ex_doc`, `excoveralls`, the Elixir
formatter, and the `trivy` scan.

1. `credo`, `dialyxir`, `sobelow`, `ex_doc`, `excoveralls` are ordinary Hex
   deps: they are updated in section 2. Afterwards review their config:
   - `.credo.exs`: compare with the new default by running
     `mix credo gen.config` into a temporary file and diffing it; adopt new
     checks deliberately, do not silence them blindly.
   - `mix.exs` `dialyzer: [flags: ...]`, and a rebuilt PLT if Dialyzer or OTP
     changed: `mix dialyzer --format short` (delete `_build/*/dialyxir_*` if
     the PLT looks stale).
   - the `sobelow` alias thresholds, and `.sobelow-skips` if present.
2. Formatter: it ships with Elixir. After a toolchain bump run `mix format` and
   commit the result as its own commit so the diff is reviewable.
   `.formatter.exs` only needs changes if `import_deps` changed.
3. Trivy: configuration lives in `.trivy.yaml`; the version comes from the
   `aquasecurity/trivy-action` input (`version: latest`). Run
   `trivy fs --config .trivy.yaml .` locally if installed and look for new
   findings caused by the dependency changes.
4. New findings from any tool are fixed in the same PR when small; otherwise
   they are recorded in the PR description with a follow-up issue. Never
   disable a check just to get a green build.

## 4. GitHub Actions and runner images

Workflows: `.github/workflows/build-and-publish.yml`, `scorecard.yml`.

1. List everything that is pinned:
   ```bash
   grep -RnE 'uses:|runs-on:|version:' .github/workflows
   ```
2. Every action is pinned to a full commit SHA with a version comment
   (`# v7.0.1`). Update **both** the SHA and the comment, taking the SHA of the
   release tag (`git ls-remote --tags https://github.com/<owner>/<repo>`; for
   annotated tags use the `^{}` line). Never switch to a floating tag.
   Dependabot's `github-actions` group normally does this; review and merge it
   instead of editing by hand when it is open.
3. Read the release notes for majors (input renames, Node runtime, permission
   changes). The currently used actions are `actions/checkout`,
   `actions/cache`, `erlef/setup-beam`, `aquasecurity/trivy-action`,
   `github/codeql-action/upload-sarif`, `codecov/codecov-action`,
   `sigstore/cosign-installer`, `actions/attest-build-provenance`,
   `softprops/action-gh-release`, and the Scorecard actions.
4. Runner image: `runs-on: ubuntu-26.04` appears in both jobs of
   `build-and-publish.yml`. Check
   <https://github.com/actions/runner-images> for a newer LTS image and for
   deprecation notices of the current one, then change every occurrence.
5. Intentional exceptions, keep them unless the reason went away:
   - the `publish` job uses `erlef/setup-elixir` (old name of `setup-beam`,
     same SHA) so OpenSSF Scorecard recognises it as an Elixir/Hex publish
     workflow; update its SHA together with the other `setup-beam` step.
6. Validate the workflow files: `actionlint` if available, and push the
   branch so that the PR run exercises them. The publish job only runs on tags,
   so changes there cannot be fully verified by a PR; say so in the PR and
   check the first release afterwards.

## 5. Docs and changelog

- Add a `CHANGELOG.md` entry only for changes users of the package can see
  (new minimum Elixir, a dependency major that changes behaviour). Pure
  tooling and CI bumps do not need one.
- Update `CONTRIBUTING.md` if the required Elixir version or the local check
  commands changed.

## 6. Verification (before opening the PR)

```bash
mix deps.get --check-locked
mix deps.unlock --check-unused
mix hex.audit
mix format --check-formatted
bash scripts/compile-property-deps.sh
mix compile --warnings-as-errors && MIX_ENV=test mix compile --warnings-as-errors
mix dialyzer
mix credo --all
mix sobelow
timeout 60s mix coveralls.json --no-compile
mix test.properties   # when property-test dependencies or the toolchain changed
```

Because the WebUI consumes the engine, a toolchain or dependency change that
affects the public API or runtime behaviour should also be checked end to end
on a developer machine with real torrents (start the WebUI against this
checkout with `ELIXIR_TORRENT_PATH=../ElixirTorrent`).

## 7. Pull request

- Branch `chore/update-deps-YYYY-MM`, English title such as
  `chore(deps): update Elixir/OTP, Hex dependencies and CI actions`.
- The description lists, per category (toolchain, Hex deps, analysis tools,
  Actions/runners): old version, new version, and anything that needed code
  changes or was deliberately skipped (with the reason).
- Wait for `Build, analyze, and test` to pass.
- If the PR was made by a cloud agent, validate locally (section 6, last
  paragraph) and only then merge.

## 8. After merging

1. Delete the feature branch locally and on the remote.
2. If the changes are worth shipping to consumers, release following the
   local `.claude/RELEASE.md` (`/release`); otherwise they go out with the
   next release.
3. Update the WebUI (its own `docs/UPDATING_DEPENDENCIES.md`): same toolchain
   pair, and the new engine version if one was released.

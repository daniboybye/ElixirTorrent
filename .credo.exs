# This file contains the configuration for Credo and you are probably reading
# this after creating it with `mix credo.gen.config`.
#
# If you find anything wrong or unclear in this file, please report an
# issue on GitHub: https://github.com/rrrene/credo/issues
#
%{
  #
  # You can have as many configs as you like in the `configs:` field.
  configs: [
    %{
      #
      # Run any config using `mix credo -C <name>`. If no config name is given
      # "default" is used.
      #
      name: "default",
      #
      # These are the files included in the analysis:
      files: %{
        #
        # You can give explicit globs or simply directories.
        # In the latter case `**/*.{ex,exs}` will be used.
        #
        included: [
          "lib/",
          "src/",
          "test/",
          "web/",
          "apps/*/lib/",
          "apps/*/src/",
          "apps/*/test/",
          "apps/*/web/"
        ],
        excluded: [~r"/_build/", ~r"/deps/", ~r"/node_modules/"]
      },
      #
      # Load and configure plugins here:
      #
      plugins: [],
      #
      # If you create your own checks, you must specify the source files for
      # them here, so they can be loaded by Credo before running the analysis.
      #
      requires: [],
      #
      # If you want to enforce a style guide and need a more traditional linting
      # experience, you can change `strict` to `true` below:
      #
      strict: true,
      #
      # To modify the timeout for parsing files, change this value:
      #
      parse_timeout: 5000,
      #
      # If you want to use uncolored output by default, you can change `color`
      # to `false` below:
      #
      color: true,
      #
      # You can customize the parameters of any check by adding a second element
      # to the tuple.
      #
      # To disable a check put `false` as second element:
      #
      #     {Credo.Check.Design.DuplicatedCode, false}
      #
      checks: %{
        enabled: [
          #
          ## Consistency Checks
          #
          {Credo.Check.Consistency.ExceptionNames, []},
          {Credo.Check.Consistency.LineEndings, []},
          {Credo.Check.Consistency.ParameterPatternMatching, []},
          {Credo.Check.Consistency.MultiAliasImportRequireUse, []},
          {Credo.Check.Consistency.SpaceAroundOperators, []},
          {Credo.Check.Consistency.SpaceInParentheses, []},
          {Credo.Check.Consistency.TabsOrSpaces, []},

          #
          ## Design Checks
          #
          # You can customize the priority of any check
          # Priority values are: `low, normal, high, higher`
          #
          {Credo.Check.Design.AliasUsage,
           [priority: :low, if_nested_deeper_than: 2, if_called_more_often_than: 0]},
          {Credo.Check.Design.SkipTestWithoutComment, []},
          {Credo.Check.Design.TagFIXME, []},
          # You can also customize the exit_status of each check.
          # If you don't want TODO comments to cause `mix credo` to fail, just
          # set this value to 0 (zero).
          #
          {Credo.Check.Design.TagTODO, [exit_status: 2]},

          #
          ## Readability Checks
          #
          {Credo.Check.Readability.AliasOrder, []},
          {Credo.Check.Readability.BlockPipe, []},
          {Credo.Check.Readability.FunctionNames, []},
          {Credo.Check.Readability.ImplTrue, []},
          {Credo.Check.Readability.LargeNumbers, []},
          {Credo.Check.Readability.MaxLineLength, [priority: :low, max_length: 120]},
          {Credo.Check.Readability.ModuleAttributeNames, []},
          {Credo.Check.Readability.ModuleDoc, []},
          {Credo.Check.Readability.ModuleNames, []},
          {Credo.Check.Readability.OneArityFunctionInPipe, []},
          {Credo.Check.Readability.OnePipePerLine, []},
          {Credo.Check.Readability.ParenthesesInCondition, []},
          {Credo.Check.Readability.ParenthesesOnZeroArityDefs, []},
          {Credo.Check.Readability.PipeIntoAnonymousFunctions, []},
          {Credo.Check.Readability.PredicateFunctionNames, []},
          {Credo.Check.Readability.PreferImplicitTry, []},
          {Credo.Check.Readability.RedundantBlankLines, []},
          {Credo.Check.Readability.SeparateAliasRequire, []},
          {Credo.Check.Readability.Semicolons, []},
          {Credo.Check.Readability.SingleFunctionToBlockPipe, []},
          {Credo.Check.Readability.SpaceAfterCommas, []},
          {Credo.Check.Readability.StrictModuleLayout, []},
          {Credo.Check.Readability.StringSigils, []},
          {Credo.Check.Readability.TrailingBlankLine, []},
          {Credo.Check.Readability.TrailingWhiteSpace, []},
          {Credo.Check.Readability.UnnecessaryAliasExpansion, []},
          {Credo.Check.Readability.VariableNames, []},
          {Credo.Check.Readability.WithCustomTaggedTuple, []},
          {Credo.Check.Readability.WithSingleClause, []},

          #
          ## Refactoring Opportunities
          #
          {Credo.Check.Refactor.Apply, []},
          {Credo.Check.Refactor.CondStatements, []},
          {Credo.Check.Refactor.CyclomaticComplexity, []},
          {Credo.Check.Refactor.DoubleBooleanNegation, []},
          {Credo.Check.Refactor.FilterCount, []},
          {Credo.Check.Refactor.FilterFilter, []},
          {Credo.Check.Refactor.FunctionArity, []},
          {Credo.Check.Refactor.LongQuoteBlocks, []},
          {Credo.Check.Refactor.MapJoin, []},
          {Credo.Check.Refactor.MatchInCondition, []},
          {Credo.Check.Refactor.NegatedConditionsInUnless, []},
          {Credo.Check.Refactor.NegatedConditionsWithElse, []},
          {Credo.Check.Refactor.Nesting, []},
          {Credo.Check.Refactor.PassAsyncInTestCases, []},
          {Credo.Check.Refactor.RedundantWithClauseResult, []},
          {Credo.Check.Refactor.FilterReject, []},
          {Credo.Check.Refactor.MapMap, []},
          {Credo.Check.Refactor.RejectFilter, []},
          {Credo.Check.Refactor.RejectReject, []},
          {Credo.Check.Refactor.UnlessWithElse, []},
          {Credo.Check.Refactor.UtcNowTruncate, []},
          {Credo.Check.Refactor.WithClauses, []},

          #
          ## Warnings
          #
          {Credo.Check.Warning.ApplicationConfigInModuleAttribute, []},
          {Credo.Check.Warning.BoolOperationOnSameValues, []},
          {Credo.Check.Warning.Dbg, []},
          {Credo.Check.Warning.ExpensiveEmptyEnumCheck, []},
          {Credo.Check.Warning.IExPry, []},
          {Credo.Check.Warning.IoInspect, []},
          {Credo.Check.Warning.MissedMetadataKeyInLoggerConfig, []},
          {Credo.Check.Warning.OperationOnSameValues, []},
          {Credo.Check.Warning.OperationWithConstantResult, []},
          {Credo.Check.Warning.RaiseInsideRescue, []},
          {Credo.Check.Warning.SpecWithStruct, []},
          # UTP.Connection currently has 36 protocol-state fields. Keep that
          # explicit baseline and fail if the hot per-connection struct grows.
          {Credo.Check.Warning.StructFieldAmount, [max_fields: 36]},
          {Credo.Check.Warning.LeakyEnvironment, []},
          {Credo.Check.Warning.MapGetUnsafePass, []},
          {Credo.Check.Warning.MixEnv, []},
          {Credo.Check.Warning.UnsafeExec, []},
          {Credo.Check.Warning.UnsafeToAtom, []},
          {Credo.Check.Warning.UnusedEnumOperation, []},
          {Credo.Check.Warning.UnusedFileOperation, []},
          {Credo.Check.Warning.UnusedKeywordOperation, []},
          {Credo.Check.Warning.UnusedListOperation, []},
          {Credo.Check.Warning.UnusedMapOperation, []},
          {Credo.Check.Warning.UnusedPathOperation, []},
          {Credo.Check.Warning.UnusedRegexOperation, []},
          {Credo.Check.Warning.UnusedStringOperation, []},
          {Credo.Check.Warning.UnusedTupleOperation, []},
          {Credo.Check.Warning.WrongTestFilename, []}
        ],
        disabled: [
          #
          # Requires Elixir < 1.7.0; always skipped on our toolchain (1.20.x), keep
          # disabled to silence Credo's "skipped, incompatible" notice on every run.
          {Credo.Check.Warning.LazyLogging, []},

          #
          # Controversial and experimental checks (opt-in, just move the check to `:enabled`)
          #
          # 1021 findings — by far the largest single check. It wants ONE style
          # per file for naming discarded values, but this codebase's mix is
          # deliberate: `{_ok, _failures, failed_peers} = results` names the
          # discarded elements to document the tuple's shape, while plain `_`
          # is used where the discarded value's identity is obvious from
          # context (e.g. `fn {p, _} -> ...`). That per-site judgment call is
          # better than a blanket rule, not sloppy inconsistency.
          {Credo.Check.Consistency.UnusedVariableNames, []},
          # The escript CLI loop's `info/1` progress printer (elixir_torrent.ex)
          # is the only IO.puts in the codebase, and it is deliberate: it is the
          # console feedback for `mix escript.build`'s ad-hoc CLI (README "CLI
          # (escript)" section), not a debug leftover. Disabled globally rather
          # than inline-suppressed at that one call site.
          {Credo.Check.Refactor.IoPuts, []},
          # 11 findings (6 unique pairs), all test-only. One pair is a genuine
          # verbatim-duplicate private helper worth extracting on its own; the
          # rest are test-boilerplate overlap between distinct scenarios (same
          # setup shape, different assertions) where each test staying
          # self-contained and readable in isolation outweighs DRY-ing the
          # shared shape into a helper. Matches Credo's own "controversial and
          # experimental" classification for this check.
          {Credo.Check.Design.DuplicatedCode, []},
          # 17 findings surveyed individually. Almost all are either order-critical
          # (uTP recv_waiters must stay FIFO; DHT k-buckets, tier lists, and their
          # tests assert a specific order) or tiny fixed-size lists (acceptor.ex
          # socket option lists, a k=8-capped DHT bucket) where `[head | tail]`
          # buys nothing. The two genuine O(n^2) accumulators (Merkle.build_stream_layout,
          # merkle.ex:663/672) sit inside BEP 52 piece-stream-layout construction —
          # reordering there risks silently corrupting piece hash verification for a
          # perf win that is negligible at realistic (<few hundred) file counts.
          {Credo.Check.Refactor.AppendSingleItem, []},
          # Every current use of `alias X, as: Y` in this codebase disambiguates a
          # real collision (e.g. Peer.UtHolepunch.Extension vs Peer.UtPex.Extension
          # both bare-aliasing to `Extension` in the same test module) or names a
          # generic last segment more specifically (DialQueue, DHTConfig). This
          # check would force reverting those deliberate, collision-avoiding names.
          {Credo.Check.Readability.AliasAs, []},
          # Directly contradicts the already-enabled
          # Consistency.MultiAliasImportRequireUse, which flags single-per-line
          # aliases as inconsistent once a file's dominant style is grouped
          # `{}` form (the norm throughout this codebase, e.g. `alias
          # Peer.LTEP.{Extensions, Handshake, Session}`). Enabling both would
          # make every multi-alias file unfixably wrong one way or the other.
          {Credo.Check.Readability.MultiAlias, []},
          # 316 findings, fires at just 2 levels of nesting — the first
          # example was `GenServer.whereis(via(hash))`, a totally benign,
          # idiomatic wrap. Forcing this into a pipe for every 2-deep call in
          # the codebase would not read better; only genuinely deep nesting
          # (3+ levels) is a real readability problem, and this check does not
          # distinguish that from the common case.
          {Credo.Check.Readability.NestedFunctionCalls, []},
          # 164 findings. Sampled several: some are neutral either way, but a
          # meaningful fraction pipe a multi-line literal into the next call
          # (e.g. `torrent(...) |> Map.put(:metadata, %{...})` with a large
          # nested map) — un-piping those would bury the multi-line argument
          # mid-call instead of trailing it, which is worse, not better. The
          # check's fix is the same regardless of call shape, so it cannot
          # tell the improving cases from the hurting ones.
          {Credo.Check.Readability.SinglePipe, []},
          # Unlike the other checks in this section, this one is NOT a case of
          # fighting a better existing pattern — @spec is genuinely valuable
          # here (Dialyzer already runs in mix quality) and this codebase uses
          # @spec pervasively already. 311 findings across 65 files is real
          # work though: a wrong @spec is worse than a missing one (misleading
          # documentation, and it can hide the exact Dialyzer warnings it
          # should surface). Needs a deliberate pass reading each function to
          # infer correct types, not a bulk fill-in.
          {Credo.Check.Readability.Specs, []},
          # 77 findings scattered across nearly every subsystem, many on the
          # dial/wire hot path (handshakes.ex up to 43, magnet/connection.ex 50,
          # tracker.ex up to 56, utp/connection.ex up to 42,
          # peer/controller/state.ex up to 45). A real fix means decomposing
          # each function's actual logic, not a mechanical edit — genuine
          # refactor work belonging in its own deliberate, function-by-function
          # pass with test coverage in hand, not a bulk lint sweep across
          # protocol-critical code.
          {Credo.Check.Refactor.ABCSize, []},
          # 443 findings — the single largest volume of anything surveyed. The
          # check wants every `if/else` rewritten as `cond`, which is the
          # opposite of the mainstream Elixir convention (if/else for binary
          # branching, cond/case for 3+ branches). Converting all 443 sites
          # would make the code more verbose for no readability gain and go
          # against how Elixir style guides and this codebase already write
          # binary conditionals.
          {Credo.Check.Refactor.CondInsteadOfIfElse, []},
          # 39 findings (17% of source files), all at 2-4x the default max of 10,
          # and the worst offenders (peer/controller/state.ex: 46, torrent.ex: 36,
          # magnet/fetcher.ex: 35, tracker.ex: 28) are exactly this codebase's
          # architectural hub modules. A hub module in a from-scratch binary
          # protocol implementation legitimately touches many small, single-
          # purpose BEP structs and sub-handlers by design — that is the
          # decomposition CLAUDE.md/ARCHITECTURE.md describes, not accidental
          # coupling. Fixing this means splitting hub modules, a real
          # architecture decision to make deliberately, not a bulk lint pass.
          {Credo.Check.Refactor.ModuleDependencies, []},
          # 23 findings, mostly `when not is_nil(x)` guards on GenServer callbacks
          # and case/with clauses across the dial/wire hot path (utp/connection.ex,
          # peer/controller.ex, magnet/connection.ex). Credo's fix is a structural
          # clause split/reorder, not a text substitution — real risk of a
          # match-order bug on protocol-handling code for a low-priority style
          # preference. Revisit as its own reviewed pass, not a bulk sweep.
          {Credo.Check.Refactor.NegatedIsNil, []},
          # 138 findings, same root complaint as Readability.SinglePipe (many
          # sites are shared): wants every pipe chain to start from a bare
          # variable, not a function call — e.g. `base_peer_state(hash, id)
          # |> Map.put(...) |> Map.put(...)` would need a throwaway
          # intermediate binding just to satisfy the rule. The
          # constructor-then-transform-chain shape is a common, deliberate
          # idiom here; forcing an extra variable name adds a line for no
          # readability gain.
          {Credo.Check.Refactor.PipeChainStart, []},
          # 55 findings, almost all the standard GenServer callback idiom
          # `state = f(state); state = g(state); {:noreply, state}` (dht.ex,
          # utp/connection.ex, torrent/controller.ex). Forcing unique names or
          # nesting the calls would read worse, not better, for this exact
          # pattern — it is one of the most common, deliberate idioms in OTP
          # code, which is presumably why Credo files this under controversial.
          {Credo.Check.Refactor.VariableRebinding, []}
          # {Credo.Check.Warning.UnusedOperation, [{MyMagicModule, [:fun1, :fun2]}]}

          # {Credo.Check.Refactor.MapInto, []},

          #
          # Custom checks can be created using `mix credo.gen.check`.
          #
        ]
      }
    }
  ]
}

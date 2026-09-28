# Guideline coverage

Source reviewed before implementation: [Command Line Interface Guidelines](https://clig.dev/). This is an implementation inventory, not a claim of complete compliance.

## Implemented by the framework

| Area | Concrete behavior |
| --- | --- |
| Help and discovery | Generated usage, descriptions, examples, option defaults/environment names/ranges/choices, public result fields, optional support URL, themed help groups and responsive columns; help/version bypass all execution work |
| Process contract | Results on injected stdout, diagnostics/progress/prompts on injected stderr, explicit exit categories, no expected-error tracebacks |
| Human and machine output | zrich help panels, single-result cards and tables, independent stream detection in the native adapter, automatic plain output on redirected stdout, separate stable plain and JSON serializers |
| Color and output controls | Nonempty NO_COLOR, TERM=dumb, --no-color; static progress only, -q progress suppression; width-aware human tables with plain fallback |
| Errors | Plain-language failures, repair hints, offending option names, allowed choices/ranges and configuration source; caller-defined expected failures; terminal error frames preserve repair instructions |
| Noninteractive use | stdin capability and read callback required before prompting; conditional --no-input; supply instructions when prompting is unavailable |
| Validation | Typed scalar/optional values, numeric bounds, finite numbers, UTF-8; validation before handler; unknown/duplicate configuration keys rejected |
| Configuration | Explicit layered inputs, lazy loader, documented precedence; only winning option values are converted |
| Lifecycle | Injected cancellation probe, cancellation notification, on_cancel and cleanup hooks; handler checkpoints |
| Destructive operations | Optional confirmation policy; dry-run advertised only with a separate preview handler; no inferred mutation suppression |
| Stability | Exact command/flag names, no abbreviations or catch-all commands; public struct defines output fields; literal terminal-safe result display |
| Distribution | Standalone example binary, no implicit global install, explicit allocator and I/O, only owned zrich package, no telemetry |
| Verification | Reusable Zig and real-process harnesses, independently controlled PTYs, tests on both explicitly selected compilers |

## Requires application cooperation

Applications write meaningful descriptions, examples, support links and domain errors. Their result structs must omit secrets and internal state. They choose appropriate confirmation levels and guarantee preview semantics. They control filesystem/config discovery (including XDG), credentials, operation timeouts, signal registration, interruptible I/O, rollback, idempotence and bounded cleanup. Progress calls and cancellation checkpoints must occur during long operations. A framework cannot recover safely from arbitrary application mutations.

The example supplies real file semantics, strict optional config loading and expected file-access errors. Its preview never calls deletion. The in-process tests demonstrate lifecycle hooks with deterministic cancellation probes. There is no automatic signal adapter in this release.

## Future work / explicit limits

- Nested commands, repeated/list options, completion, aliases, and spelling suggestions.
- Generated man pages, extended documentation commands, pagers and schema export.
- Streaming results, huge datasets, nested result objects.
- Native signal integration, second-interrupt behavior, cleanup deadlines, and cancellation of blocking reads.
- Secret-input helpers and credential-source policies.
- XDG path helpers and additional config-file parsers.
- Native Windows process conformance runs; the verification host is macOS ARM64, with Linux covered by CI.

No switches are exposed for these absent capabilities. `--dry-run`, `--yes` and `--no-input` are command-specific and appear only when their API contracts are declared. `FORCE_COLOR` is not supported; color is automatic unless disabled.

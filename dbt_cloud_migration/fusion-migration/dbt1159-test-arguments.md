# dbt1159 — Deprecated test argument format (`arguments:` block required)

## What the error looks like

```
[error] [DbtYamlValidationError (dbt1159)]:
  Deprecated test arguments: ["datepart", "field", "interval"] at top-level detected.
  Please migrate to the new format under the 'arguments' field:
  https://docs.getdbt.com/reference/deprecations#missingargumentspropertyingenerictestdeprecation.
```

## 1.8 behavior

Generic test arguments could sit at the top-level of a test declaration:

```yaml
data_tests:
  - dbt_utils.recency:
      datepart: day
      field: created_at
      interval: 1
```

## Fusion behavior

Arguments must be nested under an `arguments:` block:

```yaml
data_tests:
  - dbt_utils.recency:
      arguments:
        datepart: day
        field: created_at
        interval: 1
```

For the alternate `test_name` form, framework config (like `severity`, `enabled`, `where`) moves under `config:`:

```yaml
data_tests:
  - name: friendly_test_name
    test_name: dbt_utils.recency
    arguments:
      datepart: day
      field: created_at
      interval: 1
    config:
      severity: warn
      where: "1=1"
```

## Why the change

Splits the semantic distinction between:
- **Arguments** — parameters that get passed into the test's Jinja macro (`{{ test_recency(datepart, field, interval) }}`)
- **Config** — framework-level settings that control how dbt runs the test (severity, enabled, where clause, tag)

Previously both lived at the same level, making it ambiguous which was which.

## Migration approach

**Use `dbt-autofix`** — this is what it's built for. Handles this class alone across 50+ YAML files in this project.

```bash
dbt-autofix deprecations --all --path <project-root>
```

The `--all` flag also flips the corresponding behavior flag in `dbt_project.yml`:
```yaml
flags:
  require_generic_test_arguments_property: true   # was: false
```

## Why the `require_generic_test_arguments_property: false` shim doesn't work

We initially set `require_generic_test_arguments_property: false` in `dbt_project.yml` hoping to preserve 1.8 semantics. **It does not work in Fusion / dbt 1.10+.** The deprecation was graduated to a hard error in Fusion regardless of flag value. The flag no longer controls this behavior — migration is mandatory.

## Business impact

None if the tests were functionally correct in 1.8. The rewrite is purely syntactic — same arguments passed to the same test macros. Test SQL doesn't change, only the YAML wrapping.

## References

- [dbt Deprecations: MissingArgumentsPropertyInGenericTest](https://docs.getdbt.com/reference/deprecations#missingargumentspropertyingenerictestdeprecation)
- [dbt data tests reference](https://docs.getdbt.com/reference/resource-properties/data-tests)
- [dbt-autofix repo](https://github.com/dbt-labs/dbt-autofix)

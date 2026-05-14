# Legacy fixer-ref scan noise

## Status
Watching

## Description
`scan-legacy-fixer-refs.yml` runs `tools/scan-legacy-fixer-refs.ps1` /
`.sh` to detect outdated `scripts-fixer` (no version suffix) references that
should be `scripts-fixer-v18`.

## Symptom
Scanner can flag historical strings inside memory/spec/changelog files where
the legacy name is intentional (documenting old behaviour).

## Mitigation
Scanner already excludes `.lovable/`, `spec/audit/`, and `legacy-fix-report.json`.
If a new false-positive surfaces, add the path to the exclusion list inside
`tools/scan-legacy-fixer-refs.{ps1,sh}` — do NOT rewrite historical content.

## Do NOT
Rename strings inside `.lovable/solved-issues/` or `spec/` just to silence the
scanner. Extend exclusions instead.

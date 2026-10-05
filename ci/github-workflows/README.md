# CI workflows (staged)

These GitHub Actions workflows (Rust fmt/clippy/test, Solidity forge build/test,
TypeScript lint/test/build) are kept here because the token used for the initial
push did not have the `workflow` scope.

To enable CI:

```bash
gh auth refresh -h github.com -s workflow
mkdir -p .github/workflows
git mv ci/github-workflows/*.yml .github/workflows/
git commit -m "ci: enable GitHub Actions workflows"
git push
```

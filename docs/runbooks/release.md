# Release

The marketplace listing (GitHub omacom/omarchy-plugin-marketplace) is pinned to one commit. Each
release needs a `[Verify]` issue naming the full HEAD SHA, and any later push makes it stale.

1. Finish the code, README and `preview.png` first. Bump `version` in `manifest.json`.
2. `repo-docs map && repo-docs check`, `node --test tests/`, commit.
3. Ask before pushing. Then:

```bash
git push origin main
git tag v1.5.0 && git push origin v1.5.0
git rev-parse HEAD
```

4. Open the issue with the "Verify and publish a newer upstream commit" form. The body of #11121
   is the template; change only the target commit:

```bash
gh issue create -R omacom/omarchy-plugin-marketplace \
  --title "[Verify]: io.github.selfcrypto.power-saving 1.5.0" --body-file <body.md>
```

5. A bot validates, then a maintainer applies `approved-and-verified`. While the issue is open,
   push nothing; if something must go in, edit the issue body to the new SHA.
6. After approval, `omarchy plugin update io.github.selfcrypto.power-saving`.

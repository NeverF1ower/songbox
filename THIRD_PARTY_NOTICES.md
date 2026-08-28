# Third-party notices

## v2ray-agent decoy-site templates

`songbox.sh` can download nine optional static-site template archives from the
[`mack-a/v2ray-agent`](https://github.com/mack-a/v2ray-agent) project.

- Upstream commit: `89388ca675af39c70e72f9174c1f112b04613703`
- Upstream path: `fodder/blog/unable/html1.zip` through `html9.zip`
- Upstream license: [GNU Affero General Public License v3.0](https://github.com/mack-a/v2ray-agent/blob/89388ca675af39c70e72f9174c1f112b04613703/LICENSE)
- Local integrity manifest: `assets/decoy-sites/v2ray-agent.sha256`

The archives are not copied into this repository. They are fetched only when a
user explicitly selects a v2ray-agent template, from the pinned commit above,
then verified against the recorded SHA-256 before extraction. The three
single-file templates stored directly under `assets/decoy-sites/` are original
songbox assets and are separate from the v2ray-agent templates.

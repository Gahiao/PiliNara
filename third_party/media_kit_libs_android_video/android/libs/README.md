这里不再需要手工放置 libmpv jar。

PiliNara 构建时由 `android/build.gradle` 自动从
https://github.com/Gahiao/libmpv-android-video-build/releases/latest/download
下载最新一次 fork 构建的 `default-<abi>.jar` 与 `SHA256SUMS`，校验 SHA-256 后放进
`build/output`。因此只要 fork 的 Build workflow 跑过，App 的 Android 构建就会自动用上新库。

本地残留的 jar 会被忽略，也不会再被优先使用；需要离线构建时，请先让 fork 发布
`libmpv-latest`，或临时把 jar 放入 `build/output`。

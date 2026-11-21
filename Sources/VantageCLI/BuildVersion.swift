// SPDX-License-Identifier: MIT

/// 版本号是**构建时注入**的常量，运行时不读 Info.plist、不解析路径。
///
/// `Scripts/build_app.sh <version>` 在编译前调用 `Scripts/inject_version.py`，
/// 把同一个版本号写进这里和产物那份 Info.plist；不传参数就是 `nightly`
/// （CI 里 tag `v1.2.5` → `1.2.5`，其它触发 → `nightly`）。
///
/// 所以：
///   * 改版本请打 tag 或给构建脚本传参，**不要手改这个常量**；
///   * 仓库里留 `nightly` 只是「没走构建脚本」时的默认值，比如 `swift run`；
///   * 二进制被软链、被拷走、甚至 bundle 被删掉，`--version` 照样准确 ——
///     它就在 `__TEXT` 段里。
enum BuildVersion {
    static let marketing = "1.3.0"
}

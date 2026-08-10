# 琥珀护眼 (Amber)

> [English](README.md)

[![CI](https://github.com/TzJ2006/EyeCareAmber/actions/workflows/ci.yml/badge.svg)](https://github.com/TzJ2006/EyeCareAmber/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

面向 macOS 15 及更高版本的菜单栏光照工具。Apple Silicon 原生，稳态 CPU 占用 0.0%。

---

## 快速开始

### 下载

到 [Releases](https://github.com/TzJ2006/EyeCareAmber/releases) 取通用二进制版本。

```bash
unzip Amber-1.0.0-universal.zip
mv Amber.app /Applications/
xattr -dr com.apple.quarantine /Applications/Amber.app
open /Applications/Amber.app
```

**`xattr` 那行是必须的。** 发布版只做了临时签名、没有公证——这个项目背后没有付费的 Apple 开发者证书。macOS 会隔离一切从网上下载、且它无法验证的程序，直接拒绝启动。不想运行这条命令就从源码构建，本地构建出来的 app 不会带隔离标记。

### 从源码构建

```bash
git clone https://github.com/TzJ2006/EyeCareAmber.git
cd EyeCareAmber && ./build.sh --install
```

构建产物在 `build/Amber.app`，`--install` 会装到 `/Applications` 并启动。启动后看菜单栏右上角。

```bash
./build.sh              # 仅 arm64（推荐）
./build.sh --universal  # arm64 + x86_64
```

---

## 技术方案：为什么不用覆盖窗口

大多数同类工具的做法是**盖一层半透明黄色窗口**。本项目改用**修改显示器 Gamma 查找表（LUT）**，这是 f.lux 和系统「夜览」采用的路径。

| | 覆盖窗口 | Gamma LUT（本项目） |
|---|---|---|
| 持续开销 | 合成器每帧多混合一层全屏图层 | **0** — 写一次进显示管线，之后由扫描输出硬件应用 |
| 覆盖范围 | 盖不住比它层级更高的东西 | 所有屏幕、所有窗口、全屏应用、游戏、菜单栏、Dock |
| 对比度 | 往画面上加光，黑色变灰 | 缩放输出，黑还是黑 |
| 截图 / 录屏 | 会被拍进去 | 不影响（通常是优点） |

代价：极少数采集卡 / 虚拟显示器写不进 LUT。程序会自动检测并回落到覆盖窗口，也可以在高级设置里强制。

覆盖窗口只用于用户明确设置的“额外调暗”或 LUT 不可用时的兼容回落。科学预设的深夜额外调暗为 0；不需要时窗口不会创建。

### 与系统自动亮度的分工

请开启 macOS 自动亮度。系统负责环境光传感器与硬件背光，Amber 不读取 ALS、也从不设置系统亮度，只在当前背光上叠加 LUT 相对衰减。

但在内置屏上，Amber 会从 IORegistry 的 `AppleARMBacklight` 读取由此得到的背光 nits。这补上了纯相对衰减补不上的那一环：同样的 ×0.75 系数，在 400 nits 背光下是 119 nits，在 30 nits 背光下只有 8.9 nits，而后者低于所有已发表的舒适下界。屏幕已经够暗时 Amber 就停止继续压暗 —— 保证任何情况下都不会比不开它更难看清。外接屏与 Intel Mac 没有这个节点，那里只按相对衰减执行时间曲线。

### 功耗设计

- **没有轮询循环。** 单个 `DispatchSourceTimer`，下一次触发时刻由排班器算出来。
- **斜坡期按感知阈值自适应步进**，不是固定间隔。色温阈值 5 mired、亮度阈值 0.8%，都低于人眼在渐变、无参照条件下的分辨能力。平滑曲线两端能连睡十几分钟，只有最陡的中段才几十秒醒一次。
- **给足 leeway**（平台期 300 秒），让内核把我们的唤醒和其它进程合并。
- **增益不变就不写 LUT。**
- **UI 只在菜单打开时更新。**
- 没有 `CVDisplayLink`、没有逐帧回调、没有常驻后台线程。

实测：24 小时约 271 次定时器唤醒（平均 5 分钟一次）。作为对照，一台空闲的 Mac 每秒就有上千次定时器唤醒。

---

## 医学依据

先说三件文献支持不了的事，避免这个软件建立在错误前提上：

1. **屏幕蓝光不会损伤眼睛。** 美国眼科学会（AAO）的立场是数字设备的蓝光既不导致眼疲劳也不导致眼病。屏幕蓝光强度约为自然日光的千分之一。
2. **蓝光过滤眼镜对眼疲劳没有确证效果。** 2023 年 Cochrane 系统综述（17 项研究，619 人）结论是：短期随访下，蓝光过滤镜片相比普通镜片**可能不能**减轻电脑使用引起的眼疲劳，对最佳矫正视力也无差异，且没有证据表明能保护视网膜。
3. **数字眼疲劳的主因是用眼方式，不是光谱。** 盯屏幕时眨眼频率下降、调节持续紧张、干眼 —— 这些才是症状来源。有效对策是 20-20-20 法则（每 20 分钟看 20 英尺外 20 秒）。

**所以这个软件真正有依据的目标不是「护眼」，而是「减少夜间光照对昼夜节律和睡眠的干扰」，外加傍晚降低屏幕与环境的亮度反差。** 这两件事证据都是扎实的。

### 光照剂量：具体数值从哪来

Brown et al. (2022, *PLOS Biology*) 是目前最权威的专家共识，由 Brainard、Cajochen、Czeisler、Lockley 等昼夜节律领域核心研究者共同签署。它用 **melanopic EDI**（黑视素等效日光照度，CIE S 026:2018 定义）作为量纲，给出：

| 时段 | 建议 melanopic EDI（眼位垂直面） |
|---|---|
| 白天 | **≥ 250 lux** |
| 就寝前 3 小时 | **≤ 10 lux** |
| 睡眠期间 | **≤ 1 lux**（夜间必要活动 ≤ 10 lux） |

同时明确：白天的光**应当**富含接近黑视素作用光谱峰值的短波成分；傍晚的光则应当在该波段贫化。

**这直接决定了本软件的曲线形状：白天刻意不加黄。** 日间充足的短波光是稳定生物钟的正向输入，全天候暖色是帮倒忙。

### 为什么必须同时降亮度

Nagare, Plitnick & Figueiro (2019) 测试了 iPad 的「夜览」功能对褪黑素抑制的实际效果，全程把屏幕亮度锁在最大档：Less Warm 档（5997 K）两小时后褪黑素下降 19%，More Warm 档（2837 K）下降 12% —— 两档之间无显著差异，而且**相对昏暗对照，所有条件都仍造成了显著抑制**。该研究没有「关闭夜览」这一组，所以它说不了夜览相对原生屏值多少；它能说明的是：在亮度不变的前提下，把滑块从最冷端拉到最暖端救不了你。

结论是：**只改光谱、不降亮度，不足以避免褪黑素抑制。**

本软件因此把光谱与剂量同时纳入预设：睡前使用 4300 K ×0.55，模型相对输出约 42.6%；深夜使用 2700 K ×0.56，约 30.0%。这里的系数是叠加在系统背光之上的 LUT 衰减，不是硬件亮度；滑杆同时显示“系数”和模型“相对输出”。

深夜这一对值是为了同时满足两个终点而定的。先定住亮度：约 30% 相对输出，在常见的昏暗房间背光下落在 36 cd/m² 附近，正对上 Li et al. (2026) 的低刺激条件 —— 那一档在 DLMO、皮质醇、主观睡眠、视觉疲劳**和**认知表现上同时改善，是唯一一个两个终点都往好处走的实测亮度。而屏幕过暗本身就是疲劳来源（Yu & Akita 2019：9 cd/m² 引发身体、心理与视觉三类疲劳，25 cd/m² 只剩视觉疲劳）。

色温则取在两条代价曲线的交叉点。固定上述亮度后，屏幕越暖 melanopic 输出近似线性下降，蓝通道却是断崖式的：从 2700 K 再降到 1950 K，melanopic 只再降约 5 个百分点，蓝通道增益却从 0.101 塌到 0.0037，相差 27 倍，蓝色界面元素直接变黑。比 2700 K 更暖，就是付出的多、拿到的少了。

### 波长选择

黑视素（melanopsin）在 ipRGC 上的作用光谱峰值约 480 nm，经晶状体前滤过后在视网膜上的有效峰值约 **490 nm** —— 这是褪黑素抑制和昼夜相位偏移的主要输入通道。程序内置的曲线用 Govardovskii A1 视色素模板（λmax = 490 nm）生成，自检验证峰值落在 490 nm。

夜间干预研究普遍采用**截止 550 nm 以下**的琥珀色滤片。Burkhart & Phelps (2009) 和 Shechter et al. (2018) 的随机对照试验显示，睡前 2 小时佩戴琥珀镜片能改善主观和客观（活动记录仪）睡眠指标。本软件深夜档默认 2700 K —— 这是有直接褪黑素数据支撑的最暖色温（Nagare, Rea, Plitnick & Figueiro 2019 实测 2700 K 抑制 18.4%，6500 K 为 24.7%）；已核实的文献在约 3000 K 到 4400 K 之间是完全空白的。滑杆仍可拖到 1950 K 供想要最大琥珀的人使用，停在那里是因为低于约 1930 K 蓝通道增益已被 clamp 成精确的 0，再往下不会有任何变化。

### 傍晚为什么也要降亮度

ISO 9241-303 建议在 500 lx 水平照度下屏幕亮度取 100–150 cd/m²。低照度环境下的舒适区间要低得多，但文献对「低到哪里」并不统一：已发表的暗环境最优值大致散布在 20–65 cd/m²，跨研究相差接近五倍。Amber 因此把 20 cd/m² 当作下界而非目标。天黑了屏幕还维持正午亮度，是傍晚视觉不适的主要来源之一 —— 这就是「黄昏」过渡段存在的理由。

---

## 功能说明

### 智能模式

按作息锚点（起床 / 就寝）自动排班：

| 阶段 | 时机 | 默认值 |
|---|---|---|
| 白天 | 起床 → 就寝前 3 小时 | 6500 K ×1.00 |
| 黄昏 | 日落起（若早于上一行边界） | 平滑到约 5280 K ×0.84 |
| 睡前 | 就寝前 3 小时起，渐变 90 分钟后保持 | 4300 K ×0.55 |
| 深夜助眠 | 就寝起，渐变 45 分钟后保持 | 2700 K ×0.56，无额外调暗 |
| 拂晓 | 起床前 30 分钟 | 拉回白天值 |

所有过渡用 smoothstep，色温在 mired 空间插值（这才符合人眼对色温变化的感知线性）。

### 日出日落来源

四选一，默认第二个：

| 来源 | 说明 |
|---|---|
| 关闭 | 只按起床 / 就寝时间排班 |
| **跟随系统外观**（默认） | macOS「外观 - 自动」在日落时切深色。监听 `AppleInterfaceThemeChangedNotification` 即可反推日落时刻。**不需要定位权限、不耗电。** 前提是系统设置里外观选了「自动」 |
| 使用定位 | CoreLocation 只取一次坐标缓存到本地，之后全部本地计算，不会持续定位 |
| 手动坐标 | 自己填经纬度，0.1° 精度即可（误差 < 1 分钟） |

日出日落用 NOAA Solar Calculator 算法本地计算。自检对照结果：

| 地点 / 日期 | 本程序 | 参考值 |
|---|---|---|
| 格林尼治 2025-06-21 | 日出 03:42、日落 20:20 UTC | 03:43、20:21 |
| 格林尼治 2025-12-21 | 日出 08:03、日落 15:52 UTC | 08:04、15:53 |
| 北京 2025-03-20 | 日出 06:18、日落 18:25 CST | 06:19、18:26 |

### 手动模式

色温（1950–6500 K）、LUT 系数、额外调暗三个滑块；手动默认 4500 K ×0.80。夜间色温范围为 1950–4500 K。夜间助眠开着时，进入深夜窗口仍会自动切到更保守的值。

### 实时指标

菜单里显示当前设置对应的：

- **melanopic 输出** —— 驱动褪黑素抑制的那部分光，相对原生白点满亮度的比例
- **相对输出** —— LUT 与覆盖层共同作用后的明视觉模型输出
- **蓝通道衰减** —— LUT 与覆盖层共同作用后的模型衰减

数值基于典型 LED 背光 sRGB 面板的光谱模型。**它们只描述相对屏幕输出，用于横向比较，不是硬件亮度、lux、nits 或绝对 mEDI。**

参考数值：

| 档位 | melanopic 输出 | 相对输出 | 假设系统背光 30 / 120 / 400 nits |
|---|---|---|---|
| 白天 6500 K ×1.00 | 99.9% | 100% | 30 / 120 / 400 nits |
| 睡前 4300 K ×0.55 | 32.8% | 42.6% | 12.8 / 51.1 / 170.4 nits |
| 深夜 2700 K ×0.56 | 15.3% | 30.0% | 9.0 / 36.0 / 120.1 nits |

绝对亮度一栏只是给定背光值的演算，不是运行时测量或保证。

---

## 自检

```bash
swift run Amber --selftest             # 色度学、黑视素曲线、日出日落、24 小时排班走查
swift run Amber --compare-presets      # 比较 v1/v2 预设并验证相对指标与背光情景
swift run Amber --apply 2700 0.62      # 端到端验证 LUT 写入精度，并确认还原
swift run Amber --restore-test         # 验证还原对显示器校准无损
swift run Amber --render-ui out.png    # 把菜单界面离屏渲染成 PNG
python3 Scripts/check-localization.py  # 四语 key 一致性 + 语言码与构建产物核对
python3 Scripts/check-readme-parity.py  # 两份 README 的命令、参数、数字保持同步
```

`check-localization.py` 里那条「语言码 vs 构建产物」的检查有真实来由：源码目录是 `Resources/zh-Hans.lproj`，但 SwiftPM 打进 `Amber_Amber.bundle` 时会把名字**转成小写** `zh-hans.lproj`。`Bundle.path(forResource:ofType:)` 按精确字符串匹配资源表，大小写对不上就返回 nil，中文界面会静默退化成显示原始 key —— 编译不报错，只有切到中文才看得见。所以必须对着**构建产物**核对，而不是对着源码目录。

`--render-ui` 不需要 accessibility 权限也不用手点菜单栏：把真实的 `MenuContentView` 挂到窗口上跑完整布局再截图，能抓到编译期发现不了的布局问题（内容溢出、控件宽度不足、颜色对比度不够）。

`--restore-test` 值得说明：它先人为写入一条带 S 形的非线性假校准曲线，跑完整个「抓基线 → 施加 → 还原」循环后逐点比对整张表，并与「只写入再读回」的对照组做差，剥离表长重采样噪声。

**这个测试是有来由的：** 最初的实现用 `CGDisplayRestoreColorSyncSettings()` 还原，实测发现它会把内建 XDR 屏上系统加载的校准曲线直接抹成线性斜坡，且不会自行恢复 —— 等于永久破坏用户的显示器校准直到重新登录。现在改为写回启动时抓取的原始 LUT，归因误差 0.000000。

---

## 已知限制

- **别同时开系统「夜览」**。它工作在 gamma 层之下，并不会覆写 LUT —— 两者的变暖效果是相乘叠加，结果比任何一方想要的都更暖。真正会争抢同一张表的是 f.lux、Lunar、BetterDisplay 与 MonitorControl；程序每 15 分钟会检查 LUT 有没有被它们覆写，被覆写时会把对方的表当作新基线重新接管 —— 但这只是止损，不是好的使用方式。
- 绝对 nits 只在 Apple Silicon 内置屏上可读，且依赖一个未公开、Apple 随时可能改名的 IORegistry 键。外接屏、Intel Mac，或该键位置变动时，Amber 退回纯相对衰减，舒适下界无法强制。
- LUT 压暗只缩放白场、不动黑电平，所以 LCD 上屏幕实测对比度会随输出系数一起下降。mini-LED XDR 面板上这个损失可忽略，MacBook Air 上则不然。
- 写 gamma 表会让 macOS 在 Amber 生效期间关闭 HDR/EDR。
- 有报告（FB18559786、FB19136488）称「自动调节亮度」开启时，Apple Silicon 内置屏上的 `CGSetDisplayTransferByTable` 会被静默忽略。它在部分 macOS 构建上复现、部分不复现；`--apply` 会写完读回来比对，颜色一直没变化时请先跑它。
- 环境光可能主导眼位总剂量；相对 melanopic 指标只描述屏幕模型，不代表房间总光或绝对 mEDI。
- 暴露时长也是剂量的一部分。Wood et al. 的平板实验中，单独使用最高亮度平板 1 小时尚未显著抑制褪黑素，2 小时后达到显著；Amber 本次不追踪使用时长。
- LUT 修改不会出现在截图和屏幕录制里。
- 极少数采集卡 / 虚拟显示器不支持写 LUT，程序会自动回落到覆盖窗口。
- 覆盖窗口层级在 `CGShieldingWindowLevel` 之上，会盖住系统弹窗（但点击穿透，不影响操作）。
- 开机自启依赖 `SMAppService`，需要 app 已签名（`build.sh` 会做临时签名）且位于稳定路径，建议装到 `/Applications`。

---

## 代码结构

```
Sources/Amber/
  main.swift              入口，先处理诊断参数
  AmberApp.swift          MenuBarExtra + AppDelegate + 信号处理
  Diagnostics.swift       自检 / 验证工具（selftest、apply、restore-test、compare-presets、render-ui）
  Localization.swift      四语字符串表加载与格式化
  Core/
    ColorScience.swift    CIE 色匹配函数、普朗克轨迹、黑视素作用光谱、melanopic 指标
    SolarClock.swift      NOAA 日出日落算法
    SolarProvider.swift   三种日照信息来源的统一出口
    Schedule.swift        时间 → 光照目标（纯函数）+ 自适应步进
    Settings.swift        持久化，宽容解码（升级不丢配置）
    GammaController.swift LUT 读写、基线管理、无损还原、覆写检测
    OverlayController.swift 覆盖窗口（仅额外调暗 / 回落时使用）
    Engine.swift          编排 + 低功耗定时 + 系统事件
  UI/
    MenuContentView.swift 菜单界面
  Resources/
    {en,fr,es,zh-Hans}.lproj/Localizable.strings
Scripts/
  check-localization.py   本地化完整性校验
```

`Schedule.evaluate` 和 `ColorScience` 全部是纯函数，不碰系统 API，可以单独验证 —— 这也是自检能覆盖核心逻辑的原因。

---

## 参考文献

- Brown TM, Brainard GC, Cajochen C, et al. (2022). Recommendations for daytime, evening, and nighttime indoor light exposure to best support physiology, sleep, and wakefulness in healthy adults. *PLOS Biology* 20(3): e3001571. https://doi.org/10.1371/journal.pbio.3001571
- Singh S, Keller PR, Busija L, McMillan P, Makrai E, Lawrenson JG, Hull CC, Downie LE (2023). Blue-light filtering spectacle lenses for visual performance, sleep, and macular health in adults. *Cochrane Database of Systematic Reviews* 8: CD013244. https://doi.org/10.1002/14651858.CD013244.pub2
- Nagare R, Plitnick B, Figueiro MG (2019). Does the iPad Night Shift mode reduce melatonin suppression? *Lighting Research & Technology* 51(3): 373–383. https://doi.org/10.1177/1477153517748189
- Wood B, Rea MS, Plitnick B, Figueiro MG (2013). Light level and duration of exposure determine the impact of self-luminous tablets on melatonin suppression. *Applied Ergonomics* 44(2): 237–240. https://doi.org/10.1016/j.apergo.2012.07.008
- Burkhart K, Phelps JR (2009). Amber lenses to block blue light and improve sleep: a randomized trial. *Chronobiology International* 26(8): 1602–1612.
- CIE S 026/E:2018. *System for Metrology of Optical Radiation for ipRGC-Influenced Responses to Light.*
- Govardovskii VI, Fyhrquist N, Reuter T, et al. (2000). In search of the visual pigment template. *Visual Neuroscience* 17(4): 509–528.
- Wyman C, Sloan PP, Shirley P (2013). Simple analytic approximations to the CIE XYZ color matching functions. *Journal of Computer Graphics Techniques* 2(2): 1–11.
- Kim YS, et al. (1996). 普朗克轨迹三次多项式近似（1667–25000 K）。
- American Academy of Ophthalmology. *Should You Be Worried About Blue Light?* https://www.aao.org/eye-health/tips-prevention/should-you-be-worried-about-blue-light
- ISO 9241-303:2011. *Ergonomics of human-system interaction — Requirements for electronic visual displays.*

---

## 参与贡献

改动前请先跑通这三样，它们覆盖了这个项目最容易回归的地方：

```bash
swift build && swift run Amber --selftest && python3 Scripts/check-localization.py
```

改光照参数时，务必用 `--compare-presets` 看一眼改动对 **melanopic 剂量**的净影响。这个项目踩过的最大的坑就是：照着一篇论文的结论调色温，却没算改完之后的剂量往哪边走 —— 视觉疲劳文献和昼夜节律文献优化的是**不同终点**，两者的最优解经常相反。

新增界面文案要同时补齐 `en` / `fr` / `es` / `zh-Hans` 四份 `Localizable.strings`，缺一条就会在对应语言里显示原始 key。

## 许可证

[MIT](LICENSE)

本项目不是医疗器械，也不提供医学建议。所有参数是基于公开文献的**工程起点**，不是临床阈值。个体对夜间光的敏感度差异可超过一个数量级（Phillips et al., 2019），有睡眠障碍或眼科疾病请咨询专业人士。

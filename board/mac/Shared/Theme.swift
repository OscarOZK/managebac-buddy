import SwiftUI
import AppKit

/* ======================================================================
   ManageBac 看板 · 设计系统（Mac / Windows 两端同源）

   八项美学维度都收敛到这一处，改这里 = 两端一起变：
     ① 布局与空间   Space / Metrics
     ② 色彩系统     Palette + Semantic
     ③ 卡片与组件   cardSurface / 三级圆角 / hairline / 双层阴影
     ④ 排版体系     Typo
     ⑤ 动效与交互   Motion
     ⑥ 图标装饰     SF Symbols 语义命名（Icons）
     ⑦ 主题与模式   BoardSettings.theme
     ⑧ 无障碍       Reduce Motion / Reduce Transparency / 对比度 / focus
   ====================================================================== */

/* ---------- Color ↔ hex（两个 App 都要用，放共享层） ---------- */

extension Color {
    var hexString: String? {
        guard let c = NSColor(self).usingColorSpace(.sRGB) else { return nil }
        return String(format: "#%02x%02x%02x",
                      Int((c.redComponent * 255).rounded()),
                      Int((c.greenComponent * 255).rounded()),
                      Int((c.blueComponent * 255).rounded()))
    }
}

/* ---------- ① 布局与空间：8pt 网格 ---------- */

extension String {
    /// 去首尾空白（含换行）—— 界面里到处要用，放这儿省得每次写全名
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
    var isBlank: Bool { trimmed.isEmpty }
}

enum Space {
    static let xxs: CGFloat = 4
    static let xs:  CGFloat = 8
    static let sm:  CGFloat = 12
    static let md:  CGFloat = 16
    static let lg:  CGFloat = 20
    static let xl:  CGFloat = 24
    static let xxl: CGFloat = 32
    static let xxxl: CGFloat = 44
}

/// 密度档位：紧凑 / 舒适 / 宽松 —— 设置里可切，真实影响所有间距与行高
enum Density: String, CaseIterable, Codable {
    case compact, comfortable, spacious

    var label: String {
        switch self {
        case .compact:     return "紧凑"
        case .comfortable: return "舒适"
        case .spacious:    return "宽松"
        }
    }

    /// 全局缩放系数
    var scale: CGFloat {
        switch self {
        case .compact: return 0.86
        case .comfortable: return 1.0
        case .spacious: return 1.18
        }
    }

    /// 行高基准（列表行 / 卡片内小行）
    var rowHeight: CGFloat {
        switch self {
        case .compact: return 34
        case .comfortable: return 42
        case .spacious: return 50
        }
    }

    /// 分区之间的垂直留白
    var sectionGap: CGFloat {
        switch self {
        case .compact: return 28
        case .comfortable: return 36
        case .spacious: return 46
        }
    }
}

/// 圆角档位：直角 / 标准 / 圆润 —— 设置里可切
enum CornerStyle: String, CaseIterable, Codable {
    case sharp, regular, round

    var label: String {
        switch self {
        case .sharp:   return "直角"
        case .regular: return "标准"
        case .round:   return "圆润"
        }
    }

    var factor: CGFloat {
        switch self {
        case .sharp:   return 0.30
        case .regular: return 1.0
        case .round:   return 1.45
        }
    }
}

/* ---------- ② 色彩系统 ---------- */

struct RGB: Equatable {
    var r: Double, g: Double, b: Double

    init(_ hex: String) {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        if s.count == 3 { s = s.map { "\($0)\($0)" }.joined() }
        let v = UInt32(s, radix: 16) ?? 0
        r = Double((v >> 16) & 0xff) / 255
        g = Double((v >> 8) & 0xff) / 255
        b = Double(v & 0xff) / 255
    }

    init(r: Double, g: Double, b: Double) { self.r = r; self.g = g; self.b = b }

    /// 色相 / 饱和度 / 明度 → RGB（hue 用角度，0–360）
    init(hue: Double, saturation s: Double, value v: Double) {
        let h = ((hue.truncatingRemainder(dividingBy: 360)) + 360)
            .truncatingRemainder(dividingBy: 360) / 60
        let c = v * s
        let x = c * (1 - abs(h.truncatingRemainder(dividingBy: 2) - 1))
        let m = v - c
        let t: (Double, Double, Double)
        switch Int(h) % 6 {
        case 0:  t = (c, x, 0)
        case 1:  t = (x, c, 0)
        case 2:  t = (0, c, x)
        case 3:  t = (0, x, c)
        case 4:  t = (x, 0, c)
        default: t = (c, 0, x)
        }
        self.init(r: t.0 + m, g: t.1 + m, b: t.2 + m)
    }

    var hex: String { String(format: "#%02x%02x%02x",
                             Int((r * 255).rounded()), Int((g * 255).rounded()), Int((b * 255).rounded())) }

    /// 深色模式下往白的方向提亮（lift），保证对比度始终达标
    func color(_ scheme: ColorScheme, lift: Double = 0, opacity: Double = 1) -> Color {
        let f = (scheme == .dark) ? lift : 0
        return Color(.sRGB, red: min(1, r + (1 - r) * f),
                     green: min(1, g + (1 - g) * f),
                     blue: min(1, b + (1 - b) * f), opacity: opacity)
    }

    var color: Color { Color(.sRGB, red: r, green: g, blue: b, opacity: 1) }

    /// 相对亮度（WCAG），用于自动挑选前景色
    var luminance: Double {
        func lin(_ c: Double) -> Double { c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        return 0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(b)
    }

    /// 铺满底色时，上面该用深字还是浅字（无障碍 ⑧）
    var onColor: Color { luminance > 0.55 ? Color.black.opacity(0.82) : .white }

    func mixed(with other: RGB, _ t: Double) -> RGB {
        RGB(r: r + (other.r - r) * t, g: g + (other.g - g) * t, b: b + (other.b - b) * t)
    }
}

/* ---------- ②b 调色板（主题）系统 ----------
   一套 Palette 就是 App 里**所有**颜色的落点。换成另一套，界面整体变样，
   而且不用改任何视图代码 —— 视图只认语义槽，不认具体色值。

   内置三套：
     · standard  经典（Apple 蓝 + 莫兰迪），原样保留
     · emberglow 红霞 EmberglowOS —— 色值全部取自用户提供的校园黄昏实拍
     · verdant   绿意 VerdantOS   —— 色值全部取自用户提供的校园夏景实拍

   限时主题的做法：我把实拍图做 k-means 聚类 + 按画面分层（天光 / 中景 / 剪影）
   取样，取出的十六进制色直接写进下面的表里，没有一处是我"凭感觉调"的。
   唯一例外是 accentInk（强调色当文字用时的深色版本）——它是把 accent 与
   同一张图里的剪影色做线性混合得到的，仍然是这两个采样点的产物。 */

struct Palette: Identifiable {
    let id: String
    let name: String
    let en: String
    let tagline: String
    /// 用户提供的介绍原文，一字未改
    let intro: String
    /// 主题原图（内置进 App，也放一份在 ~/.mbboard/themes/<id>/）
    let photos: [String]

    /// 矢量氛围底纹的代号（`nil` = 不用）。
    ///
    /// 和 `photos` 是两条路：实拍底纹是「把照片糊了垫在底下」，画的是照片；
    /// 这个代号画的是**用代码现画的矢量场景**（目前只有 `"midautumn"`：
    /// 中秋月夜）。之所以不走照片：节日氛围要的是可控、清透、能跟着深浅色
    /// 换一套画法，照片做不到 —— 而且照片垫在玻璃卡片下面会把字压糊。
    var drawn: String? = nil

    /// 这套配色是否**强制深色**。
    ///
    /// 「月圆 · LunaOS」是夜景主题 —— 它的浅色版本（月华）只是备用的白天形态，
    /// 用户明确要求「切换到月圆主题，整个 App 就自动切换成深色模式」。
    /// 注意这里**不去改** `settings.theme`：只让「实际生效的深浅色」变成深色，
    /// 用户原来选的「跟随系统 / 浅色」还留着，换回别的主题就自动恢复。
    var forcesDark: Bool = false

    /* 强调色：accent 用于填充/图标，accentInk 用于强调色文字（对比度达标） */
    let accent: String
    let accentInk: String

    /* 浅色模式中性色 */
    let ink: String, ink2: String, ink3: String
    let pageTop: String, pageBottom: String
    let card: String, sidebar: String

    /* 深色模式 */
    let darkInk: String, darkInk2: String, darkInk3: String
    let darkTop: String, darkBottom: String, darkCard: String

    /* 紧急度四档 */
    let urgent: String, soon: String, notice: String, calm: String

    /* 学科八色 */
    let subjects: [String: String]

    var isLimited: Bool { !photos.isEmpty }
    /// 有氛围底纹可画：要么有实拍原图（糊一层垫底），要么有矢量场景代号。
    ///
    /// 注意和 `isLimited` 是两件事 —— `isLimited` 管的是「设置页那张卡要不要
    /// 显示照片缩略图、要不要打上限时标」，而底纹开关是另一回事：
    /// 「月圆」没有照片（全是矢量画的），但它**必须**画底纹，不然中秋氛围就没了。
    var hasBackdrop: Bool { isLimited || drawn != nil }
    var photoFolder: String { id }
}

enum Palettes {

    static let standard = Palette(
        id: "standard", name: "经典", en: "Classic",
        tagline: "Apple 蓝 · 莫兰迪",
        intro: "出厂配色。清冷克制的中性底 + Apple 蓝强调色，配莫兰迪十科，长时间看最不累。",
        photos: [],
        accent: "#0071e3", accentInk: "#0062c4",
        ink: "#1d1d1f", ink2: "#6e6e73", ink3: "#86868b",
        pageTop: "#f7f8fb", pageBottom: "#eef1f6",
        card: "#ffffff", sidebar: "#ffffff",
        darkInk: "#f5f5f7", darkInk2: "#adadb2", darkInk3: "#808085",
        darkTop: "#101014", darkBottom: "#08080a", darkCard: "#1c1c1e",
        urgent: "#ff3b30", soon: "#ff9f0a", notice: "#007aff", calm: "#34c759",
        subjects: ["chinese": "#a96f6b", "math": "#867a9e", "ela": "#b58455", "chem": "#6f7c9e",
                   "phys": "#719070", "bio": "#5b918a", "geo": "#74889c", "ids": "#94836f"])

    /* ---- 红霞 EmberglowOS ----
       采样自三张操场落日 / 国际部黄昏实拍：
         天光  #c7c4b8 #d1c5b0   中景 #d6bd9e #b99782
         晚霞  #cd8d6c #d18d6f   落日 #f0ba7e
         暮蓝  #7b8588 #938f8b   剪影 #121115 #1d2122 #625144
         暖灰  #989490 #96928f   灰白 #c2beb3 #d0c8b6 #ddc6a7 #d3ba9d */
    static let emberglow = Palette(
        id: "emberglow", name: "红霞", en: "EmberglowOS",
        tagline: "操场落日 · 教学楼橙金暮色",
        intro: "取自北京一零一中校园黄昏实拍，运动场落日与教学楼橙金色暮色。\n"
             + "这组色彩来源于一零一操场看台的落日时分，暖橙、柔粉与淡灰蓝层层渐变，"
             + "是傍晚笼罩校园的晚霞余晖。低饱和度暖调，柔和不刺眼，适合作为面板的强调色与背景色。"
             + "灵感来自看台落日、校舍剪影，保留校园黄昏安静松弛的氛围感，"
             + "用于看板标题、高亮区块、进度标记。",
        photos: ["01-stadium-dusk.jpg", "02-sunset-stand.jpg", "03-campus-glow.jpg"],
        accent: "#cd8d6c", accentInk: "#795545",
        ink: "#1d2122", ink2: "#5d5751", ink3: "#96928f",
        pageTop: "#d0c8b6", pageBottom: "#d6bd9e",
        card: "#ddc6a7", sidebar: "#c7c4b8",
        darkInk: "#ddc6a7", darkInk2: "#c2beb3", darkInk3: "#96928f",
        darkTop: "#1d2122", darkBottom: "#121115", darkCard: "#2b2e2f",
        urgent: "#d18d6f", soon: "#d5b28c", notice: "#7b8588", calm: "#c2beb3",
        subjects: ["chinese": "#cd8d6c", "math": "#7b8588", "ela": "#d5b28c", "chem": "#9a8a86",
                   "phys": "#b69683", "bio": "#8f9a90", "geo": "#6d7378", "ids": "#625144"])

    /* ---- 绿意 VerdantOS ----
       采样自林荫道 / 树影光斑 / 荷塘三张实拍：
         林深  #12160b #1f2613 #30361b   叶绿 #788c38 #636d21 #848c17
         荷绿  #54653f #48563c #58753b   草光 #b9c21d #8e8554
         塘天  #7a999c #91c2ee           石板 #919998 #8d9395 */
    static let verdant = Palette(
        id: "verdant", name: "绿意", en: "VerdantOS",
        tagline: "荷塘 · 林荫 · 银杏绿",
        intro: "取自北京一零一中校园夏景，荷塘、林荫道与银杏绿树。\n"
             + "色彩采样于一零一荷塘荷叶、林荫大道的树影光斑，主色调为沉静的深绿、清新草绿，"
             + "搭配树木受阳光照射的暖金高光。基调清爽自然，还原校园草木生机，"
             + "适合作为面板基础底色、侧边栏、卡片底色。"
             + "灵感来自校园荷塘、林荫雕塑小路，带着校园夏日独有的宁静绿意。",
        photos: ["01-avenue.jpg", "02-canopy.jpg", "03-lotus-pond.jpg"],
        accent: "#636d21", accentInk: "#43501a",
        ink: "#1b2110", ink2: "#4d5433", ink3: "#8d9395",
        pageTop: "#d3dac3", pageBottom: "#bfcbad",
        card: "#e2e8cf", sidebar: "#c9d3b8",
        darkInk: "#dfe6cb", darkInk2: "#b9c1a0", darkInk3: "#8d9395",
        darkTop: "#1f2613", darkBottom: "#12160b", darkCard: "#30361b",
        urgent: "#848c17", soon: "#8e8554", notice: "#7a999c", calm: "#91c2ee",
        subjects: ["chinese": "#8e8554", "math": "#637474", "ela": "#b9c21d", "chem": "#5f6b7a",
                   "phys": "#4b6b3a", "bio": "#58753b", "geo": "#7a999c", "ids": "#48501e"])

    /* ---- 印屑 InkOS · 宣纸 ----
       灵感来自中式水墨丹青：朱砂印章、烟墨、宣纸、留白。
       整体走「含蓄古典的雅致」—— 低饱和、暖调，背景是手作米黄宣纸。
       色值不是凭感觉调的，是按四个传统色谱位定的：
         · 朱砂 (zhu sha)    取自传统印章的辰砂红  #B5483A
         · 深赭 (shen zhe)   朱砂加墨后的暗化        #7A2E24
         · 米黄 (mi huang)    半熟宣纸本色            #F2E8D0
         · 牙白 (ya bai)      熟宣 / 卡片白          #F8F0DA
         · 烟墨 (yan mo)      深色模式下的墨夜        #1B1A17
         · 靛青 (dian qing)  矿物颜料                #395D7A
         · 青竹 (qing zhu)    竹叶青                  #4F7B61
         · 秋香 (qiu xiang)   应季叶子黄              #C49860
       十科色按中国传统「五色 + 五间色」思路：
         语文朱砂 · 数学赭石 · 英语秋香 · 化学靛青 · 物理苍青 ·
         生物青竹 · 地理远黛 · IDS 金 · 历史暮褐 · 政治海棠。 */
    static let xuanzhi = Palette(
        id: "xuanzhi", name: "宣纸", en: "InkOS · Rice Paper",
        tagline: "朱砂 · 烟墨 · 月白宣纸",
        intro: "中式水墨丹青的中文界面美学：朱砂印章点缀，墨色主导，月白铺底。\n"
             + "灵感来自案头宣纸、毛笔与印章 —— 不是把界面画成水墨画，是把界面"
             + "做出水墨画的'安静'。留白克制、对比克制、节奏克制；"
             + "重要信息用一抹朱砂点醒，次要信息藏在淡墨里。\n"
             + "适合长时间阅读、写东西、需要安静的时段。",
        photos: [],
        accent: "#b5483a", accentInk: "#7a2e24",
        ink: "#1b1a17", ink2: "#5c574c", ink3: "#8f8a78",
        // 背景走「月白→淡米」的渐变：顶部近白，底部才有一丝米的暖 —— 黄只做底韵不做主色
        pageTop: "#fbfaf5", pageBottom: "#f3ecd9",
        card: "#fffdf6", sidebar: "#f6f1e2",
        darkInk: "#e8d9b7", darkInk2: "#b5ac92", darkInk3: "#6c6757",
        darkTop: "#1b1a17", darkBottom: "#14130f", darkCard: "#26241e",
        urgent: "#b5483a", soon: "#c49860", notice: "#395d7a", calm: "#4f7b61",
        subjects: ["chinese": "#b5483a", "math": "#a36b3c", "ela": "#c49860", "chem": "#395d7a",
                   "phys": "#4a6371", "bio": "#4f7b61", "geo": "#6e7984", "ids": "#b58a3c",
                   "history": "#8a6d52", "politics": "#9a4044"])

    /* ---- 月圆 MoonFestOS ----
       围绕中秋：月华、桂影、夜色、灯笼、月饼。

       深浅两套是**两个不同的场景**，不是同一套色换个明暗：
         浅色 → 「月华」：月光洒在米白玉色上，暖金为骨、夜色只留一丝底韵。
                界面要长时间读，底色必须是亮的，所以浅色这边画的是
                「月光的颜色」，不是「夜色」。
         深色 → 「中秋月夜」：深靛蓝夜空、月轮、星子、远山剪影，金桂点缀。
                这一套才是节日的正脸。

       色源都是中秋意象色，不是随手调的：
         月华金 #c2882a   中秋圆月的暖金
         灯笼红 #c4453a   宫灯 / 烛火
         夜靛蓝 #4f6b95   中秋夜的天空
         桂叶绿 #6f8f68   金桂的叶
         月饼焦糖 #a9743f 烤色饼皮
         玉兔白  #fffdf8  熟宣一样的月白
       accent 用月华金，是因为它在这个主题里同时承担「月色」和「节日」两个含义。 */
    static let moonfest = Palette(
        id: "moonfest", name: "月圆", en: "LunaOS",
        tagline: "桂影 · 月华 · 中秋夜色",
        intro: "一轮满月升上来的时候，整块界面就换成了中秋的颜色。\n"
             + "深色是「中秋月夜」：深靛蓝的天、右上一轮带晕的满月、几点星子、"
             + "远处山脊与屋檐的剪影，云气与孔明灯缓缓地走；浅色是「月华」："
             + "月光晒过的米白玉色，暖金为骨。十科配色也换成了中秋色系 ——"
             + "灯笼红、夜靛蓝、月华金、桂叶绿、月饼焦糖。\n"
             + "月、云、星、灯、桂、玉兔都是画出来的、都能点能拖；"
             + "它们铺在所有卡片底下，所以不挡任何按钮。",
        photos: [],
        drawn: "midautumn",
        forcesDark: true,
        accent: "#c2882a", accentInk: "#8a5a12",
        ink: "#231b11", ink2: "#6c5b43", ink3: "#9b8a6f",
        pageTop: "#fdfaf1", pageBottom: "#f1e5cb",
        card: "#fffdf8", sidebar: "#f9f2e0",
        darkInk: "#f4ead3", darkInk2: "#c0b39a", darkInk3: "#867c66",
        darkTop: "#161d33", darkBottom: "#0a0d1a", darkCard: "#1e2542",
        urgent: "#c4453a", soon: "#c2882a", notice: "#5f7fae", calm: "#6f8f68",
        subjects: ["chinese": "#b4453c", "math": "#4f6b95", "ela": "#c2972f", "chem": "#7d6ba0",
                   "phys": "#5c7f9e", "bio": "#6f8f68", "geo": "#6b7a86", "ids": "#a9743f",
                   "history": "#8a6a4e", "politics": "#9a4048"])

    /// 可选主题列表。
    ///
    /// 会按当前日期过滤 —— 见过往的 `all` 是一个 `let`，节日主题一写进去就
    /// 永远挂在设置页里。做成计算属性之后，「什么时候能选到」这件事只由
    /// 一处决定，设置页 / 引导页 / 菜单栏面板三处列表自动一致。
    static var all: [Palette] {
        var out: [Palette] = [standard, xuanzhi, emberglow, verdant]
        if MoonFest.available { out.append(moonfest) }
        return out
    }

    /// 按 id 取调色板。
    ///
    /// 拿不到就退回经典 —— 这一层是**兜底**，专门对付「settings.json 里
    /// 留着一个月圆，但现在已经过了那几天」这种状态：即便配置文件没被改写，
    /// 界面也绝不会渲染出一个不该出现的主题。
    static func by(_ id: String) -> Palette {
        all.first { $0.id == id } ?? standard
    }
}

/// 当前生效的调色板。
///
/// `BoardSettings` 一换主题就写这里，全局静态读取 —— 这样上百个 view 不必
/// 层层透传 palette，同时换主题立刻作用于整个 App（大看板 + 小看板）。
enum ThemeRuntime {
    nonisolated(unsafe) private(set) static var palette: Palette = Palettes.standard
    nonisolated(unsafe) private(set) static var limited: Bool = false

    static func activate(_ p: Palette) {
        palette = p
        limited = p.isLimited
    }
}

enum Theme {
    private static var p: Palette { ThemeRuntime.palette }

    static var accentDefault: RGB { RGB(p.accent) }
    static var accentInk: RGB { RGB(p.accentInk) }
    static var redDefault: RGB { RGB(p.urgent) }
    static var amberDefault: RGB { RGB(p.soon) }
    static var greenDefault: RGB { RGB(p.calm) }
    static var blueDefault: RGB { RGB(p.notice) }

    /* 中性色阶：浅色以墨色为字、深色以提亮的暖白为字，两端同源 */
    static func ink(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? RGB(p.darkInk).color : RGB(p.ink).color
    }
    static func ink2(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? RGB(p.darkInk2).color : RGB(p.ink2).color
    }
    static func ink3(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? RGB(p.darkInk3).color : RGB(p.ink3).color
    }

    /// 强调色当文字用（对比度比 accent 高，浅色下也读得清）
    static func accentText(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? RGB(p.accent).color(scheme, lift: 0.30) : RGB(p.accentInk).color
    }

    static func line(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? RGB(p.darkInk).color.opacity(0.13) : RGB(p.ink).color.opacity(0.10)
    }
    static func lineSoft(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? RGB(p.darkInk).color.opacity(0.08) : RGB(p.ink).color.opacity(0.06)
    }

    /* 页面底色：双色渐变，避免大平面死板（① 空间 + ② 色彩） */
    static func pageTop(_ scheme: ColorScheme) -> Color {
        (scheme == .dark ? RGB(p.darkTop) : RGB(p.pageTop)).color
    }
    static func pageBottom(_ scheme: ColorScheme) -> Color {
        (scheme == .dark ? RGB(p.darkBottom) : RGB(p.pageBottom)).color
    }

    static func page(_ scheme: ColorScheme) -> LinearGradient {
        LinearGradient(colors: [pageTop(scheme), pageBottom(scheme)],
                       startPoint: .top, endPoint: .bottom)
    }

    /// 侧边栏底色（实色兜底时用）
    static func sidebarFill(_ scheme: ColorScheme) -> Color {
        (scheme == .dark ? RGB(p.darkCard) : RGB(p.sidebar))
            .color(scheme, opacity: scheme == .dark ? 0.55 : 0.72)
    }

    /// 卡片底色（实色兜底 / 玻璃下面那层主题色）
    static func cardFill(_ scheme: ColorScheme, strength: Double) -> Color {
        let s = min(1, max(0, strength))
        if scheme == .dark {
            return RGB(p.darkCard).color(scheme, opacity: 0.97 - 0.30 * s)
        }
        return RGB(p.card).color(scheme, opacity: 0.97 - 0.46 * s)
    }
}

/* ---------- ③ 卡片与组件形态 ---------- */

enum Radius {
    static let sm: CGFloat = 11
    static let md: CGFloat = 16
    static let lg: CGFloat = 22
    static let xl: CGFloat = 28

    /// 按设置里的「圆角档位」缩放
    static func of(_ base: CGFloat, _ style: CornerStyle) -> CGFloat { base * style.factor }
}

/* ---------- ④ 排版体系 ---------- */

enum Typo {
    static let display  = Font.system(size: 34, weight: .bold, design: .rounded)
    static let title    = Font.system(size: 25, weight: .bold)
    static let headline = Font.system(size: 17, weight: .semibold)
    static let body     = Font.system(size: 15)
    static let callout  = Font.system(size: 13.5)
    static let sub      = Font.system(size: 12.5)
    static let caption  = Font.system(size: 11.5, weight: .medium)
    static let micro    = Font.system(size: 10.5, weight: .medium)

    /// 数字统一等宽，列与列之间才对得齐
    static func num(_ size: CGFloat, _ weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight, design: .rounded).monospacedDigit()
    }
}

/* ---------- ⑤ 动效与交互 ----------
   全应用只允许从这里取动画，视图里不写裸的 .spring() / .easeInOut()。
   理由有两个：
     ① 手感统一 —— 同一个动作在任何页面上的时长、回弹、曲线都一致；
     ② 一处可关 —— 「减弱动态效果」能真正一次性关掉所有动画。
        （以前设置里那个开关只存不用，勾了完全没反应，这一版接上了。）

   分两层：底层是「时长/弹性」配方，上层是语义 token（select / hover / reveal…）。
   写视图时优先用语义 token，只有确实需要特别节奏时才退回配方。
   ========================================================================== */

enum Motion {

    /* ---------------- 全局开关 ---------------- */

    /// 设置里「减弱动态效果」的运行时镜像。
    /// BoardSettings 一改动就调 setReduceFlag(_:)，两个 App 进程各自同步。
    nonisolated(unsafe) private static var settingReduced = false

    static func setReduceFlag(_ on: Bool) { settingReduced = on }

    /// 系统「减弱动态效果」或设置里的开关，任一为真就关掉全部动画
    static var reduced: Bool {
        settingReduced || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    /* ---------------- 动效档位（用户可切） ----------------
       三档 —— 节奏感不一样，但**形状**都一样（不引入新动画曲线，
       只是把同一条 spring 拉长 / 拉短）。这样用户切档时不会"界面手感
       突然变成另一种 App"。

         · normal   出厂节奏 —— 跟手、干脆，0.30s 上下。
         · breathe  呼吸感 —— 1.55× 时长、阻尼更接近 1，"每一个动画都在缓慢地
                     吸气、缓缓地吐气"，适合长时间阅读、写东西、需要安静的时段。
                     默认推荐。
         · vivid    弹性更明显 —— 0.85× 时长、阻尼压到 0.78，"咣当"一下更弹，
                     适合演示、专注点击操作。

       reduced = true 时三档**完全相同**（全部 nil）—— 无障碍优先。 */
    enum MotionStyle: String, CaseIterable, Codable {
        case normal, breathe, vivid
        var label: String {
            switch self {
            case .normal:  return "标准"
            case .breathe: return "呼吸"
            case .vivid:   return "鲜活"
            }
        }
        var detail: String {
            switch self {
            case .normal:  return "干净利落，跟手"
            case .breathe: return "缓慢、克制，留白感"
            case .vivid:   return "弹性更明显，更跳"
            }
        }
        var icon: String {
            switch self {
            case .normal:  return "waveform"
            case .breathe: return "leaf"
            case .vivid:   return "sparkles"
            }
        }
        /// 时长倍率（response / duration）
        var timeScale: Double {
            switch self {
            case .normal:  return 1.0
            case .breathe: return 1.55
            case .vivid:   return 0.85
            }
        }
        /// 阻尼越接近 1 越"稳而不晃"，越小越"咣咣弹"
        var dampingScale: Double {
            switch self {
            case .normal:  return 1.0
            case .breathe: return 1.05
            case .vivid:   return 0.86
            }
        }
        /// stagger 步长倍率（breathe 错峰更缓）
        var staggerScale: Double {
            switch self {
            case .normal:  return 1.0
            case .breathe: return 1.45
            case .vivid:   return 0.72
            }
        }
    }

    nonisolated(unsafe) private static var styleRaw: String = MotionStyle.breathe.rawValue
    nonisolated(unsafe) private static var style: MotionStyle = .breathe

    static func setStyle(_ s: MotionStyle) {
        styleRaw = s.rawValue
        style = s
    }
    static var motionStyle: MotionStyle { style }

    /* ---------------- ① 时长配方 ----------------
       越「重」的东西 response 越长：小图标 0.10s，整页切换 0.40s。
       集中在这里是为了让「重」有一致的判断标准，不靠手感随手写。 */

    enum Dur {
        static let instant: Double = 0.10   // 颜色、透明度这类无形变的变化
        static let quick:   Double = 0.18   // 悬停、按压
        static let base:    Double = 0.28   // 尺寸、位置
        static let slow:    Double = 0.40   // 整页、整块
    }

    /* ---------------- ② 弹性配方 ----------------
       所有 spring 都乘以 style.timeScale（响应更长），阻尼乘以
       style.dampingScale 并封顶到 0.98 —— 越接近 1 越"稳而不晃"。 */

    static func spring(_ d: Double = 0.30) -> Animation? {
        if reduced { return nil }
        return .spring(response: d * style.timeScale,
                       dampingFraction: min(0.98, 0.82 * style.dampingScale))
    }

    /// 干脆利落、带一点点过冲 —— 用在选中、切换这种「有结论」的动作上
    static func snappy(_ d: Double = 0.22) -> Animation? {
        if reduced { return nil }
        return .snappy(duration: d * style.timeScale,
                       extraBounce: 0.04 * (style == .vivid ? 1.6 : 1.0))
    }

    /// 纯缓出，没有回弹 —— 用在悬停、透明度这种不该有惯性的地方
    static func ease(_ d: Double = 0.20) -> Animation? {
        reduced ? nil : .easeOut(duration: d * style.timeScale)
    }

    /// 明显回弹 —— 只用在「新增 / 出现」这种值得庆祝的瞬间，用多了很廉价
    static func bouncy(_ d: Double = 0.38) -> Animation? {
        if reduced { return nil }
        return .spring(response: d * style.timeScale,
                       dampingFraction: min(0.92, 0.62 * style.dampingScale))
    }

    /// 分区进场错峰（stagger）用的延迟 —— 跟着 style 拉长
    static func stagger(_ index: Int, _ step: Double = 0.035) -> Double {
        reduced ? 0 : Double(index) * step * style.staggerScale
    }

    /* ---------------- ③ 语义 token（视图里优先用这些） ---------------- */

    /// 选中态：侧边栏高亮块、分段控件胶囊在选项之间滑过去。
    /// 阻尼给到 0.86 —— 要有"吸附"感但不能弹，弹了就像廉价游戏 UI。
    static var select: Animation? {
        if reduced { return nil }
        return .spring(response: 0.32 * style.timeScale,
                       dampingFraction: min(0.98, 0.86 * style.dampingScale))
    }

    /// 悬停：只有 0.16s 的缓出。悬停要"跟手"，加了弹簧反而显得拖沓。
    static var hover: Animation? { reduced ? nil : .easeOut(duration: 0.16 * style.timeScale) }

    /// 按压：下去要快、回来要有回弹，这才像真的按到了东西
    static var press: Animation? {
        if reduced { return nil }
        return .spring(response: 0.22 * style.timeScale,
                       dampingFraction: min(0.95, 0.70 * style.dampingScale))
    }

    /// 展开 / 折叠：先快后缓，尾巴收得干净
    static var reveal: Animation? {
        if reduced { return nil }
        return .spring(response: 0.34 * style.timeScale,
                       dampingFraction: min(0.98, 0.90 * style.dampingScale))
    }

    /// 整页切换（换分区、引导翻页）
    static var page: Animation? {
        if reduced { return nil }
        return .spring(response: 0.42 * style.timeScale,
                       dampingFraction: min(0.98, 0.92 * style.dampingScale))
    }

    /// 数值滚动
    static var numeric: Animation? {
        reduced ? nil : .snappy(duration: 0.30 * style.timeScale,
                                extraBounce: 0.04 * (style == .vivid ? 1.6 : 1.0))
    }

    /// 状态点呼吸、进行中脉冲（无限循环，所以必须能被 reduced 关掉）
    /// breathe 档下周期放长 —— "真的在呼吸"，不是"闪烁"。
    static var pulse: Animation? {
        reduced ? nil : .easeInOut(duration: style == .breathe ? 2.6
                                            : (style == .vivid ? 1.1 : 1.5))
    }

    /// 弹出物：菜单、确认条、提示气泡
    static var pop: Animation? {
        if reduced { return nil }
        return .spring(response: 0.30 * style.timeScale,
                       dampingFraction: min(0.95, 0.74 * style.dampingScale))
    }
}

/* ---------- 过渡：方向感知的位移 + 淡入 ----------
   SwiftUI 自带的 .move(edge:) 会把视图**整幅**从屏幕外推进来 —— 内容区有
   1100pt 宽，用它是"咣当"一下，很吵。这里改成固定像素的小位移 + 淡入 + 极轻微
   缩放：看得见"从哪边来"，但不会晃眼睛。 */

struct SlideFade: ViewModifier {
    var dx: CGFloat = 0
    var dy: CGFloat = 0
    var opacity: Double = 1
    var scale: CGFloat = 1

    func body(content: Content) -> some View {
        content
            .offset(x: dx, y: dy)
            .scaleEffect(scale, anchor: .top)
            .opacity(opacity)
    }
}

extension AnyTransition {

    /// 换分区：新的从前进方向滑进来，旧的往后退方向滑出去，两边都淡。
    /// `forward` 决定方向 —— 「下一页」和「上一页」的手感必须是反的，
    /// 不然用户分不清自己到底往前还是往后走了。
    static func pageSlide(_ forward: Bool) -> AnyTransition {
        let d: CGFloat = forward ? 30 : -30
        return .asymmetric(
            insertion: .modifier(
                active: SlideFade(dx: d, opacity: 0, scale: 0.988),
                identity: SlideFade(dx: 0, opacity: 1, scale: 1)),
            removal: .modifier(
                active: SlideFade(dx: -d * 0.65, opacity: 0, scale: 0.994),
                identity: SlideFade(dx: 0, opacity: 1, scale: 1)))
    }

    /// 展开 / 折叠一块内容：从上方 6pt 处落下并放大一点点，
    /// 比裸 .move(edge: .top) 少了那种"整块被抽出来"的突兀感。
    static var reveal: AnyTransition {
        .asymmetric(
            insertion: .modifier(
                active: SlideFade(dy: -7, opacity: 0, scale: 0.97),
                identity: SlideFade(dy: 0, opacity: 1, scale: 1)),
            removal: .modifier(
                active: SlideFade(dy: -4, opacity: 0, scale: 0.99),
                identity: SlideFade(dy: 0, opacity: 1, scale: 1)))
    }

    /// 弹出：小一点、快一点，像从触发它的控件里长出来
    static var pop: AnyTransition {
        .asymmetric(
            insertion: .modifier(
                active: SlideFade(dy: 6, opacity: 0, scale: 0.94),
                identity: SlideFade(dy: 0, opacity: 1, scale: 1)),
            removal: .opacity)
    }
}

/* ---------- ⑥ 图标语义（两端用同一套名字，Windows 端映射成内联 SVG） ---------- */

enum Icons {
    static let todo     = "checklist"
    static let classes  = "calendar"
    static let grades   = "chart.bar.fill"
    /// 灵析 AI：用四角星，跟「最新出分」那个 sparkles 区分开
    static let ai       = "sparkles.rectangle.stack.fill"
    static let settings = "gearshape.fill"
    static let refresh  = "arrow.clockwise"
    static let user     = "person.crop.circle"
    static let logout   = "rectangle.portrait.and.arrow.right"
    static let quit     = "xmark"
    static let warn     = "exclamationmark.triangle.fill"
    static let clock    = "clock.fill"
    static let room     = "mappin.and.ellipse"
    static let teacher  = "person.fill"
    static let open     = "arrow.up.forward.square"
    static let star     = "star.fill"
    static let gauge    = "gauge.with.dots.needle.67percent"
    static let palette  = "paintpalette.fill"
    static let eye      = "eye.fill"
    static let bolt     = "bolt.fill"
    static let search   = "magnifyingglass"
    // Teams 用「三个人」而不是原来的「对话气泡 + 对勾」：
    // 那个图标渲染出来是个方块里一个白勾，看着像复选框，跟「Teams 里的新任务」
    // 完全对不上（引导页通知列表里尤其扎眼 —— 一列彩色图标中间夹一个勾选框）。
    // person.3 和 English Corner 的 person.2 是同一个语族，一眼能区分开。
    static let teams    = "person.3.fill"
    /// 删除 / 找回（逾期作业的两次确认删除 + 设置里的恢复）
    static let trash    = "trash"
    static let undo     = "arrow.uturn.backward"
}

/* ---------- ⑦ 玻璃 / 卡片表面 ---------- */

/// 渲染自检开关（命令行 --render 用；正常运行时全是 false）
enum PreviewFlags {
    static var flat = false
    static var noScroll = false
    static var fullHeight = false
    static var nowOverride: Date? = nil
    static var section: String = ""
    static var search: String = ""      // 离屏渲染时预填搜索框，用来核对搜索效果
    /// 离屏渲染时只画设置页的某一组（空 = 全部）。用来量各组的最小宽度。
    static var group: String = ""
    /// 只画设置页本身（不套 DashRoot），看页面自己会不会超宽
    static var solo = false
    /// 离屏渲染面板时把「快速设置」展开（真机默认是收起的）
    static var quick = false
    /// 离屏渲染设置页时去掉「量宽度」用的绿底红框（做对比图/交付图时用）
    static var clean = false
    /// 离屏渲染引导页时直接跳到第几步（nil = 用真机默认的第一屏）
    static var onboardStep: Int? = nil
    /// 离屏渲染中。ImageRenderer 画不了 NSViewRepresentable（WKWebView），
    /// 会画成一张黄底红圈「禁止」占位图，而且**盖在所有内容上面** ——
    /// 于是整屏只剩那块占位。所以走离屏时干脆不挂网页引擎。
    static var offscreen = false
    /// 离屏渲染灵析 AI 时假装已登录（真机上登录态来自网页里的 token，离屏拿不到）。
    /// 只看布局用，不参与任何真实逻辑。
    static var aiAuthed = false
    /// 离屏渲染时直接展开某个学科的柱状图（值 = 学科 key，如 "chemistry"）。
    /// 真机上这一层要点一下学科行才弹出来，离屏没法点 —— 只能开个后门。
    static var chartKey: String? = nil
    /// 离屏自检时把「今天」挪到某一天，用来核对按日期分档的表现。
    /// 和 `nowOverride` 同一性质：正常运行全程为 nil，界面上没有任何入口能写它。
    static var dateOverride: Date? = nil
    /// 离屏自检时直接展开 Teams 任务预览（值 = 第几条）。真机要点一下才出来，离屏没法点。
    static var previewIndex: Int? = nil
    /// 离屏自检时直接展开任务详情单（值 = 第几条）。同上。
    static var detailIndex: Int? = nil
    /// 真运行时核验（--live）专用：让浮层小窗自己来回荡。
    /// 「拖动时渐暗跟着走」这条只能靠真拖才知道，而无头环境注入不了指点事件
    /// —— 于是让 offset 自己动起来，逐帧比对就能证明渐变中心是跟帧走的。
    static var autoDrag = false
    /// 离屏自检时按住上线提示弹窗，不让它出现。
    /// 档期内**每次启动都会弹**（用户要求），所以自检要拍「不被遮住的全页图」
    /// 就只能靠这个开关。
    static var hideMoonNotice = false
    /// `--drag x,y`：给浮层小窗钉一个固定位移（离屏几何核验用，见 FloatingChrome）
    static var dragTo: CGSize? = nil
    /// `--still`：把底纹的动画冻结在第一帧。
    ///
    /// 做「某个东西的位置对不对」这类几何核验时，必须把动的部分按住 ——
    /// 云在飘、灯在升、花瓣在落，两张分别渲染的图逐像素一减，
    /// 差异里九成是动画噪声，真正要看的那个位移反而淹在里面。
    static var still = false
}

/// 玻璃强度 → 材质的落点。设置里可调，真实影响观感。
struct GlassLook {
    var strength: Double = 1.0          // 0…1
    var reduceTransparency: Bool = false

    /// 用实色兜底（开了「降低透明度」或把强度拉到 0）
    var useFallback: Bool { reduceTransparency || strength <= 0.02 }

    /// 磨砂厚度：强度越高越接近常规玻璃，越低越通透 —— 这条真实参与渲染
    var variant: Glass { strength >= 0.62 ? .regular : .clear }

    /// 卡片底下那层主题色的不透明度：强度越高越让位给玻璃
    var washOpacity: Double { min(1, max(0, strength)) }
}

/// 统一的「卡面」：主题底 + 一层液态玻璃 + hairline 描边 + 双层柔和阴影
///
/// 这里刻意把结构写成 `content.background { 主题底 + 玻璃 }`，**不是** ZStack：
/// ① 顺序必须固定 —— 内容在最上、玻璃在底，反了玻璃就会盖住内容（见下）；
/// ② 尺寸必须由内容决定 —— ZStack 里那个无限弹性的 shape 会被父级拉长（见下）。
/// 强度 `s` 同时控制玻璃层的透明度与主题底的不透明度，所以滑块从 0 拉到 1 一定看得见变化。
///
/// ⚠️ 两个已经踩过的坑，改这个结构前务必读：
/// - **不要**在卡面外包 `GlassEffectContainer`。容器会把一组卡片的玻璃合并成单独
///   一层并合成到内容之上，结果是卡片里的文字全部变成「透过磨砂玻璃看」——发糊。
///   （真机截图验证：容器内 .card() 行糊、容器外 .card() 行清晰。）
/// - **不要**改回 ZStack 把底和内容并排。ZStack 取最大子视图，而 shape 是无限弹性的，
///   父级有多少余量它就要多少，会把 28pt 的按钮撑成几百 pt 的空盒子。
struct CardSurface<S: InsettableShape>: ViewModifier {
    @Environment(\.colorScheme) private var scheme
    let shape: S
    var tint: Color? = nil
    var look: GlassLook = GlassLook()
    /// 是否叠一层柔和投影（列表里成片的行不要投影，会脏）
    var shadow: Bool = true
    var lineWidth: CGFloat = 0.8

    private var glassOn: Bool { !(PreviewFlags.flat || look.useFallback) }

    private var strokeGradient: LinearGradient {
        LinearGradient(
            colors: scheme == .dark
                ? [Color.white.opacity(0.16), Color.white.opacity(0.04)]
                : [Color.white.opacity(0.92), Color.black.opacity(0.07)],
            startPoint: .top, endPoint: .bottom)
    }

    func body(content: Content) -> some View {
        let s = look.strength
        // ⚠️ 卡面必须用 .background / .overlay，**不能**用 ZStack 把底和内容并排。
        //
        // ZStack 的尺寸是「子视图里最大的那个」，而底下的 shape 是无限弹性的：
        // 父级给多少高度它就要多少。结果就是——只要父级 VStack 有多余高度，
        // 它就会被 VStack 分配给这张卡（而不是分配给 Spacer），
        // 于是一颗 28pt 高的按钮、一条 40pt 高的预览条，会被撑成几百 pt 高的空盒子。
        // （真机上「实时预览」变成一张巨大空卡、侧边栏刷新按钮变成大方块，
        //   都是这一处造成的。离屏渲染量不出来，因为自检模式没走 ScrollView。）
        //
        // .background 的背景会被提议「内容自己的尺寸」，shape 就正好铺满内容，
        // 卡片尺寸恒等于内容尺寸，再也不会被拉长。
        content
            .background {
                ZStack {
                    // ① 主题底：强度越低越实，越高越透明（让玻璃露出来）
                    shape.fill(Theme.cardFill(scheme, strength: s))

                    // ② 玻璃：强度 0 时不画，中间档走更通透的 clear，高档才是常规磨砂
                    if glassOn {
                        Rectangle()
                            .fill(Color.clear)
                            .glassEffect(tint.map { look.variant.tint($0) } ?? look.variant, in: shape)
                            .opacity(0.30 + 0.70 * s)
                    }
                }
            }
            // ③ 描边
            .overlay {
                shape.strokeBorder(strokeGradient, lineWidth: lineWidth)
                    .allowsHitTesting(false)
            }
            .compositingGroup()
            .shadow(color: .black.opacity(shadow ? (scheme == .dark ? 0.34 : 0.11) * max(0.30, s) : 0),
                    radius: shadow ? 12 : 0, x: 0, y: shadow ? 5 : 0)
            .shadow(color: .black.opacity(shadow ? (scheme == .dark ? 0.22 : 0.05) : 0),
                    radius: shadow ? 2 : 0, x: 0, y: shadow ? 1 : 0)
    }
}

extension View {
    /// 卡面：形状 + 可选玻璃着色 + 玻璃强度
    func card<S: InsettableShape>(_ shape: S, tint: Color? = nil, look: GlassLook = GlassLook(), shadow: Bool = true) -> some View {
        modifier(CardSurface(shape: shape, tint: tint, look: look, shadow: shadow))
    }

    /// 圆角矩形卡面（最常用）
    func card(_ radius: CGFloat, tint: Color? = nil, look: GlassLook = GlassLook(), shadow: Bool = true) -> some View {
        card(RoundedRectangle(cornerRadius: radius, style: .continuous),
             tint: tint, look: look, shadow: shadow)
    }

    /// 整块内容区（无阴影，纯玻璃底）
    func glassPane(_ radius: CGFloat) -> some View {
        modifier(CardSurface(shape: RoundedRectangle(cornerRadius: radius, style: .continuous),
                             tint: nil, look: GlassLook(), shadow: false))
    }
}

/* ---------- ⑧ 无障碍：焦点环 ---------- */

struct FocusRing<S: InsettableShape>: ViewModifier {
    @Environment(\.colorScheme) private var scheme
    let shape: S
    var active: Bool

    func body(content: Content) -> some View {
        content.overlay(
            shape.strokeBorder(active ? Theme.accentDefault.color(scheme, lift: 0.16) : .clear,
                               lineWidth: 2.5)
        )
    }
}

extension View {
    func focusRing<S: InsettableShape>(_ shape: S, active: Bool) -> some View {
        modifier(FocusRing(shape: shape, active: active))
    }
}

/* ---------- 小节标题 ---------- */

/// 根据英文 title 推断印文（壹/贰/叁/肆/伍/陆/柒/捌）。没有合适的英文 → 用「今」。
/// 用户可以在调用处用 `seal:` 显式覆盖。
private func autoSeal(for title: String) -> String {
    let map: [String: String] = [
        "Todo": "壹", "Teams": "贰", "Classes": "叁", "Grades": "肆",
        "Settings": "伍", "Theme": "陆", "Profile": "柒", "Appearance": "捌",
        "Notifications": "玖", "Refresh": "拾",
        "Quick Settings": "雅", "Today": "今", "Overview": "阅",
    ]
    if let m = map[title] { return m }
    // 关键字匹配（标题里包含关键词就用对应印文）
    for (k, v) in map {
        if title.contains(k) { return v }
    }
    return "今"
}

struct SectionHeader: View {
    let title: String
    var subtitle: String = ""
    var icon: String? = nil
    /// 印文 —— 默认根据标题自动挑一个字；显式传 nil 则不画印。
    var seal: String? = "__auto__"
    /// 自定义印的大小（默认 14）。设为 0 关闭印章。
    var sealSize: CGFloat = 14

    @Environment(\.colorScheme) private var scheme

    private var env: Env {
        // 这里只用到 scheme；设置由各页面的 EnvironmentObject 注入，所以这里取自
        // settings 这一环境变量——但 SectionHeader 在很多地方是被 Theme.ink
        // 静态取的，所以这里只读 scheme。accent 由 ThemeRuntime 静态提供。
        Env(scheme: scheme,
            settings: BoardSettings.shared)
    }

    private var resolvedSeal: String? {
        if seal == "__auto__" { return autoSeal(for: title) }
        return seal
    }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            // 朱砂短竖线 —— 印章感
            CinnabarTick(height: 17, width: 1.6, env: env)

            // 可选小印
            if let s = resolvedSeal, sealSize > 0 {
                InkSeal(char: s, size: sealSize, env: env)
                    .accessibilityHidden(true)
            } else if let icon {
                // 不用印时回退到 SF Symbol
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.accentDefault.color(.light))
                    .accessibilityHidden(true)
            }

            Text(title)
                .font(Typo.title)
                .foregroundStyle(Theme.ink(scheme))
                // 上沿一抹极淡墨晕 —— 让"标题"看着像写在纸上的字
                .shadow(color: .black.opacity(scheme == .dark ? 0.0 : 0.06),
                        radius: 0.5, x: 0, y: 0.5)

            Spacer(minLength: 8)

            if !subtitle.isEmpty {
                Text(subtitle)
                    .font(Typo.callout)
                    .foregroundStyle(.tertiary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

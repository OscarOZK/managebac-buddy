import SwiftUI
import AppKit

/* ======================================================================
   ④ 设置页

   布局次序（按用户指定的优先级）：
     ① 实时预览 —— 细长一条，始终钉在设置页最上方（由 DashRoot 渲染，不随滚动）
     ② 主题     —— 最显眼的第一排，限时主题在这里换
     ③ 使用者 · 外观 · 配色 · 通知 · 刷新 · 待办 · 跳转 · 小看板 · 作息 · 希悦 · 快捷键 · 配置文件
   每一项都立刻写回 ~/.mbboard/settings.json 并驱动界面 —— 没有摆设。
   ====================================================================== */

struct SettingsSection: View {
    @EnvironmentObject var settings: BoardSettings
    @Environment(\.colorScheme) private var scheme
    /// 「已删除的作业」列表 —— 订阅单例，删/恢复后这一组立刻重画
    @ObservedObject private var deleted = DeletedTasks.shared
    /// 「全部恢复」要二次确认：一次把几十条全放回列表，误触代价大
    @State private var confirmRestoreAll = false

    private var env: Env { Env(scheme: scheme, settings: settings) }

    var body: some View {
        // LazyVStack 而不是 VStack：设置页 13 个组、每张组卡都带玻璃+双层阴影，
        // 全量渲染时整页 6000px 高，滚动每帧都在合成屏幕外的模糊 —— 这就是
        // 「设置页上下滚动非常卡」的根因。懒加载后只渲染屏内的组，滚动立刻顺滑。
        LazyVStack(alignment: .leading, spacing: settings.density.sectionGap) {
            // PreviewFlags.group 只在离屏自检时非空：用来单独量某一组的最小宽度，
            // 正常运行时恒为空，等于全部渲染。
            if on("theme")    { themeGroup }
            // 账号管理紧跟「主题」—— 四个账号（ManageBac / Teams / 希悦 / DeepSeek）
            // 统一在这里登录，用户想「看看哪个掉了」不用来回翻页面。
            if on("accounts") { accountsGroup }
            if on("profile") { profileGroup }
            if on("appear")  { appearanceGroup }
            if on("color")   { colorGroup }
            if on("notify")  { notifyGroup }
            if on("refresh") { refreshGroup }
            if on("todo")    { todoGroup }
            if on("deleted") { deletedGroup }
            if on("link")    { linkGroup }
            if on("panel")   { panelGroup }
            if on("life")    { lifeGroup }
            if on("seiue")   { seiueGroup }
            if on("keys")    { shortcutGroup }
            if on("reset")   { resetGroup }
        }
    }

    private func on(_ id: String) -> Bool {
        PreviewFlags.group.isEmpty || PreviewFlags.group == id
    }

    /* ================================================================
       ② 主题 —— 设置页第一排
       ================================================================ */

    private var themeGroup: some View {
        VStack(alignment: .leading, spacing: env.space(13)) {
            HStack(alignment: .firstTextBaseline, spacing: 9) {
                Image(systemName: Icons.palette)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(env.accent.color(scheme, lift: 0.12))
                Text("主题").font(.system(size: 20, weight: .bold))
                    .foregroundStyle(Theme.ink(scheme))
                Spacer(minLength: 8)
                Text("配色整体替换，大小看板一起变")
                    .font(.system(size: 11.5)).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 2)

            VStack(spacing: env.space(11)) {
                ForEach(Palettes.all) { p in
                    PaletteCard(env: env, palette: p,
                              // 比的是**实际生效**的那个 id，不是配置里存的那个。
                              // 节令主题过了档期，`settings.palette` 已经退回经典，
                              // 而配置文件里可能还留着旧值 —— 若比 `paletteID`，
                              // 卡片会一张都不亮，看着像「主题没了」。
                              active: settings.palette.id == p.id,
                              apply: {
                                  withAnimation(Motion.spring(0.4)) { settings.paletteID = p.id }
                              })
                }
            }

            // `hasBackdrop` 而不是 `isLimited`：月圆没有实拍原图（整幅月夜是
            // 用代码画的），但它**必须**能开关底纹 —— 不然用户嫌月色太抢眼时
            // 就没有退路了。
            if settings.palette.hasBackdrop {
                SettingToggleRow(env: env,
                                 title: "主题氛围底纹",
                                 detail: settings.palette.drawn != nil
                                     ? "背景里的月色、星子、远山与飘落的金桂。关掉就只留配色"
                                     : "把该主题的校园实拍糊成一层极淡的底，氛围更足；关掉则只用采样出来的色",
                                 on: $settings.themeBackdrop)
                .card(env.radius(Radius.md), look: env.look)
            }
        }
        .appearIn(0)
    }

    /* ================================================================
       ⓪b 账号管理 —— 紧跟主题
       ================================================================ */

    private var accountsGroup: some View {
        AccountsGroup()
    }

    /* ================================================================
       ⓪ 使用者
       ================================================================ */

    private var profileGroup: some View {
        SettingGroup(env: env, title: "使用者", icon: Icons.user,
                     note: "English Corner 名单按英语名匹配，务必填真实英语名") {
            SettingFieldRow(env: env, title: "英语名",
                            detail: "例如 Alex Chen —— 大小写不敏感，写全名更准",
                            text: $settings.englishName,
                            placeholder: "First Last")
            rowLine
            SettingFieldRow(env: env, title: "怎么称呼你",
                            detail: "界面上打招呼用；留空就用英语名的名",
                            text: $settings.displayName,
                            placeholder: settings.hasProfile ? "可选" : "可选")
            rowLine
            SettingFieldRow(env: env, title: "年级",
                            detail: "影响课表与成绩的显示口径",
                            text: $settings.gradeLabel,
                            placeholder: "G10")
            rowLine
            HStack(spacing: env.space(12)) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("重新走一遍新手引导")
                        .font(.system(size: 13.5, weight: .medium))
                        .foregroundStyle(Theme.ink(scheme))
                    Text("保留已填的档案，只是再过一遍连接与主题的流程")
                        .font(.system(size: 11.5)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: env.space(10))
                Button {
                    withAnimation(Motion.spring(0.36)) { settings.onboarded = false }
                } label: {
                    Text("开始引导")
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(env.accent.color(scheme, lift: 0.06))
                        .padding(.horizontal, 14).frame(height: 28)
                        .contentShape(RoundedRectangle(cornerRadius: env.radius(Radius.sm), style: .continuous))
                }
                .buttonStyle(.plain)
                .card(env.radius(Radius.sm),
                      tint: env.accent.color(scheme, lift: 0.86, opacity: scheme == .dark ? 0.16 : 0.12),
                      look: env.look, shadow: false)
            }
            .settingsRowPadding(env)
        }
    }

    /* ================================================================
       ① 外观
       ================================================================ */

    private var appearanceGroup: some View {
        SettingGroup(env: env, title: "外观", icon: "circle.lefthalf.filled",
                     note: "深浅色、密度、圆角、玻璃与描边") {
            SettingControlRow(env: env, title: "深浅色", detail: "跟随系统或强制指定") {
                SegmentedTabs(env: env,
                              items: ThemeMode.allCases.map {
                                  SegItem(id: $0.rawValue, label: $0.label, icon: $0.icon) },
                              selection: Binding(
                                get: { settings.theme.rawValue },
                                set: { settings.theme = ThemeMode(rawValue: $0) ?? .system }))
            }
            rowLine
            SettingControlRow(env: env, title: "密度", detail: "行高与留白的整体节奏") {
                SegmentedTabs(env: env,
                              items: Density.allCases.map { SegItem(id: $0.rawValue, label: $0.label) },
                              selection: Binding(
                                get: { settings.density.rawValue },
                                set: { settings.density = Density(rawValue: $0) ?? .comfortable }))
            }
            rowLine
            SettingControlRow(env: env, title: "圆角", detail: "卡片与控件的转角") {
                SegmentedTabs(env: env,
                              items: CornerStyle.allCases.map { SegItem(id: $0.rawValue, label: $0.label) },
                              selection: Binding(
                                get: { settings.corner.rawValue },
                                set: { settings.corner = CornerStyle(rawValue: $0) ?? .regular }))
            }
            rowLine
            SettingControlRow(env: env, title: "玻璃强度",
                              detail: "0% 是纯色卡面，100% 是最通透的液态玻璃") {
                GlassSlider(env: env, value: $settings.glassStrength,
                            range: 0...1, step: 0.05, width: 190,
                            valueLabel: { String(format: "%.0f%%", $0 * 100) })
            }
            rowLine
            /* --- 弹窗那圈液态玻璃描边的四项微调 ---
               默认值就是原来那套（7pt / 100% / 94% / 投影开），所以不改也能用，
               改了也只是让那圈玻璃更宽、更亮，或者更薄、更素。 */
            SettingControlRow(env: env, title: "弹窗描边宽度",
                              detail: "弹窗外面那圈液态玻璃铺多开。0 = 只有一道细边") {
                GlassSlider(env: env, value: $settings.glassPanelBorder,
                            range: 0...14, step: 0.5, width: 190,
                            valueLabel: { String(format: "%.1f pt", $0) })
            }
            rowLine
            SettingControlRow(env: env, title: "描边高光",
                              detail: "玻璃边缘那道白色反光的强弱，0% 是纯折射无高光") {
                GlassSlider(env: env, value: $settings.glassPanelRim,
                            range: 0...1, step: 0.05, width: 190,
                            valueLabel: { String(format: "%.0f%%", $0 * 100) })
            }
            rowLine
            SettingControlRow(env: env, title: "弹窗内圈挡色",
                              detail: "越大越不透出底下的颜色，正文越清楚") {
                GlassSlider(env: env, value: $settings.glassPanelBody,
                            range: 0.55...1, step: 0.01, width: 190,
                            valueLabel: { String(format: "%.0f%%", $0 * 100) })
            }
            rowLine
            SettingToggleRow(env: env, title: "弹窗投影",
                             detail: "弹窗底下的那层柔影。关掉更扁平，开着重心更稳",
                             on: $settings.glassPanelShadow)
            rowLine
            /* --- 浮窗拖拽 ---
               「最上边那一部分」= 面板顶边往下 46pt 的一条带（见 FloatingChrome
               里的 `grabH`）。关掉这一项，顶边就不再响应拖拽，只是普通的头部。 */
            SettingToggleRow(env: env, title: "浮窗可拖动",
                             detail: "按住小窗顶边那一条可以拖到任意位置；关掉就固定居中",
                             on: $settings.panelDrag)
            rowLine
            SettingControlRow(env: env, title: "字号",
                              detail: "全局缩放，不影响布局结构") {
                GlassSlider(env: env, value: $settings.fontScale,
                            range: 0.85...1.25, step: 0.05, width: 190,
                            valueLabel: { String(format: "%.0f%%", $0 * 100) })
            }
            rowLine
            SettingToggleRow(env: env, title: "降低透明度",
                             detail: "玻璃退化为实色，屏幕上字更清楚（系统开启该项时自动等效）",
                             on: $settings.reduceTransparency)
            rowLine
            SettingControlRow(env: env, title: "动效档位",
                              detail: "呼吸感更适合长时间阅读；鲜活弹性更强、更跳") {
                MotionStylePicker(env: env, value: $settings.motionStyle)
            }
            rowLine
            SettingToggleRow(env: env, title: "减弱动态效果",
                             detail: "关掉进场、悬停与数值滚动动画",
                             on: $settings.reduceMotion)
            rowLine
            SettingToggleRow(env: env, title: "水墨印章",
                             detail: "标题与侧栏旁的朱砂小印（雅、壹、贰、叁…）。默认关，想要雅趣再开",
                             on: $settings.showSeals)
        }
    }

    /* ================================================================
       ② 配色 —— 强调色 + 学科配色（扩充版：每一科都能单独改）
       ================================================================ */

    private var colorGroup: some View {
        SettingGroup(env: env, title: "配色", icon: "drop.fill",
                     note: "换主题会一并替换，之后仍可单独微调") {
            /* ① 强调色 ----------------------------------------------------
               原来这块是「标题行右边孤零零挂一个取色圆点、圆点行左边挤一堆
               色板」，中间一大片空白，看着散。现在收成标准的一行：
               左边标签，右边「色板 + 回到主题色 + 自定义取色」。 */
            SettingControlRow(env: env, title: "强调色",
                              detail: settings.palette.isLimited
                                  ? "当前跟随主题·\(settings.palette.name)" : "") {
                HStack(spacing: env.space(9)) {
                    ForEach(AccentPreset.all) { ap in
                        AccentSwatch(env: env, preset: ap,
                                     active: settings.accentHex.lowercased() == ap.hex.lowercased()) {
                            withAnimation(Motion.snappy(0.2)) { settings.accentHex = ap.hex }
                        }
                    }
                    // 直接取自当前主题的强调色，方便一键回到主题色
                    if settings.palette.isLimited {
                        Button {
                            withAnimation(Motion.snappy(0.2)) { settings.accentHex = settings.palette.accent }
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: "arrow.uturn.backward")
                                    .font(.system(size: 9.5, weight: .bold))
                                Text("回到主题色").font(.system(size: 11, weight: .semibold))
                            }
                            .foregroundStyle(env.accent.color(scheme, lift: 0.08))
                            .padding(.horizontal, 9).frame(height: 24)
                            .contentShape(Capsule())
                            .background(Capsule().fill(env.accent.color(scheme).opacity(0.12)))
                        }
                        .buttonStyle(.plain)
                    }

                    Rectangle().fill(Theme.line(scheme)).frame(width: 1, height: 18)

                    // 自定义取色：带个「自定义」小字，免得那个圆点看着像孤零零的装饰
                    Text("自定义").font(.system(size: 11)).foregroundStyle(.tertiary)
                    ColorSwatch(env: env, hex: settings.accentHex,
                                width: 30, height: 22, corner: 6) { h in
                        withAnimation(Motion.snappy(0.2)) { settings.accentHex = h }
                    }
                }
            }

            rowLine

            /* ② 学科配色方案 ------------------------------------------------
               三张等宽卡，每张把十科色做成一条铺满整卡的色带 ——
               色带自己撑满宽度，卡里就不会再留一大片空白。 */
            VStack(alignment: .leading, spacing: env.space(10)) {
                HStack(spacing: 8) {
                    Text("学科配色方案").font(.system(size: 13.5, weight: .medium))
                        .foregroundStyle(Theme.ink(scheme))
                    Spacer(minLength: 8)
                    Text("整套换掉十个学科的颜色").font(.system(size: 11)).foregroundStyle(.tertiary)
                }
                HStack(spacing: env.space(10)) {
                    ForEach(SubjectPreset.all) { sp in
                        let on = settings.subjectPresetID == sp.id
                        Button {
                            withAnimation(Motion.snappy(0.22)) { settings.applySubjectPreset(sp.id) }
                        } label: {
                            VStack(alignment: .leading, spacing: 8) {
                                // 八段等宽色带：铺满卡片，一眼看出整套配色
                                HStack(spacing: 3) {
                                    ForEach(Subject.keys, id: \.self) { k in
                                        Capsule()
                                            .fill(RGB(sp.colors[k] ?? "#888888")
                                                .color(scheme, lift: on ? 0.12 : 0.04))
                                            .frame(maxWidth: .infinity)
                                            .frame(height: 16)
                                    }
                                }
                                HStack(spacing: 6) {
                                    Text(sp.name)
                                        .font(.system(size: 12, weight: on ? .semibold : .medium))
                                        .foregroundStyle(on ? Theme.ink(scheme) : Color.secondary)
                                    Spacer(minLength: 0)
                                    if on {
                                        Image(systemName: "checkmark.circle.fill")
                                            .font(.system(size: 11))
                                            .foregroundStyle(env.accent.color(scheme, lift: 0.08))
                                    }
                                }
                            }
                            .padding(.horizontal, env.space(12))
                            .padding(.vertical, env.space(11))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(RoundedRectangle(cornerRadius: env.radius(Radius.sm), style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .card(env.radius(Radius.sm),
                              tint: on ? env.accent.color(scheme, lift: 0.88,
                                                          opacity: scheme == .dark ? 0.20 : 0.14) : nil,
                              look: env.look, shadow: false)
                    }
                }
            }
            .settingsRowPadding(env)

            rowLine

            /* ③ 单科微调 ----------------------------------------------------
               自适应网格：窗口宽时八个一排，窄了自动折成四列 / 两列。
               比写死四列强 —— 写死四列在宽窗上每格 230pt，色块和图标中间
               空出一大段，看着就是散的。 */
            VStack(alignment: .leading, spacing: env.space(10)) {
                HStack(spacing: 8) {
                    Text("单科颜色").font(.system(size: 13.5, weight: .medium))
                        .foregroundStyle(Theme.ink(scheme))
                    Spacer(minLength: 8)
                    Text("点色块可精确取色").font(.system(size: 11)).foregroundStyle(.tertiary)
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 108, maximum: 200),
                                             spacing: env.space(9))],
                          spacing: env.space(9)) {
                    ForEach(Subject.keys, id: \.self) { k in
                        let c = Subject.rgb(k, settings)
                        HStack(spacing: 8) {
                            ColorSwatch(env: env, hex: c.hex, width: 24, height: 18, corner: 5) { h in
                                withAnimation(Motion.snappy(0.2)) { settings.subjectColors[k] = h }
                            }
                            Text(Subject.cnLabels[k] ?? k)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(Theme.ink(scheme))
                                .lineLimit(1)
                                .fixedSize(horizontal: true, vertical: false)
                            Image(systemName: Subject.symbol(k))
                                .font(.system(size: 10.5))
                                .foregroundStyle(c.color(scheme, lift: 0.13))
                                .fixedSize()
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, env.space(9))
                        .frame(height: 32)
                        .background {
                            RoundedRectangle(cornerRadius: env.radius(8), style: .continuous)
                                .fill(c.color(scheme, lift: 0.88, opacity: scheme == .dark ? 0.16 : 0.10))
                        }
                    }
                }
            }
            .settingsRowPadding(env)
        }
    }

    /* ================================================================
       ⑥ 通知
       ================================================================ */

    private var notifyGroup: some View {
        SettingGroup(env: env, title: "通知", icon: "bell.badge.fill",
                     note: "提醒什么、什么时候提醒，完全由你定") {
            SettingToggleRow(env: env, title: "开启通知",
                             detail: "总开关。关掉之后下面的细分项都不生效",
                             on: $settings.notifyEnabled)
            if settings.notifyEnabled {
                rowLine
                SettingToggleRow(env: env, title: "待办到期提醒",
                                 detail: "快到期 / 已逾期的任务推一条",
                                 on: $settings.notifyTask)
                if settings.notifyTask {
                    SettingToggleRow(env: env, title: "只提醒「紧急」档",
                                     detail: "打开后黄、蓝档不打扰你",
                                     on: $settings.notifyTaskRedOnly)
                    rowLine
                    SettingControlRow(env: env, title: "提前提醒",
                                      detail: "在截止前多久推送") {
                        GlassSlider(env: env, value: $settings.notifyLeadHours,
                                    range: 0.5...24, step: 0.5, width: 170,
                                    valueLabel: { String(format: "%.1f 小时", $0) })
                    }
                }

                rowLine
                SettingToggleRow(env: env, title: "每日汇总",
                                 detail: "每天固定时间推一条「今天有什么」",
                                 on: $settings.notifyDigest)
                if settings.notifyDigest {
                    SettingControlRow(env: env, title: "汇总时间", detail: "") {
                        timeMenu($settings.notifyDigestAt)
                    }
                }

                hintRow("按来源")

                SettingToggleRow(env: env, title: "Teams 学习待办",
                                 detail: "作业、测验、会议从 Teams 挑出来时提醒",
                                 on: $settings.notifyTeams)
                rowLine
                SettingToggleRow(env: env, title: "邮件",
                                 detail: "有新的重要邮件时提醒（默认关，避免刷屏）",
                                 on: $settings.notifyMail)
                rowLine
                SettingToggleRow(env: env, title: "日程 / 课程",
                                 detail: "下一节课或日程开始前提醒",
                                 on: $settings.notifyEvents)
                rowLine
                SettingToggleRow(env: env, title: "新成绩",
                                 detail: "老师评完分就提醒",
                                 on: $settings.notifyGrades)
                rowLine
                SettingToggleRow(env: env, title: "English Corner",
                                 detail: "名单里有你时提醒",
                                 on: $settings.notifyEC)
                if settings.notifyEC {
                    SettingControlRow(env: env, title: "EC 提前量",
                                      detail: "EC 开始前多久提醒") {
                        GlassSlider(env: env, value: $settings.notifyECLead,
                                    range: 5...120, step: 5, width: 170,
                                    valueLabel: { String(format: "%.0f 分钟", $0) })
                    }
                }

                rowLine
                // 分学科过滤
                VStack(alignment: .leading, spacing: env.space(9)) {
                    HStack {
                        Text("只通知这些学科").font(.system(size: 13.5, weight: .medium))
                            .foregroundStyle(Theme.ink(scheme))
                        Spacer(minLength: 8)
                        Text(settings.notifySubjects.isEmpty
                             ? "全部学科" : "已选 \(settings.notifySubjects.count) 科")
                            .font(.system(size: 11)).foregroundStyle(.tertiary)
                    }
                    // ⚠️ 这里以前是一条 HStack，一行排完所有学科。
                    // 学科从 8 个扩到 10 个（加了历史、政治）之后，最后两个直接
                    // 溢出到卡片外面去了 —— 用户截图指出的就是这处。
                    // 换成 FlowRow：装不下就换行，加多少科都不会溢出。
                    FlowRow(spacing: env.space(7), lineSpacing: env.space(7)) {
                        ForEach(Subject.keys, id: \.self) { k in
                            let on = settings.notifySubjects.contains(k)
                            Button {
                                withAnimation(Motion.select) {
                                    if on { settings.notifySubjects.removeAll { $0 == k } }
                                    else { settings.notifySubjects.append(k) }
                                }
                            } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: Subject.symbol(k))
                                        .font(.system(size: 9.5, weight: .semibold))
                                    Text(Subject.cnLabels[k] ?? k)
                                        .font(.system(size: 11.5, weight: on ? .semibold : .medium))
                                }
                                .foregroundStyle(on ? .white : Theme.ink2(scheme))
                                .padding(.horizontal, 9).frame(height: 25)
                                .contentShape(Capsule())
                                .background {
                                    Capsule().fill(on
                                        ? Subject.rgb(k, settings).color(scheme, lift: 0.05)
                                        : Color.primary.opacity(scheme == .dark ? 0.12 : 0.07))
                                }
                            }
                            .buttonStyle(.plain)
                            .help(on ? "点一下不再通知这一科" : "点一下只通知这一科")
                        }
                    }
                }
                .settingsRowPadding(env)

                rowLine
                SettingToggleRow(env: env, title: "通知上显示学科图标",
                                 detail: "十科不同颜色与符号，右下角小圆再标事项种类",
                                 on: $settings.notifySubjectIcon)
                rowLine
                SettingToggleRow(env: env, title: "提示音",
                                 detail: "关掉则静默推送",
                                 on: $settings.notifySound)

                hintRow("免打扰")

                SettingToggleRow(env: env, title: "开启免打扰时段",
                                 detail: "这段时间内不推送任何通知",
                                 on: $settings.notifyQuietOn)
                if settings.notifyQuietOn {
                    HStack(spacing: env.space(10)) {
                        Text("从").font(.system(size: 12.5)).foregroundStyle(.secondary)
                        timeMenu($settings.notifyQuietFrom)
                        Text("到").font(.system(size: 12.5)).foregroundStyle(.secondary)
                        timeMenu($settings.notifyQuietTo)
                        Spacer(minLength: 0)
                    }
                    .settingsRowPadding(env)
                }

                rowLine
                HStack(spacing: env.space(12)) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("通知中心打扫").font(.system(size: 13.5, weight: .medium))
                            .foregroundStyle(Theme.ink(scheme))
                        Text("超过 36 小时的通知会自动摘掉，最多留 24 条；想立刻清空就按右边")
                            .font(.system(size: 11.5)).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    Button {
                        Notifier.clearDelivered()
                    } label: {
                        Text("清空已投递通知")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Theme.ink(scheme))
                            .padding(.horizontal, 12).frame(height: 26)
                            .contentShape(RoundedRectangle(cornerRadius: env.radius(8), style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .card(env.radius(Radius.sm), look: env.look, shadow: false)
                }
                .settingsRowPadding(env)

                rowLine
                HStack(spacing: env.space(12)) {
                    Text("系统权限").font(.system(size: 13.5, weight: .medium))
                        .foregroundStyle(Theme.ink(scheme))
                    Spacer(minLength: 8)
                    Button {
                        Notifier.openSystemSettings()
                    } label: {
                        Text("打开系统通知设置")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Theme.ink(scheme))
                            .padding(.horizontal, 12).frame(height: 26)
                            .contentShape(RoundedRectangle(cornerRadius: env.radius(8), style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .card(env.radius(Radius.sm), look: env.look, shadow: false)
                }
                .settingsRowPadding(env)

                rowLine
                NotifyTroubleCard()
                    .settingsRowPadding(env)
            }
        }
    }

    /* ================================================================
       ④⑨ 刷新
       ================================================================ */

    private var refreshGroup: some View {
        SettingGroup(env: env, title: "刷新", icon: Icons.refresh,
                     note: "数据时效性由这里决定") {
            SettingControlRow(env: env, title: "主体刷新间隔",
                              detail: "作业、成绩、课表 —— 抓一次要开浏览器，间隔太短会拖慢机器") {
                GlassSlider(env: env, value: $settings.refreshMinutes,
                            range: 1...30, step: 1, width: 180,
                            valueLabel: { String(format: "%.0f 分钟", $0) })
            }
            rowLine
            SettingControlRow(env: env, title: "详情预取间隔",
                              detail: "提前把作业详情和附件取下来，点开就能秒看") {
                SegmentedTabs(env: env,
                              items: PrefetchInterval.allCases.map {
                                  SegItem(id: $0.rawValue, label: $0.label) },
                              selection: Binding(
                                get: { "\(Int(settings.prefetchMinutes))" },
                                set: { settings.prefetchMinutes = Double($0) ?? 30 }))
            }
            rowLine
            SettingControlRow(env: env, title: "Teams 刷新间隔",
                              detail: "调快一点也不会被限流，放心调") {
                GlassSlider(env: env, value: $settings.refreshTeamsSec,
                            range: 30...300, step: 15, width: 180,
                            valueLabel: { String(format: "%.0f 秒", $0) })
            }
            rowLine
            SettingToggleRow(env: env, title: "仅在看板可见时刷新",
                             detail: "窗口不在最前时暂停读取，省电",
                             on: $settings.refreshWhenVisibleOnly)
            rowLine
            SettingToggleRow(env: env, title: "开机自动启动",
                             detail: "登录时自动挂上菜单栏图标",
                             on: Binding(
                                get: { settings.launchAtLogin },
                                set: { settings.launchAtLogin = $0; LaunchAtLogin.set($0) }))
            rowLine
            HStack(spacing: env.space(12)) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("立即刷新一次").font(.system(size: 13.5, weight: .medium))
                        .foregroundStyle(Theme.ink(scheme))
                    // store.subtitle 本身就是「更新于 23:02」这种完整句子，
                    // 前面再拼「上次更新」会变成「上次更新 更新于 23:02」
                    Text(store.busy ? "正在抓取…" : store.subtitle)
                        .font(.system(size: 11.5)).foregroundStyle(.secondary)
                }
                Spacer(minLength: env.space(10))
                Button {
                    Task { await store.load(force: true); await store.loadTeams() }
                } label: {
                    HStack(spacing: 5) {
                        SpinIcon(spinning: store.busy)
                        Text(store.busy ? "抓取中…" : "刷新数据")
                            .font(.system(size: 12.5, weight: .semibold))
                    }
                    .foregroundStyle(Theme.ink(scheme))
                    .padding(.horizontal, 14).frame(height: 28)
                    .contentShape(RoundedRectangle(cornerRadius: env.radius(Radius.sm), style: .continuous))
                }
                .buttonStyle(.plain)
                .card(env.radius(Radius.sm), look: env.look, shadow: false)
            }
            .settingsRowPadding(env)
        }
    }

    /* ================================================================
       ③ 待办
       ================================================================ */

    private var todoGroup: some View {
        SettingGroup(env: env, title: "待办", icon: Icons.todo,
                     note: "紧急度分档与过滤") {
            SettingControlRow(env: env, title: "「紧急」阈值",
                              detail: "剩余时间少于这个数就算紧急") {
                GlassSlider(env: env, value: $settings.urgentHours,
                            range: 2...96, step: 1,
                            color: Theme.redDefault, width: 170,
                            valueLabel: { String(format: "%.0f 小时", $0) })
            }
            rowLine
            SettingControlRow(env: env, title: "「临近」阈值",
                              detail: "必须大于紧急阈值") {
                GlassSlider(env: env, value: $settings.soonHours,
                            range: 3...200, step: 1,
                            color: Theme.amberDefault, width: 170,
                            valueLabel: { String(format: "%.0f 小时", $0) })
            }
            rowLine
            SettingControlRow(env: env, title: "「留意」阈值",
                              detail: "必须大于临近阈值") {
                // 三条滑块的轨道配色 = 卡片上三档标签的配色，不用对照也能认出谁是谁
                GlassSlider(env: env, value: $settings.blueHours,
                            range: 4...400, step: 1, width: 170,
                            valueLabel: { String(format: "%.0f 小时", $0) })
            }
            rowLine
            SettingToggleRow(env: env, title: "逾期项计入紧凑计数",
                             detail: "关掉则菜单栏上的数字不含已逾期",
                             on: $settings.countOverdue)
            rowLine
            VStack(alignment: .leading, spacing: env.space(9)) {
                HStack {
                    Text("隐藏这些关键词").font(.system(size: 13.5, weight: .medium))
                        .foregroundStyle(Theme.ink(scheme))
                    Spacer(minLength: 8)
                    Text("逗号或换行分隔").font(.system(size: 11)).foregroundStyle(.tertiary)
                }
                // ⚠️ TextEditor 底层是 NSTextView，ImageRenderer 画不出来 ——
                //    整块会被一张「黄底红圈禁止符」占位图盖住，于是这一行在
                //    离屏自检图里永远是个黑洞：周围的间距、圆角、配色对不对，
                //    自检时根本看不见。（TextField / SecureField 是原生绘制的，
                //    不受影响 —— 别顺手把它们也改了。）
                //    自检时换成等高的静态文本，真机仍然是可编辑的输入框。
                Group {
                    if PreviewFlags.offscreen {
                        Text(settings.hiddenKeywords.isEmpty
                             ? "（还没有隐藏任何关键词）" : settings.hiddenKeywords)
                            .font(.system(size: 12.5))
                            .foregroundStyle(settings.hiddenKeywords.isEmpty
                                             ? Color.secondary.opacity(0.7) : Theme.ink(scheme))
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                    } else {
                        TextEditor(text: $settings.hiddenKeywords)
                            .font(.system(size: 12.5))
                            .scrollContentBackground(.hidden)
                    }
                }
                .frame(height: 54)
                .padding(7)
                .background {
                    RoundedRectangle(cornerRadius: env.radius(8), style: .continuous)
                        .fill(Color.primary.opacity(scheme == .dark ? 0.10 : 0.05))
                }
            }
            .settingsRowPadding(env)
            rowLine
            SettingControlRow(env: env, title: "每页最多显示",
                              detail: "0 表示不限") {
                GlassSlider(env: env, value: $settings.taskLimit,
                            range: 0...200, step: 5, width: 180,
                            valueLabel: { $0 < 0.5 ? "不限" : String(format: "%.0f 条", $0) })
            }
        }
    }

    /* ================================================================
       ⑥b 已删除的作业（逾期作业的两步删除，在这里找回）
       ================================================================ */

    private var deletedGroup: some View {
        SettingGroup(env: env, title: "已删除的作业", icon: Icons.trash,
                     note: deleted.count == 0 ? "目前没有删除记录"
                                              : "\(deleted.count) 条 · 随时可以恢复") {
            if deleted.list.isEmpty {
                HStack(spacing: env.space(10)) {
                    Image(systemName: "checkmark.circle")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Theme.greenDefault.color(scheme, lift: 0.14))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("没有删掉任何作业")
                            .font(.system(size: 13.5, weight: .medium))
                            .foregroundStyle(Theme.ink(scheme))
                        Text("在待办页的逾期卡片上点「删除」（两次确认）后，被删掉的那条会出现在这里。")
                            .font(.system(size: 11.5))
                            .foregroundStyle(.tertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }
                .settingsRowPadding(env)
            } else {
                SettingControlRow(env: env, title: "全部恢复",
                                  detail: "把下面这些一次性放回待办／逾期列表") {
                    Button {
                        confirmRestoreAll = true
                    } label: {
                        Label("全部恢复", systemImage: Icons.undo)
                            .font(.system(size: 11.5, weight: .semibold))
                            .padding(.horizontal, 13)
                            .frame(height: 27)
                            .background(Capsule().fill(env.accent.color(scheme, lift: 0.86, opacity: 0.16)))
                            .foregroundStyle(env.accent.color(scheme, lift: 0.06))
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .alert("恢复全部 \(deleted.count) 条？", isPresented: $confirmRestoreAll) {
                        Button("取消", role: .cancel) { }
                        Button("恢复全部") { DeletedTasks.shared.restoreAll() }
                    } message: {
                        Text("它们会重新出现在待办和逾期列表里。")
                    }
                }

                ForEach(deleted.list) { d in
                    rowLine
                    deletedRow(d)
                }
            }
        }
    }

    /// 一条删除记录：标题 + 学科／截止 + 删除时间 + 恢复按钮
    private func deletedRow(_ d: DeletedTask) -> some View {
        HStack(spacing: env.space(12)) {
            VStack(alignment: .leading, spacing: 3) {
                Text(d.title)
                    .font(.system(size: 13.5, weight: .medium))
                    .foregroundStyle(Theme.ink(scheme))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 6) {
                    if !d.subject.isEmpty {
                        Text(d.subject)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    if let due = d.due {
                        Text("· 截止 \(shortDueDate(due))")
                            .font(Typo.num(11, .regular))
                            .foregroundStyle(.tertiary)
                    }
                    Text("· \(deletedAtText(d.deletedAt))")
                        .font(Typo.num(11, .regular))
                        .foregroundStyle(Theme.redDefault.color(scheme, lift: 0.16))
                }
            }
            Spacer(minLength: env.space(10))
            Button {
                DeletedTasks.shared.restore(id: d.id)
            } label: {
                Label("恢复", systemImage: Icons.undo)
                    .font(.system(size: 11.5, weight: .semibold))
                    .padding(.horizontal, 12)
                    .frame(height: 26)
                    .background(Capsule().fill(Color.primary.opacity(scheme == .dark ? 0.10 : 0.06)))
                    .foregroundStyle(Theme.ink2(scheme))
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .help("把「\(d.title)」放回待办列表")
        }
        .settingsRowPadding(env)
    }

    /* ================================================================
       ⑦ 打开链接的方式
       ================================================================ */

    private var linkGroup: some View {
        SettingGroup(env: env, title: "打开链接", icon: Icons.open,
                     note: "App 里所有跳网页的地方都按这里走") {
            SettingToggleRow(env: env, title: "一律用内置浏览窗",
                             detail: "不管下面怎么设，所有链接都在看板内的小窗打开，不切应用",
                             on: $settings.linkAllBuiltin)
            rowLine
            SettingControlRow(env: env, title: "默认方式",
                              detail: "点任务、成绩、邮件里的链接时") {
                SegmentedTabs(env: env,
                              items: LinkMode.allCases.map {
                                  SegItem(id: $0.rawValue, label: $0.label, icon: $0.icon) },
                              selection: $settings.linkTarget)
            }
            rowLine
            hintRow("按来源单独覆盖（留空则跟随默认）")
            ForEach(LinkSource.all, id: \.id) { s in
                HStack(spacing: env.space(12)) {
                    HStack(spacing: 8) {
                        Image(systemName: s.icon).font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(env.accent.color(scheme, lift: 0.12))
                            .frame(width: 18)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(s.label).font(.system(size: 13.5, weight: .medium))
                                .foregroundStyle(Theme.ink(scheme))
                            Text(s.sample).font(.system(size: 11)).foregroundStyle(.tertiary)
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: env.space(10))
                    Group {
                        // 离屏自检画不了 Menu（.borderlessButton → NSPopUpButton），
                        // 会留一张黄底占位符。这五行在自检图里原本完全看不见，
                        // 对齐/间距对不对无从核对。自检时换成同一张「面」的静态版。
                        if PreviewFlags.offscreen {
                            linkOverrideFace(s.id)
                        } else {
                            Menu {
                                Button("跟随默认（\(LinkMode(rawValue: settings.linkTarget)?.label ?? "系统浏览器")）") {
                                    settings.linkOverrides.removeValue(forKey: s.id)
                                }
                                Divider()
                                ForEach(LinkMode.allCases) { t in
                                    Button {
                                        settings.linkOverrides[s.id] = t.rawValue
                                    } label: { Label(t.label, systemImage: t.icon) }
                                }
                            } label: {
                                linkOverrideFace(s.id)
                            }
                            .menuStyle(.borderlessButton)
                            .menuIndicator(.hidden)
                        }
                    }
                    .fixedSize()
                    .card(env.radius(Radius.sm), look: env.look, shadow: false)
                }
                .settingsRowPadding(env)
                if s.id != LinkSource.all.last?.id { rowLine }
            }
        }
    }

    private func overrideLabel(_ id: String) -> String {
        guard let v = settings.linkOverrides[id], let t = LinkMode(rawValue: v) else {
            return "跟随默认"
        }
        return t.label
    }

    /* ================================================================
       ⑧ 小看板（菜单栏面板）自定义
       ================================================================ */

    private var panelGroup: some View {
        SettingGroup(env: env, title: "小看板", icon: "menubar.rectangle",
                     note: "显示什么、多大、用什么主题") {
            hintRow("主题")
            // 第 18 轮：主看板与菜单栏面板合并成一个 App / 一个进程，
            // 全局色板只能有一套，「小看板独立主题」这条分支整组去掉了。
            SettingNoteRow(env: env, text: "看板与菜单栏面板已合并为一个 App，共用同一套主题与配色。面板里调主题/主题色，改的就是看板这套。")
            rowLine
            hintRow("显示哪些区块")
            SettingToggleRow(env: env, title: "大计时", detail: "距离下课/晚自习的倒计时",
                             on: $settings.panelShowTimer)
            rowLine
            SettingToggleRow(env: env, title: "学习待办", detail: "今天与即将到期的事项",
                             on: $settings.panelShowTodo)
            rowLine
            SettingToggleRow(env: env, title: "接下来的课", detail: "今天剩下的课程",
                             on: $settings.panelShowClass)
            rowLine
            SettingToggleRow(env: env, title: "最新成绩", detail: "最近评完分的作业",
                             on: $settings.panelShowScore)
            rowLine
            SettingToggleRow(env: env, title: "English Corner", detail: "今天要不要去 EC",
                             on: $settings.panelShowEC)
            rowLine
            SettingToggleRow(env: env, title: "快速设置", detail: "面板里直接切主题、密度、玻璃",
                             on: $settings.panelShowQuick)
            if settings.panelShowQuick {
                SettingToggleRow(env: env, title: "快速设置默认展开",
                                 detail: "默认收起，点标题才展开（推荐）",
                                 on: $settings.panelQuickOpen)
            }

            rowLine
            hintRow("尺寸与行数")
            SettingControlRow(env: env, title: "面板宽度", detail: "") {
                GlassSlider(env: env, value: $settings.panelWidth,
                            range: 380...640, step: 10, width: 180,
                            valueLabel: { String(format: "%.0f pt", $0) })
            }
            rowLine
            SettingControlRow(env: env, title: "面板高度", detail: "") {
                GlassSlider(env: env, value: $settings.panelHeight,
                            range: 420...900, step: 20, width: 180,
                            valueLabel: { String(format: "%.0f pt", $0) })
            }
            rowLine
            SettingControlRow(env: env, title: "待办显示条数",
                              detail: "收起状态下显示几行") {
                GlassSlider(env: env, value: $settings.panelTodoRows,
                            range: 2...12, step: 1, width: 180,
                            valueLabel: { String(format: "%.0f 条", $0) })
            }
            rowLine
            SettingControlRow(env: env, title: "成绩每行几个",
                              detail: "一行放几张小卡") {
                SegmentedTabs(env: env,
                              items: [3, 4, 5, 6].map { SegItem(id: "\($0)", label: "\($0)") },
                              selection: Binding(
                                get: { "\(Int(settings.panelScoreCols))" },
                                set: { settings.panelScoreCols = Double(Int($0) ?? 4) }))
            }
            rowLine
            SettingToggleRow(env: env, title: "隐藏「已逾期」区块",
                             detail: "不想被翻旧账时打开",
                             on: $settings.panelHideOverdue)
        }
    }

    /* ================================================================
       ⑤ 作息
       ================================================================ */

    private var lifeGroup: some View {
        SettingGroup(env: env, title: "作息", icon: Icons.clock,
                     note: "影响计时器对「上课 / 休息 / 晚自习」的判断") {
            SettingControlRow(env: env, title: "起床时间", detail: "早于这个时间不计入课程安排") {
                timeMenu($settings.wakeTime)
            }
            rowLine
            SettingControlRow(env: env, title: "晚自习开始", detail: "") {
                timeMenu($settings.nightStart)
            }
            rowLine
            SettingControlRow(env: env, title: "晚自习结束", detail: "") {
                timeMenu($settings.nightEnd)
            }
            rowLine
            SettingControlRow(env: env, title: "打开看板时停在哪一页",
                              detail: "平时切页不会把它改掉，只有这里改") {
                SegmentedTabs(env: env,
                              items: DashSection.allCases.map { SegItem(id: $0.rawValue, label: $0.title) },
                              selection: $settings.dashboardSection)
            }
            rowLine
            SettingToggleRow(env: env, title: "显示底部提示",
                             detail: "看板侧边栏底部的更新时间等提示",
                             on: $settings.showFooterHints)
        }
    }

    /* ================================================================
       ⑩ 希悦
       ================================================================ */

    private var seiueGroup: some View {
        SettingGroup(env: env, title: "希悦课表", icon: "calendar.badge.clock",
                     note: "yly.seiue.com · 一周同步一次即可") {
            SettingToggleRow(env: env, title: "启用希悦",
                             detail: "用希悦的课表补充 ManageBac，课名更直观",
                             on: $settings.seiueEnabled)
            if settings.seiueEnabled {
                rowLine
                SettingFieldRow(env: env, title: "希悦账号",
                                detail: "邮箱或手机号",
                                text: $settings.seiueAccount,
                                placeholder: "学号 / 邮箱 / 手机号")
                rowLine
                SettingToggleRow(env: env, title: "用希悦课表覆盖课程页",
                                 detail: "关掉则只作为备用来源",
                                 on: $settings.seiueForSchedule)
                rowLine
                SettingControlRow(env: env, title: "同步周期", detail: "课表变动不频繁") {
                    GlassSlider(env: env, value: $settings.seiueRefreshDays,
                                range: 1...30, step: 1, width: 170,
                                valueLabel: { String(format: "%.0f 天", $0) })
                }
                rowLine
                HStack(spacing: env.space(12)) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("同步希悦课表").font(.system(size: 13.5, weight: .medium))
                            .foregroundStyle(Theme.ink(scheme))
                        Text(seiueStatusLine)
                            .font(.system(size: 11.5)).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: env.space(10))
                    Button {
                        Task { await runSeiueSync() }
                    } label: {
                        HStack(spacing: 5) {
                            if seiueBusy {
                                ProgressView().controlSize(.mini).scaleEffect(0.7)
                            } else {
                                Image(systemName: "arrow.triangle.2.circlepath")
                                    .font(.system(size: 10.5, weight: .semibold))
                            }
                            Text("立即同步").font(.system(size: 12.5, weight: .semibold))
                        }
                        .foregroundStyle(Theme.ink(scheme))
                        .padding(.horizontal, 14).frame(height: 28)
                        .contentShape(RoundedRectangle(cornerRadius: env.radius(Radius.sm), style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .card(env.radius(Radius.sm), look: env.look, shadow: false)
                }
                .settingsRowPadding(env)
                rowLine
                SettingFieldRow(env: env, title: "希悦密码（仅本机钥匙串）",
                                detail: "密码不会被写进配置文件，只交给系统钥匙串",
                                text: $seiuePassword,
                                placeholder: "••••••••",
                                secure: true)
            }
        }
    }

    private var seiueStatusLine: String {
        if settings.seiueLastSync <= 0 { return "还没同步过" }
        let d = Date(timeIntervalSince1970: settings.seiueLastSync)
        let f = DateFormatter()
        f.dateFormat = "M月d日 HH:mm"
        return "上次同步 \(f.string(from: d))"
    }

    /* ================================================================
       ⑪ 快捷键
       ================================================================ */

    private var shortcutGroup: some View {
        SettingGroup(env: env, title: "快捷键", icon: "command",
                     note: "点一下再按组合键即可改；按 ⌫ 清除绑定") {
            // 重复绑定检测：同一个组合键挂了两个动作时，只有先注册的那个会生效，
            // 用户会以为「这个键坏了」。与其让人猜，不如直接指出来。
            if !conflictingKeys.isEmpty {
                HStack(spacing: 7) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.amberDefault.color(scheme, lift: 0.10))
                    Text("有 \(conflictingKeys.count) 个组合键被绑了多次（\(conflictingKeys.joined(separator: "、"))），只有第一个会生效")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.ink2(scheme))
                    Spacer(minLength: 0)
                }
                .settingsRowPadding(env)
                rowLine
            }

            ShortcutRow(env: env, title: "立即刷新数据", binding: $settings.keyRefresh)
            rowLine
            ShortcutRow(env: env, title: "搜索", detail: "打开看板时聚焦搜索框",
                        binding: $settings.keySearch)
            rowLine
            ShortcutRow(env: env, title: "下一页 / 上一页", binding: $settings.keyNextSection,
                        second: $settings.keyPrevSection)

            rowLine
            // ↓ 用户要求：一个键直接跳到对应板块，不用按「下一页」翻过去
            HStack {
                Text("跳到板块")
                    .font(.system(size: 13.5, weight: .medium))
                    .foregroundStyle(Theme.ink(scheme))
                Spacer(minLength: env.space(10))
                Text("按下即切到那一页")
                    .font(.system(size: 11.5)).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, env.space(Space.md))
            .padding(.top, env.space(10))

            // 五个键排一行，窗口窄了自动换行成两行 —— 硬塞一行会被切掉右边。
            // 「设置」不在这里：它已经有 ⌘, 这个系统级约定键，不占数字位。
            FlowRow(spacing: env.space(10), lineSpacing: env.space(8)) {
                jumpChip(DashSection.todo.title, DashSection.todo.icon, $settings.keySectionTodo)
                jumpChip(DashSection.teams.title, DashSection.teams.icon, $settings.keySectionTeams)
                jumpChip(DashSection.classes.title, DashSection.classes.icon, $settings.keySectionClasses)
                jumpChip(DashSection.grades.title, DashSection.grades.icon, $settings.keySectionGrades)
                jumpChip(DashSection.ai.title, DashSection.ai.icon, $settings.keySectionAI)
            }
            .settingsRowPadding(env)
            .padding(.top, env.space(9))
            .padding(.bottom, env.space(10))

            rowLine
            ShortcutRow(env: env, title: "显示 / 收起菜单栏面板", binding: $settings.keyTogglePanel)
            rowLine
            ShortcutRow(env: env, title: "深浅色切换", binding: $settings.keyToggleTheme)
            rowLine
            ShortcutRow(env: env, title: "打开设置", binding: $settings.keyOpenSettings)
        }
    }

    /// 「跳到板块」里的一个小胶囊：板块图标 + 名字 + 可录制的按键
    private func jumpChip(_ title: String, _ icon: String, _ binding: Binding<String>) -> some View {
        HStack(spacing: 7) {
            Image(systemName: icon)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(env.accent.color(scheme, lift: 0.10))
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.ink(scheme))
            ShortcutField(env: env, value: binding, width: 66)
        }
        .padding(.leading, 10)
        .padding(.trailing, 4)
        .frame(height: 34)
        .background {
            RoundedRectangle(cornerRadius: env.radius(Radius.sm), style: .continuous)
                .fill(Color.primary.opacity(scheme == .dark ? 0.07 : 0.045))
        }
    }

    /// 找出被绑了多次的组合键（空串不算）
    private var conflictingKeys: [String] {
        let all: [(String, String)] = [
            ("刷新", settings.keyRefresh), ("搜索", settings.keySearch),
            ("下一页", settings.keyNextSection), ("上一页", settings.keyPrevSection),
            ("待办", settings.keySectionTodo), ("Teams", settings.keySectionTeams),
            ("课程", settings.keySectionClasses), ("成绩", settings.keySectionGrades),
            ("灵析 AI", settings.keySectionAI),
            ("面板", settings.keyTogglePanel), ("深浅色", settings.keyToggleTheme),
            ("设置", settings.keyOpenSettings),
        ]
        var seen: [String: Int] = [:]
        for (_, raw) in all where !raw.isEmpty {
            guard let sc = Shortcut(raw) else { continue }
            seen[sc.string, default: 0] += 1
        }
        return seen.filter { $0.value > 1 }.keys
            .sorted()
            .map { Shortcut($0)?.display ?? $0 }
    }

    /* ================================================================
       配置文件
       ================================================================ */

    private var resetGroup: some View {
        SettingGroup(env: env, title: "配置文件", icon: "folder",
                     // 显示**真实**路径。以前写死「~/.mbboard/settings.json」——
                     // 分发版的数据目录根本不是那里，等于指错地方，
                     // 用户按这句话去 Finder 里找会一无所获。
                     note: "保存于 \(BoardSettings.fileURL.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))") {
            HStack(spacing: env.space(12)) {
                Button {
                    NSWorkspace.shared.selectFile(BoardSettings.fileURL.path, inFileViewerRootedAtPath: "")
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "folder").font(.system(size: 11, weight: .semibold))
                        Text("在访达中显示").font(.system(size: 12.5, weight: .semibold))
                    }
                    .foregroundStyle(Theme.ink(scheme))
                    .padding(.horizontal, 14).frame(height: 30)
                    .contentShape(RoundedRectangle(cornerRadius: env.radius(Radius.sm), style: .continuous))
                }
                .buttonStyle(.plain)
                .card(env.radius(Radius.sm), look: env.look, shadow: false)

                Button {
                    withAnimation(Motion.spring(0.34)) { settings.resetAll() }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.counterclockwise").font(.system(size: 11, weight: .semibold))
                        Text("恢复默认").font(.system(size: 12.5, weight: .semibold))
                    }
                    .foregroundStyle(Theme.redDefault.color(scheme, lift: 0.14))
                    .padding(.horizontal, 14).frame(height: 30)
                    .contentShape(RoundedRectangle(cornerRadius: env.radius(Radius.sm), style: .continuous))
                }
                .buttonStyle(.plain)
                .card(env.radius(Radius.sm),
                      tint: Theme.redDefault.color(scheme, lift: 0.86, opacity: scheme == .dark ? 0.12 : 0.09),
                      look: env.look, shadow: false)

                // 恢复新手导览：比「恢复默认」更彻底 —— 连身份档案一起清掉，
                // 直接回到第一次使用时的第一屏。（要确认，避免误触）
                Button {
                    confirmingGuideReset = true
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "sparkles").font(.system(size: 11, weight: .semibold))
                        Text("恢复新手导览").font(.system(size: 12.5, weight: .semibold))
                    }
                    .foregroundStyle(Theme.redDefault.color(scheme, lift: 0.14))
                    .padding(.horizontal, 14).frame(height: 30)
                    .contentShape(RoundedRectangle(cornerRadius: env.radius(Radius.sm), style: .continuous))
                }
                .buttonStyle(.plain)
                .card(env.radius(Radius.sm),
                      tint: Theme.redDefault.color(scheme, lift: 0.86, opacity: scheme == .dark ? 0.12 : 0.09),
                      look: env.look, shadow: false)
                .help("清空全部设置与使用者档案，重新走一遍引导")
                .alert("恢复新手导览？", isPresented: $confirmingGuideReset) {
                    Button("取消", role: .cancel) { }
                    Button("清空并重新引导", role: .destructive) {
                        withAnimation(Motion.spring(0.34)) { settings.resetForOnboarding() }
                    }
                } message: {
                    Text("会把全部设置与使用者档案（英语名、称呼、年级）恢复成第一次使用的状态，"
                         + "并立刻回到第一屏重新走一遍引导。\n"
                         + "开机自启的注册保留；下载好的 EC 名单 PDF 不会删除。")
                }

                Spacer(minLength: 0)
                Text("修改即时保存 · 要连档案一起清空，用「恢复新手导览」")
                    .font(.system(size: 11)).foregroundStyle(.tertiary)
            }
            .settingsRowPadding(env)
        }
    }

    /* ---------------- 小零件 ---------------- */

    @ObservedObject private var store = DataStore.shared
    @State private var seiuePassword = ""
    @State private var seiueBusy = false
    /// 「恢复新手导览」要二次确认：这是全量重置，误触代价大
    @State private var confirmingGuideReset = false

    private var rowLine: some View {
        Rectangle().fill(Theme.lineSoft(scheme)).frame(height: 1)
            .padding(.leading, env.space(Space.md))
    }

    private func hintRow(_ t: String) -> some View {
        HStack {
            Text(t).font(.system(size: 11, weight: .semibold))
                .foregroundStyle(env.accent.color(scheme, lift: 0.10))
                .textCase(.uppercase).tracking(0.6)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, env.space(Space.md))
        .padding(.top, env.space(11))
        .padding(.bottom, env.space(3))
    }

    private func runSeiueSync() async {
        seiueBusy = true
        defer { seiueBusy = false }
        let r = await Bridge.post("/api/seiue/sync", [
            "account": settings.seiueAccount,
            "password": seiuePassword,
        ], timeout: 120)
        if Bridge.ok(r) {
            settings.seiueLastSync = Date().timeIntervalSince1970
            await store.load(force: true)
        }
    }

    /// 时间选择：每 30 分钟一个选项
    /// 「打开方式」下拉的「面」：当前选择 + 上下箭头。
    /// 抽出来是为了让真机（Menu）和离屏自检（静态）用同一套外观。
    private func linkOverrideFace(_ id: String) -> some View {
        HStack(spacing: 5) {
            Text(overrideLabel(id))
                .font(.system(size: 11.5, weight: .medium))
            Image(systemName: "chevron.up.chevron.down")
                .font(.system(size: 8, weight: .bold))
        }
        .foregroundStyle(Theme.ink2(scheme))
        .padding(.horizontal, 10).frame(height: 26)
        .contentShape(RoundedRectangle(cornerRadius: env.radius(8), style: .continuous))
    }

    /// 时间下拉的「面」：时钟图标 + 时间 + 上下箭头。
    /// 单独抽出来是为了让真机（Menu）和离屏自检（静态文本）用**同一套**外观，
    /// 否则自检图里看到的样子和真机不是一回事，等于白测。
    private func timeLabel(_ text: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: "clock").font(.system(size: 10, weight: .semibold))
            Text(text)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .monospacedDigit()
            Image(systemName: "chevron.up.chevron.down")
                .font(.system(size: 8, weight: .bold))
        }
        .foregroundStyle(Theme.ink(scheme))
        .padding(.horizontal, 10).frame(height: 26)
        .contentShape(RoundedRectangle(cornerRadius: env.radius(8), style: .continuous))
    }

    private func timeMenu(_ binding: Binding<String>) -> some View {
        Group {
            // ⚠️ Menu 加了 .borderlessButton 之后底层是 NSPopUpButton，ImageRenderer
            //    画不出来 —— 三行作息时间在离屏自检图里一直都是「黄底红圈禁止符」，
            //    自检时完全看不到这几行。自检换成同款静态标签，真机该弹还是弹。
            if PreviewFlags.offscreen {
                timeLabel(binding.wrappedValue)
            } else {
                Menu {
                    ForEach(Self.timeOptions, id: \.self) { t in
                        Button(t) { binding.wrappedValue = t }
                    }
                } label: {
                    timeLabel(binding.wrappedValue)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
            }
        }
        .fixedSize()
        .card(env.radius(Radius.sm), look: env.look, shadow: false)
    }

    private static let timeOptions: [String] = stride(from: 0, to: 24 * 60, by: 30).map {
        String(format: "%02d:%02d", $0 / 60, $0 % 60)
    }
}

/* ======================================================================
   实时预览条
   —— 用户要求：始终在设置最上方，但占地要小，窄窄一长行。
   所以由 DashRoot 放在滚动区之外渲染，滚到哪它都在。
   ====================================================================== */

struct SettingsPreviewStrip: View {
    @EnvironmentObject var settings: BoardSettings
    @Environment(\.colorScheme) private var scheme
    @ObservedObject private var store = DataStore.shared

    private var env: Env { Env(scheme: scheme, settings: settings) }

    var body: some View {
        HStack(spacing: env.space(11)) {
            HStack(spacing: 6) {
                Image(systemName: Icons.eye).font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(env.accent.color(scheme, lift: 0.12))
                Text("实时预览").font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.ink(scheme))
                    .lineLimit(1).fixedSize(horizontal: true, vertical: false)
            }

            Rectangle().fill(Theme.line(scheme)).frame(width: 1, height: 16)

            // 一行示例：学科点 + 标题 + 紧急度 + 进度
            HStack(spacing: 7) {
                Circle().fill(Subject.rgb("chem", settings).color(scheme, lift: 0.14))
                    .frame(width: 7, height: 7)
                Text("化学").font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(Subject.rgb("chem", settings).color(scheme, lift: 0.10))
                    .lineLimit(1).fixedSize(horizontal: true, vertical: false)
                Text("实验报告 · 酸碱滴定")
                    .font(.system(size: 12)).foregroundStyle(Theme.ink(scheme)).lineLimit(1)
                Pill(env: env, text: "紧急", color: Theme.redDefault, bold: true)
                    .fixedSize(horizontal: true, vertical: false)
                Text("剩 3h12m").font(Typo.num(11, .bold))
                    .foregroundStyle(Theme.redDefault.color(scheme, lift: 0.16))
                    .lineLimit(1).fixedSize(horizontal: true, vertical: false)
            }
            .padding(.horizontal, 10).frame(height: 26)
            .background {
                RoundedRectangle(cornerRadius: env.radius(8), style: .continuous)
                    .fill(scheme == .dark ? Color.white.opacity(0.05) : Color.white.opacity(0.55))
            }
            .layoutPriority(1)

            Spacer(minLength: 4)

            // 窗口拉窄时：示例卡的标题先截断，四个小胶囊与右侧状态保持完整
            chip("主题", settings.palette.name, settings.palette.isLimited)
                .layoutPriority(1)
            chip("密度", settings.density.label, false)
                .layoutPriority(1)
            chip("玻璃", String(format: "%.0f%%", settings.glassStrength * 100), false)
                .layoutPriority(1)
            chip("字号", String(format: "%.0f%%", settings.fontScale * 100), false)
                .layoutPriority(1)

            HStack(spacing: 5) {
                Circle().fill(store.statusColor(scheme, accent: settings.accent))
                    .frame(width: 6, height: 6)
                Text(store.busy ? "抓取中" : store.subtitle)
                    .font(.system(size: 10.5)).foregroundStyle(.secondary)
                    .lineLimit(1).fixedSize(horizontal: true, vertical: false)
            }
        }
        .padding(.horizontal, env.space(13))
        .frame(height: 40)
        .frame(maxWidth: 1180, alignment: .leading)
        .card(env.radius(Radius.sm), look: env.look, shadow: false)
        .frame(maxWidth: .infinity, alignment: .center)
    }

    private func chip(_ k: String, _ v: String, _ highlight: Bool) -> some View {
        HStack(spacing: 4) {
            Text(k).font(.system(size: 10)).foregroundStyle(.tertiary)
                .lineLimit(1).fixedSize(horizontal: true, vertical: false)
            Text(v).font(.system(size: 11, weight: .semibold))
                .foregroundStyle(highlight ? env.accent.color(scheme, lift: 0.06) : Theme.ink2(scheme))
                .lineLimit(1).fixedSize(horizontal: true, vertical: false)
        }
        // 窗口拉到最小宽度（1020pt）时这一条会变挤；
        // 不给 lineLimit/fixedSize 的话「主题 / 经典」会各自折成两行、整条变高。
        // 现在宁可让最右边的状态文字先截断，也不要整条换行。
        .padding(.horizontal, 8).frame(height: 22)
        .background {
            Capsule().fill(highlight
                ? env.accent.color(scheme).opacity(0.13)
                : Color.primary.opacity(scheme == .dark ? 0.09 : 0.05))
        }
    }
}

/* ======================================================================
   主题卡：左图 + 右文 + 色板
   用户要求：两组原图本身也要插入在 App 中 —— 所以这里把三张实拍缩略图直接摆出来。
   ====================================================================== */

struct PaletteCard: View {
    let env: Env
    let palette: Palette
    let active: Bool
    var apply: () -> Void

    @State private var hovering = false
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Button(action: apply) {
            HStack(alignment: .top, spacing: env.space(14)) {
                photoStrip
                VStack(alignment: .leading, spacing: env.space(7)) {
                    HStack(spacing: 8) {
                        Text(palette.name)
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(Theme.ink(scheme))
                        Text(palette.en)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Theme.ink3(scheme))
                        if palette.isLimited {
                            Text("限时")
                                .font(.system(size: 9.5, weight: .bold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(Capsule().fill(RGB(palette.accent).color(scheme, lift: 0.02)))
                        }
                        Spacer(minLength: 8)
                        stateBadge
                    }
                    Text(palette.tagline)
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(RGB(palette.accent).color(scheme, lift: 0.10))

                    if palette.isLimited {
                        Text(palette.intro)
                            .font(.system(size: 11.5))
                            .foregroundStyle(Theme.ink2(scheme))
                            .lineSpacing(2.5)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: 560, alignment: .leading)
                    }

                    swatches
                }
                // 让文字列占满剩余宽度 —— 否则这列只有 560pt 宽（被 intro 的
                // maxWidth 卡住），下面的色带就铺不到卡片右边缘。
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(env.space(13))
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(RoundedRectangle(cornerRadius: env.radius(Radius.md), style: .continuous))
        }
        .buttonStyle(.plain)
        .card(env.radius(Radius.md),
              tint: active ? RGB(palette.accent).color(scheme, lift: 0.9,
                                                       opacity: scheme == .dark ? 0.16 : 0.10)
                           : (hovering ? env.accent.color(scheme, lift: 0.94,
                                                          opacity: scheme == .dark ? 0.07 : 0.05) : nil),
              look: env.look,
              shadow: active || hovering)
        .overlay {
            RoundedRectangle(cornerRadius: env.radius(Radius.md), style: .continuous)
                .strokeBorder(active ? RGB(palette.accent).color(scheme, lift: 0.08).opacity(0.55)
                                     : Color.clear,
                              lineWidth: 1.6)
        }
        .onHover { hovering = $0 }
        .hoverLift(3)
        .animation(Motion.hover, value: hovering)
        .accessibilityLabel("\(palette.name) \(palette.en)")
        .accessibilityAddTraits(active ? [.isSelected] : [])
    }

    @ViewBuilder
    private var photoStrip: some View {
        let imgs = ThemeAssets.images(palette)
        if imgs.isEmpty {
            // 经典主题没有实拍图，用强调色渐变块占位，保持卡片高度一致
            RoundedRectangle(cornerRadius: env.radius(Radius.sm), style: .continuous)
                .fill(LinearGradient(colors: [RGB(palette.pageTop).color,
                                              RGB(palette.accent).color,
                                              RGB(palette.pageBottom).color],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: 132, height: 84)
                .overlay {
                    Image(systemName: Icons.palette)
                        .font(.system(size: 20, weight: .light))
                        .foregroundStyle(.white.opacity(0.85))
                }
        } else {
            HStack(spacing: 4) {
                ForEach(Array(imgs.enumerated()), id: \.offset) { _, img in
                    Image(nsImage: img)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 42, height: 84)
                        .clipShape(RoundedRectangle(cornerRadius: env.radius(8), style: .continuous))
                }
            }
            .frame(width: 132)
        }
    }

    private var stateBadge: some View {
        HStack(spacing: 4) {
            Image(systemName: active ? "checkmark.circle.fill" : "circle.dashed")
                .font(.system(size: 10, weight: .bold))
            Text(active ? "使用中" : "应用")
                .font(.system(size: 11.5, weight: .semibold))
        }
        .foregroundStyle(active ? RGB(palette.accent).color(scheme, lift: 0.04)
                                : Theme.ink2(scheme))
        .padding(.horizontal, 10).frame(height: 24)
        .background {
            Capsule().fill(active
                ? RGB(palette.accent).color(scheme, lift: 0.86,
                                            opacity: scheme == .dark ? 0.24 : 0.20)
                : Color.primary.opacity(scheme == .dark ? 0.10 : 0.055))
        }
    }

    /// 色板：强调色 / 四档紧急度 / 学科八色 —— 全部来自这套主题。
    /// 做成**铺满卡片宽度**的等宽色带（而不是固定 15pt 的一串小方块）：
    /// 卡片有一千来点宽，固定尺寸的色板只占左边 300pt，右边整块空着，
    /// 看着就是「没排满」。等宽铺满之后整张卡才立得住。
    private var swatches: some View {
        HStack(spacing: 3) {
            ForEach(Array(swatchHexes.enumerated()), id: \.offset) { _, h in
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(RGB(h).color(scheme, lift: 0.08))
                    .frame(maxWidth: .infinity)
                    .frame(height: 15)
                    .overlay {
                        // 这套主题里本来就有三个接近纯白的「面/底」色（pageTop /
                        // card / sidebar）。不加描边的话它们连成一片白，看着像
                        // 色带漏了几个洞。0.16 在浅底上是淡灰线、深底上是淡白线，
                        // 两种模式都看得见。
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.16), lineWidth: 0.6)
                    }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 1)
    }

    private var swatchHexes: [String] { palette.bandHexes }
}

/* ======================================================================
   分组容器与行
   ====================================================================== */

struct SettingGroup<Content: View>: View {
    let env: Env
    let title: String
    let icon: String
    var note: String = ""
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: env.space(11)) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(env.accent.color(env.scheme, lift: 0.14))
                Text(title).font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Theme.ink(env.scheme))
                Spacer(minLength: 8)
                if !note.isEmpty {
                    Text(note).font(.system(size: 11.5)).foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 2)

            VStack(spacing: 0) { content() }
                .card(env.radius(Radius.md), look: env.look)
        }
    }
}

extension View {
    /// 设置行统一的内外边距。
    ///
    /// ⚠️ 以前这里**只加左右内边距**。SettingControlRow / SettingToggleRow 这类
    /// 标准行自己带了 `.padding(.vertical, 9)`，看着没问题；但所有「自定义行」
    /// （新手引导行、通知里的学科过滤、配置文件那排按钮）直接用这个修饰符，
    /// 于是上下都贴边 —— 底部尤其挤，文字像被卡片边缘切掉半行。
    /// 现在左右上下一起给，和标准行对齐。
    func settingsRowPadding(_ env: Env) -> some View {
        padding(.horizontal, env.space(Space.md))
            .padding(.vertical, env.space(11))
    }
}

/* ---------------- 设置行的两种排法 ----------------
   窗口窄的时候，把控件挤在标题右边一定会溢出（这一页控件很多）。
   所以每种行都写两套排法，交给 ViewThatFits 按实际可用宽度自己挑：
     · 宽：标题在左、控件在右（默认，最好看）
     · 窄：控件换行到底下，占满整行（不溢出，也不压缩控件）
   这样无论用户把窗口拉多窄，设置页都不会被切掉右边。
*/

/// 左侧标题 + 说明，右侧控件
struct SettingControlRow<Content: View>: View {
    let env: Env
    let title: String
    var detail: String = ""
    @ViewBuilder var control: () -> Content

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: env.space(14)) {
                label
                Spacer(minLength: env.space(10))
                control()
                    .fixedSize()
            }
            VStack(alignment: .leading, spacing: env.space(9)) {
                label
                control()
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, env.space(Space.md))
        .padding(.vertical, env.space(9))
        .frame(minHeight: env.space(44))
    }

    private var label: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 13.5, weight: .medium))
                .foregroundStyle(Theme.ink(env.scheme))
            if !detail.isEmpty {
                Text(detail)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// 纯说明行：没有控件，只有一句解释（例如「两 App 已合并」这类事项）
struct SettingNoteRow: View {
    let env: Env
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "info.circle")
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(env.accent.color(env.scheme, lift: 0.10))
                .padding(.top, 1)
            Text(text)
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.ink2(env.scheme))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .settingsRowPadding(env)
    }
}

/// 左侧标题 + 说明，右侧自绘开关
struct SettingToggleRow: View {
    let env: Env
    let title: String
    var detail: String = ""
    @Binding var on: Bool

    var body: some View {
        HStack(alignment: .center, spacing: env.space(14)) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13.5, weight: .medium))
                    .foregroundStyle(Theme.ink(env.scheme))
                if !detail.isEmpty {
                    Text(detail)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: env.space(10))
            GlassToggle(env: env, on: $on)
        }
        .padding(.horizontal, env.space(Space.md))
        .padding(.vertical, env.space(9))
        .frame(minHeight: env.space(44))
    }
}

/// 左侧标题 + 说明，右侧文本框
struct SettingFieldRow: View {
    let env: Env
    let title: String
    var detail: String = ""
    @Binding var text: String
    var placeholder: String = ""
    var secure: Bool = false

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: env.space(14)) {
                label
                Spacer(minLength: env.space(10))
                field.frame(width: 176)
            }
            VStack(alignment: .leading, spacing: env.space(9)) {
                label
                field.frame(maxWidth: .infinity)
            }
        }
        .padding(.horizontal, env.space(Space.md))
        .padding(.vertical, env.space(9))
        .frame(minHeight: env.space(44))
    }

    private var label: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 13.5, weight: .medium))
                .foregroundStyle(Theme.ink(env.scheme))
            if !detail.isEmpty {
                Text(detail)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private var field: some View {
        SoftField(placeholder: placeholder, text: $text, scheme: env.scheme,
                  font: .system(size: 12.5), secure: secure, align: .trailing)
        .padding(.horizontal, 10)
        .frame(height: 28)
        // 走统一的 fieldWell（见 Components.swift）。这一排是 28pt 高的紧凑
        // 数字框，圆角用 8 比 Radius.sm(11) 合适 —— 11 已经接近高度的 40%，
        // 看起来会像一颗药丸而不是输入框。三处输入框共用同一份实现，
        // 不再各写各的（以前账号管理那份甚至用的是卡面，白底上几乎看不见）。
        .fieldWell(env, radius: 8)
    }
}

/* ======================================================================
   动效档位选择器
   ----------------------------------------------------------------------
   三张等宽小卡并排，每张显示该档位的「节奏缩略」：
     · normal   一条均匀波形
     · breathe  长周期的缓慢起伏（两根靠近的峰）
     · vivid    高频小尖刺 + 明显回落
   选中那张把整张卡染强调色淡底，中央波形跟着切换。

   这个 selector 本身就是动效档位的"预览"——用户在这里就能看到当前选中档位的节奏，
   不必真的去看板里来回切。
   ====================================================================== */
struct MotionStylePicker: View {
    let env: Env
    @Binding var value: Motion.MotionStyle

    var body: some View {
        HStack(spacing: env.space(7)) {
            ForEach(Motion.MotionStyle.allCases, id: \.self) { s in
                MotionStyleChip(env: env, style: s, active: value == s) {
                    withAnimation(Motion.select) { value = s }
                }
            }
        }
    }
}

private struct MotionStyleChip: View {
    let env: Env
    let style: Motion.MotionStyle
    let active: Bool
    let pick: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: pick) {
            VStack(alignment: .center, spacing: 5) {
                Waveform(env: env, style: style, active: active)
                    .frame(height: 22)
                Text(style.label)
                    .font(.system(size: 11.5, weight: active ? .semibold : .medium))
                    .foregroundStyle(active ? env.accent.color(env.scheme, lift: 0.04)
                                            : Theme.ink(env.scheme))
            }
            .frame(width: 70, height: 56)
            .background {
                RoundedRectangle(cornerRadius: env.radius(10), style: .continuous)
                    .fill(active
                          ? env.accent.color(env.scheme,
                                              opacity: env.scheme == .dark ? 0.20 : 0.14)
                          : (env.scheme == .dark ? Color.white.opacity(0.04) : Color.white.opacity(0.65)))
            }
            .overlay {
                RoundedRectangle(cornerRadius: env.radius(10), style: .continuous)
                    .strokeBorder(active
                                  ? env.accent.color(env.scheme).opacity(0.55)
                                  : (hovering ? Theme.line(env.scheme) : Theme.lineSoft(env.scheme)),
                                  lineWidth: active ? 1.4 : 0.8)
            }
            .scaleEffect(hovering ? 1.04 : 1)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(Motion.hover, value: hovering)
        .accessibilityLabel("\(style.label)动效")
        .accessibilityAddTraits(active ? [.isSelected] : [])
    }
}

/// 用一条细线画"节奏缩略"：normal 均匀、breathe 缓慢起伏、vivid 密集小尖刺。
private struct Waveform: View {
    let env: Env
    let style: Motion.MotionStyle
    let active: Bool

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let mid = h / 2
            let color = active
                ? env.accent.color(env.scheme, lift: 0.06)
                : Theme.ink2(env.scheme).opacity(0.78)
            ZStack {
                // 中心基线
                Path { p in
                    p.move(to: CGPoint(x: 0, y: mid))
                    p.addLine(to: CGPoint(x: w, y: mid))
                }
                .stroke(Theme.lineSoft(env.scheme), style: StrokeStyle(lineWidth: 0.6, dash: [2, 2]))

                // 节奏曲线
                Path { p in
                    p.move(to: CGPoint(x: 0, y: mid))
                    let n = 26
                    for i in 0...n {
                        let x = w * CGFloat(i) / CGFloat(n)
                        let t = Double(i) / Double(n)
                        let y: CGFloat
                        switch style {
                        case .normal:
                            y = mid - CGFloat(sin(t * .pi * 2)) * (h * 0.32)
                        case .breathe:
                            // 1 个完整周期 + 顶部平坦段 —— "真的在呼吸"
                            let phase = t * 2 * .pi - .pi/2
                            y = mid - CGFloat(sin(phase)) * (h * 0.40)
                                * CGFloat(0.5 + 0.5 * cos(t * .pi))
                        case .vivid:
                            // 高频 + 末端小回落
                            y = mid - CGFloat(sin(t * .pi * 6)) * (h * 0.36)
                                * CGFloat(1.0 - t * 0.4)
                        }
                        p.addLine(to: CGPoint(x: x, y: y))
                    }
                }
                .stroke(color, style: StrokeStyle(lineWidth: active ? 1.6 : 1.2, lineCap: .round))
                .animation(Motion.select, value: style)
            }
        }
    }
}

/// 快捷键行（可以只有一条，也可以是「下一项 / 上一项」两条）
struct ShortcutRow: View {
    let env: Env
    let title: String
    var detail: String = ""
    @Binding var binding: String
    var second: Binding<String>? = nil

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: env.space(14)) {
                label
                Spacer(minLength: env.space(10))
                fields.fixedSize()
            }
            VStack(alignment: .leading, spacing: env.space(9)) {
                label
                fields
            }
        }
        .padding(.horizontal, env.space(Space.md))
        .padding(.vertical, env.space(9))
        .frame(minHeight: env.space(44))
    }

    private var label: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 13.5, weight: .medium))
                .foregroundStyle(Theme.ink(env.scheme))
            if !detail.isEmpty {
                Text(detail).font(.system(size: 11.5)).foregroundStyle(.secondary)
            }
        }
    }

    private var fields: some View {
        HStack(spacing: 6) {
            ShortcutField(env: env, value: $binding)
            if let second {
                ShortcutField(env: env, value: second)
            }
        }
    }
}

/// 强调色小色块
struct AccentSwatch: View {
    let env: Env
    let preset: AccentPreset
    let active: Bool
    var tap: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: tap) {
            Circle()
                .fill(RGB(preset.hex).color(env.scheme, lift: 0.06))
                .frame(width: 22, height: 22)
                .overlay {
                    Circle().strokeBorder(
                        active ? Theme.ink(env.scheme).opacity(0.75) : Color.primary.opacity(0.12),
                        lineWidth: active ? 2 : 0.8)
                }
                .overlay {
                    if active {
                        Image(systemName: "checkmark")
                            .font(.system(size: 10, weight: .black))
                            .foregroundStyle(RGB(preset.hex).onColor)
                    }
                }
                .scaleEffect(hovering ? 1.10 : 1)
                .animation(Motion.snappy(0.18), value: hovering)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(preset.name)
        .accessibilityLabel(preset.name)
    }
}

/* ---------------- 开机自启 ---------------- */

enum LaunchAtLogin {
    static let label = "com.mbboard.menubar"

    static func set(_ on: Bool) {
        let agents = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
        let plist = agents.appendingPathComponent("\(label).plist")
        if !on {
            try? FileManager.default.removeItem(at: plist)
            return
        }
        let appPath = "/Applications/ManageBac 菜单栏.app"
        let fallback = NSHomeDirectory() + "/Desktop/ManageBac 看板 For Mac/ManageBac 菜单栏.app"
        let target = FileManager.default.fileExists(atPath: appPath) ? appPath : fallback
        try? FileManager.default.createDirectory(at: agents, withIntermediateDirectories: true)
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
          <key>Label</key><string>\(label)</string>
          <key>ProgramArguments</key>
          <array><string>/usr/bin/open</string><string>-a</string><string>\(target)</string></array>
          <key>RunAtLoad</key><true/>
        </dict>
        </plist>
        """
        try? xml.data(using: .utf8)?.write(to: plist)
    }
}

/* ---------------- Color ↔ hex 已在 Theme.swift（共享层） ---------------- */

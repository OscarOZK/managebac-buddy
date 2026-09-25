import SwiftUI
import AppKit

/* ======================================================================
   浮层小窗的统一外壳
   ----------------------------------------------------------------------
   全 App 的浮层弹窗（任务详情 / Teams 预览 / 学科柱状图 / 主题推送）都套这一层，
   于是「怎么出现、怎么挪、背景怎么压暗」只有一处实现。

   四件事，各自都有前车之鉴：

   ① **相对窗口居中，不是相对内容居中。**
      以前 Teams 预览的浮层是挂在任务列表那个 `VStack` 上的（`.overlay {}`）。
      那个 VStack 就是**滚动内容本身**，比视口高得多 —— 于是「居中」居的是
      整篇长文的中点：内容一长，小窗就掉到视口下方，甚至被窗口底边切掉一半
      （用户截图就是这个）。
      现在浮层挂在窗口根部的 ZStack 上（见各 `*Host`），中心永远是视口中心，
      跟被点的卡片原来在哪儿无关。

   ② **整条顶边都能按住拖。**
      第一版只在左上角铺了一条 240pt 宽的透明拖拽带（怕铺满会吃掉页头右边的
      关闭按钮）。用户用下来嫌太窄：「整个最上边的那部分都可以拖拽」。
      现在改成挂在**整块面板**上的高优先手势（`.highPriorityGesture`），
      只按「落点在不在这条顶带里」决定要不要挪窗口：
        · 轻轻一点按钮 → 位移没到阈值，手势不成立，按钮照常工作；
        · 按住一拖 → 手势成立，**优先于**子视图的按钮 → 从关闭按钮上起拖
          也只会挪窗口，不会误触关闭。
      这两条同时成立，靠的就是 `minimumDistance` + `highPriorityGesture`
      这个组合；换成铺一条透明 overlay 是做不到的 —— overlay 会直接
      把下面按钮的点击整块吃掉（hit-test 是先命中上层视图，不再往下传）。

   ③ **背景不是一块全黑纱幕，而是跟着小窗走的径向渐暗。**
      全黑纱幕的问题是「远处也被压暗」—— 用户要的是小窗附近稍微暗一点，
      然后**渐变**回正常。所以这里用 RadialGradient，中心钉在小窗中心，
      半径跟着窗口尺寸算；拖动时位移一变，渐变中心当帧就跟着走。

   ④ **位移必须量在「不动的坐标系」里 —— 这是「拖动时闪跳抽搐」的根因。**
      第一版用 `DragGesture()`（默认 `.local`）配 `base + translation`，
      而手势所附着的视图**自己正被这个 translation 挪动**：
      坐标系跟着视图一起移，于是「上一帧的位移」被算进了这一帧的位移里，
      形成正反馈 —— 表现就是小窗一边抖一边抽。
      两条修法一起上：
        · `coordinateSpace` 指到**视口**（一个不随小窗移动的命名坐标系），
          位移在两个固定点之间量，1:1 跟手，不可能自激；
        · 在手位移（`@GestureState live`）不落 `@State`，由 SwiftUI 在手势
          结束时自动归零。落 `@State` 的话，手势结束后那一次重算会**再叠一次**
          位移，看着就是「松手瞬间跳一下」。
      另外位移**完全不套动画**：拖动要的是跟手，套了弹簧反而显得拖沓；
      只给「拖起来的抬升感」配一点缩放和更深的投影。
   ====================================================================== */

struct FloatingWindow<Panel: View>: View {

    /// 小窗正中心处的不透明度（离小窗越远越淡，到 2.1 倍半径处归零）
    var dim: Double = 0.46
    /// 小窗的「半径」——决定那圈阴影铺多开。取半对角线量级即可。
    var panelRadius: CGFloat = 400
    /// 小窗四周留白（就是原来各弹窗自己写的那圈 `.padding`）。
    /// 顶带要贴在小窗**本体的顶边**上，所以留白必须由这里来加。
    var inset: EdgeInsets = EdgeInsets(top: 28, leading: 28, bottom: 28, trailing: 28)
    /// 点小窗以外的地方
    var onTapOutside: () -> Void = {}
    @ViewBuilder var panel: () -> Panel

    /// 顶带的高度：小窗页头那一条
    private let grabH: CGFloat = 46
    /// 手势成立的位移阈值。给 6pt 是为了「点击」与「拖动」分得干净：
    /// 手指的正常抖动不会越过它，所以按钮的点按不会被拖拽抢走。
    private let grabSlop: CGFloat = 6

    @ObservedObject private var settings = BoardSettings.shared

    /// 已经定下来的落点（松手后保留）
    @State private var committed: CGSize = .zero
    /// 本次拖动的手部位移。`@GestureState` 在手势结束时**自动归零**，
    /// 所以松手那一刻不会像 `@State` 那样被重复计入一次（那正是「跳一下」的来源）。
    @GestureState private var live: CGSize = .zero
    @State private var dragging = false
    /// 小窗本体的高度（不含 inset）。算「顶带在视口里的位置」要用它，
    /// 而小窗高度是内容决定的、只能在运行时量。
    @State private var panelH: CGFloat = 0

    private var cur: CGSize {
        CGSize(width: committed.width + live.width, height: committed.height + live.height)
    }

    var body: some View {
        GeometryReader { geo in
            let W = max(1, geo.size.width)
            let H = max(1, geo.size.height)
            ZStack {
                scrim(W, H)
                content(W, H)
            }
            // ★ 位移量在**这个**坐标系里量 ★
            // 它挂在视口上，不随小窗移动 —— 见文件头 ④。
            .coordinateSpace(name: Self.space)
        }
        .ignoresSafeArea()
    }

    static var space: String { "mbboard.floating" }

    /* ---------------- 跟手的径向渐暗 ---------------- */

    private func scrim(_ W: CGFloat, _ H: CGFloat) -> some View {
        // 渐变中心 = 视口中心 + 当前位移。拖动时位移每帧都在变，
        // 所以中心也是每帧跟着走 —— 这就是「实时」。
        let cx = W / 2 + cur.width
        let cy = H / 2 + cur.height
        let endR = max(140, panelRadius * 2.1)

        // 五段 stop 从 dim 平滑归零：小窗脚下最暗，往外一路渐弱，
        // 到 2.1 倍半径处彻底消失 —— 没有硬边，就是用户要的「渐变过渡」。
        return RadialGradient(
            gradient: Gradient(stops: [
                .init(color: .black.opacity(dim),            location: 0.00),
                .init(color: .black.opacity(dim * 0.86),     location: 0.42),
                .init(color: .black.opacity(dim * 0.46),     location: 0.70),
                .init(color: .black.opacity(dim * 0.14),     location: 0.88),
                .init(color: .black.opacity(0),              location: 1.00)
            ]),
            center: UnitPoint(x: cx / W, y: cy / H),
            startRadius: 0,
            endRadius: endR)
        .frame(width: W, height: H)
        .contentShape(Rectangle())
        .onTapGesture(perform: onTapOutside)
    }

    /* ---------------- 小窗本体 ---------------- */

    private func content(_ W: CGFloat, _ H: CGFloat) -> some View {
        panel()
            // 量一下小窗本体多高（见 panelTopInViewport 的说明）
            .background {
                GeometryReader { g in
                    Color.clear.preference(key: FloatPanelH.self, value: g.size.height)
                }
            }
            .padding(inset)
            .offset(cur)
            .scaleEffect(dragging ? 1.006 : 1)
            .shadow(color: .black.opacity(settings.glassPanelShadow ? (dragging ? 0.40 : 0.26) : 0),
                    radius: dragging ? 42 : 26, y: dragging ? 22 : 14)
            // 位移本身**不套动画**（见文件头 ④）：拖动必须 1:1 跟手。
            // 唯一要动画的是「拖起来的抬升感」，它跟的是 dragging 这个布尔量。
            .animation(Motion.hover, value: dragging)
            // 自检专用：让位移自己来回荡，用来核验「渐暗实时跟随」（见 13.14）
            .animation(PreviewFlags.autoDrag
                       ? .easeInOut(duration: 1.15).repeatForever(autoreverses: true)
                       : nil,
                       value: committed)
            .onPreferenceChange(FloatPanelH.self) { panelH = $0 }
            // ★ 必须是 highPriorityGesture，不能是 gesture ★
            // `.gesture` 的优先级**低于**子视图，从关闭按钮上按下再拖，事件会被
            // 按钮吃掉，窗口纹丝不动 —— 那就还是「只有一小块地方能拖」。
            // 换成高优先之后，配合 `minimumDistance: grabSlop`：
            //   位移不到 6pt → 手势不成立 → 事件照常传给按钮（点击有效）；
            //   拖过 6pt     → 手势成立并抢走后续事件 → 只挪窗口，不会误触按钮。
            // 见文件头 ②。
            .highPriorityGesture(grab(W, H))
            .onAppear { startAutoWobble() }
    }

    /* ---------------- 拖动 ---------------- */

    /// 小窗本体（不含 inset）的顶边落在视口坐标系里的哪个 y。
    ///
    /// 推导：ZStack 把小窗（含 padding 的整体）居中，所以整体顶边 = (H - 整体高)/2，
    /// 再加当前位移；本体顶边再往下让一个 inset.top。
    private func panelTopInViewport(_ H: CGFloat) -> CGFloat {
        let wholeH = panelH + inset.top + inset.bottom
        return (H - wholeH) / 2 + inset.top + cur.height
    }

    private func grab(_ W: CGFloat, _ H: CGFloat) -> some Gesture {
        // 坐标空间用视口（不随小窗移动）——见文件头 ④
        DragGesture(minimumDistance: grabSlop, coordinateSpace: .named(Self.space))
            .updating($live) { v, s, _ in
                guard settings.panelDrag else { return }
                // 只有落在顶带里才算「拖窗口」，免得在正文里拖一下也把窗口带走
                guard v.startLocation.y <= panelTopInViewport(H) + grabH else { return }
                s = v.translation
            }
            .onChanged { v in
                guard settings.panelDrag else { return }
                guard v.startLocation.y <= panelTopInViewport(H) + grabH else { return }
                if !dragging { dragging = true }
            }
            .onEnded { v in
                guard settings.panelDrag else { return }
                guard v.startLocation.y <= panelTopInViewport(H) + grabH else { return }
                dragging = false
                // 横向不给拖出视口（留一点边，免得整块飘出去找不回来）；
                // 纵向不设限 —— 小窗想停哪儿停哪儿。
                let limX = max(40, W / 2 - 70)
                committed = CGSize(
                    width: min(limX, max(-limX, committed.width + v.translation.width)),
                    height: committed.height + v.translation.height)
            }
    }

    /// 只在 `--live --autodrag` 自检里跑：让位移自己来回荡。
    /// 拖动时 `scrim` 的渐变中心 = 视口中心 + 位移，位移每帧在变，
    /// 中心就每帧在变 —— 逐帧比相邻帧就能验证「渐暗真的跟手」，而不是
    /// 拖完才跳一下。真机代码路径与此完全一致（都是改这个位移）。
    ///
    /// `--drag x,y` 是**钉死**一个位移（不带动画）。量「渐暗中心有没有跟着
    /// 位移走」这种几何题，固定位移比动画可靠：动画每帧相位不同，采样撞上
    /// 哪一相位全看运气，两次跑出来的数字没法比。
    private func startAutoWobble() {
        if let d = PreviewFlags.dragTo {
            committed = d
            return
        }
        guard PreviewFlags.autoDrag else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            committed = CGSize(width: 190, height: 118)
        }
    }
}

/// 量小窗本体高度用的偏好键
private struct FloatPanelH: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
